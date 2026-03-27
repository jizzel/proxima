import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

/// Writes a structured implementation plan to `.proxima/plan.md` for user
/// review before execution. Safe risk level — the plan itself is a proposal doc.
class WritePlanTool implements ProximaTool {
  @override
  String get name => 'write_plan';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  String get description =>
      'Write a plan to .proxima/plan.md for user review before execution. '
      'Use this in plan mode after researching the codebase.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'content': {
        'type': 'string',
        'description':
            'Full markdown plan content to write to .proxima/plan.md',
      },
    },
    'required': ['content'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final content = args['content'] as String;
    final planDir = p.join(workingDir, '.proxima');
    final planPath = p.join(planDir, 'plan.md');

    if (!isSafePath(planPath, workingDir)) {
      throw ToolError(
        name,
        'Plan path is outside working directory.',
        errorCode: ToolErrorCode.pathViolation,
      );
    }

    await Directory(planDir).create(recursive: true);
    await File(planPath).writeAsString(content);

    return 'Plan written to .proxima/plan.md';
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    return DryRunResult(
      preview: 'Would write plan to .proxima/plan.md',
      riskLevel: riskLevel,
    );
  }
}
