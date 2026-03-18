import 'dart:async';
import 'dart:io';
import '../../core/types.dart';
import '../tool_interface.dart';
import '../../permissions/blocked_patterns.dart';

class RunCommandTool implements ProximaTool {
  @override
  String get name => 'run_command';

  @override
  String get description =>
      'Run a shell command in the working directory. '
      'Blocked patterns (sudo, rm -rf /, curl|sh, etc.) are rejected.';

  @override
  RiskLevel get riskLevel => RiskLevel.confirm;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'command': {'type': 'string', 'description': 'Shell command to run'},
      'timeout_seconds': {
        'type': 'integer',
        'description': 'Timeout in seconds (default 30)',
      },
    },
    'required': ['command'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final command = args['command'] as String;
    final timeoutSeconds = args['timeout_seconds'] as int? ?? 30;

    if (isBlockedCommand(command)) {
      throw ToolError(name, 'Command blocked by security policy: $command');
    }

    try {
      final result = await Process.run(
        'bash',
        ['-c', command],
        workingDirectory: workingDir,
        runInShell: false,
      ).timeout(Duration(seconds: timeoutSeconds));

      final output = StringBuffer();
      if (result.stdout.toString().isNotEmpty) {
        output.write(result.stdout);
      }
      if (result.stderr.toString().isNotEmpty) {
        output.write('\nSTDERR: ${result.stderr}');
      }
      output.write('\nExit code: ${result.exitCode}');

      return output.toString().trim();
    } on TimeoutException {
      throw ToolError(
        name,
        'Command timed out after ${timeoutSeconds}s: $command',
      );
    } catch (e) {
      throw ToolError(name, 'Command failed: $e');
    }
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final command = args['command'] as String;
    final blocked = isBlockedCommand(command);
    return DryRunResult(
      preview: blocked ? '[BLOCKED] $command' : 'Would run: $command',
      riskLevel: blocked ? RiskLevel.blocked : riskLevel,
    );
  }
}
