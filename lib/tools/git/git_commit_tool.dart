import 'dart:io';
import '../../core/types.dart';
import '../tool_interface.dart';

class GitCommitTool implements ProximaTool {
  @override
  String get name => 'git_commit';

  @override
  String get description => 'Create a commit with the given message.';

  @override
  RiskLevel get riskLevel => RiskLevel.confirm;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'message': {'type': 'string', 'description': 'Commit message.'},
    },
    'required': ['message'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final message = args['message'] as String;

    final result = await Process.run('git', [
      'commit',
      '-m',
      message,
    ], workingDirectory: workingDir);
    if (result.exitCode != 0) {
      throw ToolError(name, 'git_commit failed: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final message = args['message'] as String;
    return DryRunResult(
      preview: 'Would run: git commit -m "$message"',
      riskLevel: riskLevel,
    );
  }
}
