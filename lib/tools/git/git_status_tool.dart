import 'dart:io';
import '../../core/types.dart';
import '../tool_interface.dart';

class GitStatusTool implements ProximaTool {
  @override
  String get name => 'git_status';

  @override
  String get description =>
      'Show the working tree status (staged, unstaged, and untracked files).';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': <String, dynamic>{},
    'required': <String>[],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final result = await Process.run('git', [
      'status',
      '--short',
    ], workingDirectory: workingDir);
    if (result.exitCode != 0) {
      // Not being a git repository is an ordinary condition, not a failure —
      // a scaffolded project has no repo yet, and a hard error there reads as
      // a broken tool. Report it as information the model can act on.
      final stderr = (result.stderr as String).toLowerCase();
      if (stderr.contains('not a git repository')) {
        return 'Not a git repository.';
      }
      throw ToolError(name, 'git_status failed: ${result.stderr}');
    }
    final out = (result.stdout as String).trim();
    return out.isEmpty ? 'Working tree clean.' : out;
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async => DryRunResult(
    preview: 'Would run: git status --short',
    riskLevel: riskLevel,
  );
}
