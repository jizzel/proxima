import 'dart:io';
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class GitAddTool implements ProximaTool {
  @override
  String get name => 'git_add';

  @override
  String get description =>
      'Stage a file for commit. Explicit path required — no "git add ." allowed.';

  @override
  RiskLevel get riskLevel => RiskLevel.confirm;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {
        'type': 'string',
        'description': 'Relative path to the file to stage.',
      },
    },
    'required': ['path'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final path = args['path'] as String;

    if (!isSafePath(path, workingDir)) {
      throw ToolError(name, 'Path "$path" is outside working directory.');
    }

    final result = await Process.run('git', [
      'add',
      path,
    ], workingDirectory: workingDir);
    if (result.exitCode != 0) {
      throw ToolError(name, 'git_add failed: ${result.stderr}');
    }
    return 'Staged: $path';
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final path = args['path'] as String;
    return DryRunResult(
      preview: 'Would run: git add $path',
      riskLevel: riskLevel,
    );
  }
}
