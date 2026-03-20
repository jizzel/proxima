import 'dart:io';
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class GitDiffTool implements ProximaTool {
  @override
  String get name => 'git_diff';

  @override
  String get description =>
      'Show unstaged or staged diff. Optionally filter by file path.';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'staged': {
        'type': 'boolean',
        'description': 'If true, show staged (--cached) diff. Default false.',
      },
      'path': {
        'type': 'string',
        'description': 'Optional: limit diff to this file path.',
      },
    },
    'required': <String>[],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final staged = args['staged'] as bool? ?? false;
    final path = args['path'] as String?;

    if (path != null && !isSafePath(path, workingDir)) {
      throw ToolError(name, 'Path "$path" is outside working directory.');
    }

    final gitArgs = ['diff'];
    if (staged) gitArgs.add('--staged');
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
      throw ToolError(name, 'git_diff failed: ${result.stderr}');
    }
    final out = (result.stdout as String).trim();
    return out.isEmpty ? 'No diff.' : out;
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final staged = args['staged'] as bool? ?? false;
    final path = args['path'] as String?;
    final cmd =
        'git diff${staged ? ' --staged' : ''}${path != null ? ' -- $path' : ''}';
    return DryRunResult(preview: 'Would run: $cmd', riskLevel: riskLevel);
  }
}
