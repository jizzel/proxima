import 'dart:io';
import '../../core/types.dart';
import '../tool_interface.dart';

class GitResetTool implements ProximaTool {
  @override
  String get name => 'git_reset';

  @override
  String get description =>
      'Reset the working tree to a ref using --hard. Destructive — requires explicit confirmation.';

  @override
  RiskLevel get riskLevel => RiskLevel.highRisk;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'ref': {
        'type': 'string',
        'description': 'Git ref to reset to (default: HEAD).',
      },
    },
    'required': <String>[],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final ref = args['ref'] as String? ?? 'HEAD';

    final result = await Process.run('git', [
      'reset',
      '--hard',
      ref,
    ], workingDirectory: workingDir);
    if (result.exitCode != 0) {
      throw ToolError(name, 'git_reset failed: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final ref = args['ref'] as String? ?? 'HEAD';
    return DryRunResult(
      preview: '[HIGH RISK] git reset --hard $ref',
      riskLevel: riskLevel,
    );
  }
}
