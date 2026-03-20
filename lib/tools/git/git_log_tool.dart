import 'dart:io';
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class GitLogTool implements ProximaTool {
  @override
  String get name => 'git_log';

  @override
  String get description =>
      'Show recent commit history. Optionally limit count or filter by path.';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'limit': {
        'type': 'integer',
        'description': 'Number of commits to show (default 20).',
      },
      'path': {
        'type': 'string',
        'description': 'Optional: limit history to this file path.',
      },
    },
    'required': <String>[],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final limit = args['limit'] as int? ?? 20;
    final path = args['path'] as String?;

    if (path != null && !isSafePath(path, workingDir)) {
      throw ToolError(name, 'Path "$path" is outside working directory.');
    }

    final gitArgs = ['log', '--oneline', '-n', '$limit'];
    if (path != null) {
      gitArgs.add('--');
      gitArgs.add(path);
    }

    final result = await Process.run(
      'git',
      gitArgs,
      workingDirectory: workingDir,
    );
    if (result.exitCode != 0) {
      final stderr = result.stderr as String;
      // Empty repo has no commits yet — not a real error.
      if (stderr.contains('does not have any commits yet')) {
        return 'No commits found.';
      }
      throw ToolError(name, 'git_log failed: $stderr');
    }
    final out = (result.stdout as String).trim();
    return out.isEmpty ? 'No commits found.' : out;
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final limit = args['limit'] as int? ?? 20;
    final path = args['path'] as String?;
    final cmd =
        'git log --oneline -n $limit${path != null ? ' -- $path' : ''}';
    return DryRunResult(preview: 'Would run: $cmd', riskLevel: riskLevel);
  }
}
