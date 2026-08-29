import 'dart:async';
import 'dart:convert';
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

  /// Terminates [process] and any children it spawned.
  ///
  /// `process.kill()` alone is not enough on Windows: `cmd /c <command>`
  /// launches the command as a *separate* process, so killing the shell leaves
  /// it running — holding the working directory open and continuing work the
  /// user was told had stopped. `taskkill /T` ends the whole tree.
  ///
  /// On POSIX `bash -c` execs into the command, so killing the shell is
  /// sufficient.
  static Future<void> killProcessTree(Process process) async {
    if (Platform.isWindows) {
      try {
        await Process.run('taskkill', [
          '/pid',
          '${process.pid}',
          '/T',
          '/F',
        ]).timeout(const Duration(seconds: 5));
      } catch (_) {
        // Fall through to the direct kill below.
      }
    }
    process.kill(ProcessSignal.sigkill);
    // Wait for the handle to be released before a caller tries to remove the
    // working directory — Windows refuses to delete one still held open.
    await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
  }

  /// Gathers stdout, stderr, and the exit code from a started [process],
  /// producing the same shape `Process.run` would have returned.
  static Future<ProcessResult> collect(Process process) async {
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    final exitCode = await process.exitCode;
    return ProcessResult(
      process.pid,
      exitCode,
      await stdoutFuture,
      await stderrFuture,
    );
  }

  /// The shell used to run commands.
  ///
  /// Hardcoding `bash` broke every Windows install: `bash.exe` on Windows
  /// resolves to the WSL launcher, which — with no distribution installed —
  /// returns UTF-16 text explaining how to install one, and exit code 1. Every
  /// `run_command` call failed that way, in the shipped binary as well as CI.
  static String get shellExecutable => Platform.isWindows ? 'cmd' : 'bash';

  /// Arguments preceding the command string for [shellExecutable].
  static List<String> get shellArgs =>
      Platform.isWindows ? const ['/c'] : const ['-c'];

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final command = args['command'] as String;
    final timeoutSeconds = args['timeout_seconds'] as int? ?? 30;

    if (isBlockedCommand(command)) {
      throw ToolError(name, 'Command blocked by security policy: $command');
    }

    // Process.start rather than Process.run: `run(...).timeout(...)` abandons
    // the Future but leaves the child running, so a "timed out" command keeps
    // executing invisibly — unacceptable for a tool behind a permission gate,
    // and on Windows it also holds the working directory open.
    final process = await Process.start(
      shellExecutable,
      [...shellArgs, command],
      workingDirectory: workingDir,
      runInShell: false,
    );

    try {
      final result = await collect(
        process,
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
      await killProcessTree(process);
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
