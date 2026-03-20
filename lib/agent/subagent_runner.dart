import '../core/types.dart';
import '../providers/provider_interface.dart';

enum SubagentType {
  codeAnalyzer,
  refactor,
  test;

  static SubagentType fromString(String value) => switch (value) {
    'code_analyzer' => SubagentType.codeAnalyzer,
    'refactor' => SubagentType.refactor,
    'test' => SubagentType.test,
    _ => throw ArgumentError('Unknown subagent type: $value'),
  };
}

class SubagentResult {
  final String agentType;
  final String output;
  final TokenUsage usage;
  final bool isError;
  final String? errorMessage;

  const SubagentResult({
    required this.agentType,
    required this.output,
    required this.usage,
    required this.isError,
    this.errorMessage,
  });
}

class SubagentRunner {
  final LLMProvider _provider;

  static const _codeAnalyzerPrompt =
      'You are a code analysis agent. Analyze the provided code and return your '
      'findings as a JSON object with the following structure: '
      '{"issues": [], "severity": [], "suggestions": []}. '
      'The "issues" array should list specific problems found. '
      'The "severity" array should list severity levels (low/medium/high) for each issue. '
      'The "suggestions" array should list actionable improvement suggestions. '
      'Only return valid JSON. Do not include any text outside the JSON object.';

  static const _refactorPrompt =
      'You are a refactoring agent. Analyze the provided code and propose '
      'refactoring changes as a JSON object with the following structure: '
      '{"proposed_changes": [{"file": "", "diff": "", "reason": ""}], "impact_summary": ""}. '
      'Each entry in "proposed_changes" should include the file path, a unified diff, '
      'and the reason for the change. The "impact_summary" should describe overall impact. '
      'Only return valid JSON. Do not include any text outside the JSON object.';

  static const _testPrompt =
      'You are a test generation agent. Analyze the provided code and generate '
      'test cases as a JSON object with the following structure: '
      '{"test_cases": [{"name": "", "description": ""}], "coverage_gaps": [], "failing_tests": []}. '
      'The "test_cases" array should list tests to write. '
      'The "coverage_gaps" array should list areas lacking test coverage. '
      'The "failing_tests" array should list tests likely to fail based on code issues. '
      'Only return valid JSON. Do not include any text outside the JSON object.';

  SubagentRunner({required LLMProvider provider}) : _provider = provider;

  Future<SubagentResult> run({
    required String agentTypeStr,
    required String task,
    required String context,
    required String model,
  }) async {
    SubagentType agentType;
    try {
      agentType = SubagentType.fromString(agentTypeStr);
    } catch (_) {
      return SubagentResult(
        agentType: agentTypeStr,
        output: '',
        usage: TokenUsage.zero,
        isError: true,
        errorMessage: 'Unknown subagent type: $agentTypeStr',
      );
    }

    final systemPrompt = switch (agentType) {
      SubagentType.codeAnalyzer => _codeAnalyzerPrompt,
      SubagentType.refactor => _refactorPrompt,
      SubagentType.test => _testPrompt,
    };

    final request = CompletionRequest(
      model: model,
      systemPrompt: systemPrompt,
      messages: [
        Message(
          role: MessageRole.user,
          content: 'Task: $task\n\nContext:\n$context',
        ),
      ],
      tools: const [],
      maxTokens: 4096,
      temperature: 0.0,
      stream: false,
    );

    try {
      final response = await _provider.complete(request);
      final body = response.body;
      final output = switch (body) {
        FinalResponse() => body.text,
        ToolCallResponse() => body.toolCall.toString(),
        ClarifyResponse() => body.question,
        ErrorResponse() => body.message,
      };
      return SubagentResult(
        agentType: agentTypeStr,
        output: output,
        usage: response.usage,
        isError: false,
      );
    } catch (e) {
      return SubagentResult(
        agentType: agentTypeStr,
        output: '',
        usage: TokenUsage.zero,
        isError: true,
        errorMessage: 'Subagent LLM error: $e',
      );
    }
  }
}
