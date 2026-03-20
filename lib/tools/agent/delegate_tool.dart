import '../../core/types.dart';
import '../tool_interface.dart';

/// Tool that allows the main agent to delegate to a specialist subagent.
///
/// This tool is registered in the tool registry so the LLM sees it in tool
/// definitions. Its [execute] method is a sentinel — the agent loop intercepts
/// [delegate_to_subagent] calls before they ever reach this method.
class DelegateToSubagentTool implements ProximaTool {
  @override
  String get name => 'delegate_to_subagent';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  String get description =>
      'Delegate a specialist sub-task to one of three expert agents and receive '
      'structured JSON output. Available agents:\n'
      '- code_analyzer: returns {"issues":[], "severity":[], "suggestions":[]}\n'
      '- refactor: returns {"proposed_changes":[{"file","diff","reason"}], "impact_summary":""}\n'
      '- test: returns {"test_cases":[{"name","description"}], "coverage_gaps":[], "failing_tests":[]}\n'
      'Use at most twice per turn. Subagents receive no tools and cannot delegate further.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'agent': {
        'type': 'string',
        'enum': ['code_analyzer', 'refactor', 'test'],
        'description': 'The specialist agent to delegate to.',
      },
      'task': {
        'type': 'string',
        'description': 'Clear description of what the subagent should do.',
      },
      'context': {
        'type': 'string',
        'description':
            'Relevant code, file contents, or other context the subagent needs.',
      },
    },
    'required': ['agent', 'task', 'context'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) {
    throw ToolError(
      name,
      'delegate_to_subagent must be intercepted by the agent loop before execute() is reached.',
    );
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final agent = args['agent'] as String? ?? 'unknown';
    final task = args['task'] as String? ?? '';
    return DryRunResult(
      preview: '[DRY RUN] Would delegate to $agent: $task',
      riskLevel: riskLevel,
    );
  }
}
