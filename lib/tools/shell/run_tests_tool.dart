import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import '../tool_interface.dart';
import 'test_output_parser.dart';

class RunTestsTool implements ProximaTool {
  @override
  String get name => 'run_tests';

  @override
  String get description =>
      'Run the project test suite. Auto-detects the framework from project files.';

  @override
  RiskLevel get riskLevel => RiskLevel.confirm;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Optional specific test file or directory',
      },
      'filter': {
        'type': 'string',
        'description': 'Optional test name filter/pattern',
      },
    },
    'required': [],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final command = await _detectTestCommand(workingDir, args);
    if (command == null) {
      throw ToolError(name, 'Could not detect test framework in $workingDir');
    }

    final framework = _detectFramework(workingDir);

    try {
      final result = await Process.run(
        'bash',
        ['-c', command],
        workingDirectory: workingDir,
        runInShell: false,
      ).timeout(const Duration(seconds: 120));

      final rawOutput = StringBuffer();
      rawOutput.write(result.stdout);
      if (result.stderr.toString().isNotEmpty) {
        rawOutput.write('\nSTDERR: ${result.stderr}');
      }

      // Parse into structured result for LLM-friendly output.
      final fw = await framework;
      final parsed = fw != null
          ? TestOutputParser.parse(rawOutput.toString(), fw)
          : null;

      final output = StringBuffer();
      if (parsed != null) {
        output.writeln(parsed.toPromptText());
        if (!parsed.passed) {
          // Include raw output after the summary so the LLM has full context.
          output.writeln('\n--- raw output ---');
          output.write(rawOutput);
        }
      } else {
        output.write(rawOutput);
      }
      output.write('\nExit code: ${result.exitCode}');
      if (fw != null) {
        output.write('$kFrameworkMarker${fw.name}');
      }

      return output.toString().trim();
    } on TimeoutException {
      throw ToolError(
        name,
        'Tests timed out after 120s',
        errorCode: ToolErrorCode.timeout,
      );
    } catch (e) {
      throw ToolError(name, 'Tests failed to run: $e');
    }
  }

  /// Detect which test framework the project uses.
  Future<TestFramework?> _detectFramework(String workingDir) async {
    if (await File(p.join(workingDir, 'pubspec.yaml')).exists()) {
      return TestFramework.dart;
    }
    if (await File(p.join(workingDir, 'package.json')).exists()) {
      return TestFramework.jest;
    }
    if (await File(p.join(workingDir, 'Cargo.toml')).exists()) {
      return TestFramework.cargo;
    }
    if (await File(p.join(workingDir, 'go.mod')).exists()) {
      return TestFramework.go;
    }
    if (await File(p.join(workingDir, 'requirements.txt')).exists() ||
        await File(p.join(workingDir, 'setup.py')).exists() ||
        await File(p.join(workingDir, 'pyproject.toml')).exists()) {
      return TestFramework.pytest;
    }
    return null;
  }

  /// Sanitize a user-supplied string to only allow safe identifier characters.
  /// Prevents shell injection when args are embedded in shell command strings.
  String? _sanitize(String? value) {
    if (value == null) return null;
    // Allow alphanumeric, spaces, dots, underscores, hyphens, slashes, colons.
    // Reject anything that could escape the quoted context.
    final sanitized = value.replaceAll(RegExp(r'[^\w\s.\-/:@]'), '');
    return sanitized.isEmpty ? null : sanitized;
  }

  Future<String?> _detectTestCommand(
    String workingDir,
    Map<String, dynamic> args,
  ) async {
    final path = _sanitize(args['path'] as String?);
    final filter = _sanitize(args['filter'] as String?);

    // Dart / Flutter
    if (await File(p.join(workingDir, 'pubspec.yaml')).exists()) {
      final cmd = StringBuffer('dart test');
      if (path != null) cmd.write(' ${_shellQuote(path)}');
      if (filter != null) cmd.write(' --name ${_shellQuote(filter)}');
      return cmd.toString();
    }

    // Node.js (Jest / npm test)
    if (await File(p.join(workingDir, 'package.json')).exists()) {
      final cmd = StringBuffer('npm test');
      if (filter != null) {
        cmd.write(' -- --testNamePattern=${_shellQuote(filter)}');
      }
      return cmd.toString();
    }

    // Rust
    if (await File(p.join(workingDir, 'Cargo.toml')).exists()) {
      final cmd = StringBuffer('cargo test');
      if (filter != null) cmd.write(' ${_shellQuote(filter)}');
      return cmd.toString();
    }

    // Go
    if (await File(p.join(workingDir, 'go.mod')).exists()) {
      final pkg = path ?? './...';
      final cmd = StringBuffer('go test ${_shellQuote(pkg)}');
      if (filter != null) cmd.write(' -run ${_shellQuote(filter)}');
      return cmd.toString();
    }

    // Python
    if (await File(p.join(workingDir, 'requirements.txt')).exists() ||
        await File(p.join(workingDir, 'setup.py')).exists() ||
        await File(p.join(workingDir, 'pyproject.toml')).exists()) {
      final cmd = StringBuffer('python -m pytest');
      if (path != null) cmd.write(' ${_shellQuote(path)}');
      if (filter != null) cmd.write(' -k ${_shellQuote(filter)}');
      return cmd.toString();
    }

    return null;
  }

  /// Single-quote a shell argument (safe for bash -c contexts).
  String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final command = await _detectTestCommand(workingDir, args);
    return DryRunResult(
      preview: command != null
          ? 'Would run: $command'
          : 'Could not detect test framework',
      riskLevel: riskLevel,
    );
  }
}
