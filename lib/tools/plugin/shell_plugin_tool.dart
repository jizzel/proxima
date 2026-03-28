import 'dart:convert';
import 'dart:io';
import '../../core/types.dart';
import '../tool_interface.dart';

/// Wraps a shell-script or binary plugin as a Proxima tool.
class ShellPluginTool implements ProximaTool {
  final String _name;
  final String _description;
  final RiskLevel _riskLevel;
  final Map<String, dynamic> _inputSchema;
  final String _executable; // absolute path
  final int _timeoutSeconds;

  ShellPluginTool({
    required String name,
    required String description,
    required RiskLevel riskLevel,
    required Map<String, dynamic> inputSchema,
    required String executable,
    required int timeoutSeconds,
  }) : _name = name,
       _description = description,
       _riskLevel = riskLevel,
       _inputSchema = inputSchema,
       _executable = executable,
       _timeoutSeconds = timeoutSeconds;

  @override
  String get name => _name;

  @override
  String get description => _description;

  @override
  RiskLevel get riskLevel => _riskLevel;

  @override
  Map<String, dynamic> get inputSchema => _inputSchema;

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final process = await Process.start(
      _executable,
      [],
      workingDirectory: workingDir,
    );
    try {
      process.stdin.write(jsonEncode(args));
      await process.stdin.close();
    } catch (_) {
      // Process may have exited before reading stdin (e.g. ignores it).
      // The exit code check below will surface the actual failure.
    }

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();

    final exitCode = await process.exitCode.timeout(
      Duration(seconds: _timeoutSeconds),
    );

    final result = await stdoutFuture;
    if (exitCode != 0) {
      final err = await stderrFuture;
      throw ToolError(
        _name,
        err.trim().isNotEmpty
            ? err.trim()
            : 'Plugin exited with code $exitCode',
        retryable: false,
        errorCode: ToolErrorCode.unknown,
      );
    }
    return result.trim();
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async => DryRunResult(
    preview: 'Will run plugin "$_name" with args: ${jsonEncode(args)}',
    riskLevel: _riskLevel,
  );
}
