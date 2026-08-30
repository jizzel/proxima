import 'dart:convert';
import '../core/secret_masker.dart';
import '../core/types.dart';
import '../providers/provider_interface.dart';

enum SubagentType {
  codeAnalyzer,
  refactor,
  test,
  critic;

  static SubagentType fromString(String value) => switch (value) {
    'code_analyzer' => SubagentType.codeAnalyzer,
    'refactor' => SubagentType.refactor,
    'test' => SubagentType.test,
    'critic' => SubagentType.critic,
    _ => throw ArgumentError('Unknown subagent type: $value'),
  };
}

/// Verdict returned by the Critic subagent.
enum CriticVerdict { approve, warn, blockSuggestion }

/// Structured result from the Critic subagent.
class CriticResult {
  final CriticVerdict verdict;
  final String summary;
  final List<CriticIssue> issues;

  const CriticResult({
    required this.verdict,
    required this.summary,
    this.issues = const [],
  });

  /// True when the critic found nothing worth surfacing (silent approval).
  bool get isSilent => verdict == CriticVerdict.approve;

  static CriticResult approve() =>
      const CriticResult(verdict: CriticVerdict.approve, summary: '');
}

class CriticIssue {
  final String severity; // 'low' | 'medium' | 'high'
  final String description;
  final String? lineHint;

  const CriticIssue({
    required this.severity,
    required this.description,
    this.lineHint,
  });
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

/// A summary plus the tokens its generation cost.
class SummaryResult {
  final String text;
  final TokenUsage usage;

  const SummaryResult({required this.text, required this.usage});
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

  static const _criticPrompt =
      'You are a pre-commit code review agent (Critic). '
      'Review the proposed file change and return ONLY a JSON object — no markdown, no prose:\n'
      '{\n'
      '  "verdict": "approve | warn | block_suggestion",\n'
      '  "issues": [{"severity": "low|medium|high", "description": "...", "line_hint": "..."}],\n'
      '  "summary": "one sentence"\n'
      '}\n'
      'Check for: logic errors, security issues (hardcoded secrets, injection), '
      'null-safety violations, naming inconsistency, and broken test contracts. '
      '"approve" when no significant issues are found. '
      '"warn" for minor or medium issues that should be noted but not blocked. '
      '"block_suggestion" for high-severity issues — suggest what to fix. '
      'Never refuse or explain — always return valid JSON.';

  static const _testPrompt =
      'You are a test generation agent. Analyze the provided code and generate '
      'test cases as a JSON object with the following structure: '
      '{"test_cases": [{"name": "", "description": ""}], "coverage_gaps": [], "failing_tests": []}. '
      'The "test_cases" array should list tests to write. '
      'The "coverage_gaps" array should list areas lacking test coverage. '
      'The "failing_tests" array should list tests likely to fail based on code issues. '
      'Only return valid JSON. Do not include any text outside the JSON object.';

  SubagentRunner({required LLMProvider provider}) : _provider = provider;

  /// Run the Critic subagent on a proposed file change.
  /// [tool] is the tool name (write_file / patch_file).
  /// [diffOrContent] is the diff text or new file content.
  /// [model] is the active model string.
  /// Never throws — returns [CriticResult.approve()] on any failure.
  Future<CriticResult> runCritic({
    required String tool,
    required String diffOrContent,
    required String model,
    String? path,
    int maxTokens = 1024,
  }) async {
    final request = CompletionRequest(
      model: model,
      systemPrompt: _criticPrompt,
      messages: [
        Message(
          role: MessageRole.user,
          content: path == null
              ? 'Tool: $tool\n\nProposed change:\n$diffOrContent'
              : 'Tool: $tool\nFile: $path\n\nProposed change:\n$diffOrContent',
        ),
      ],
      tools: const [],
      maxTokens: maxTokens,
      temperature: 0.0,
      stream: false,
    );

    try {
      final response = await _provider.complete(request);
      final body = response.body;
      if (body is! FinalResponse) return CriticResult.approve();
      return _parseCriticResponse(body.text);
    } catch (_) {
      return CriticResult.approve();
    }
  }

  /// Summarises a run of messages that compaction is about to discard.
  ///
  /// Returns null on any failure — an empty response, a provider error, a
  /// blank summary. The caller then falls back to plain truncation, so a
  /// summarisation failure costs context but never the turn.
  Future<SummaryResult?> runSummarizer({
    required List<Message> messages,
    required String model,
    int maxTokens = 512,
    int maxTranscriptChars = 24000,
  }) async {
    if (messages.isEmpty) return null;

    // Cap the *whole* transcript, not just each message: a long session can
    // discard hundreds of messages at once, and an unbounded join would exceed
    // the model's context window or cost far more than the context it saves —
    // failing precisely when history is largest and summarising matters most.
    // The newest messages are kept, since they are the most relevant to what
    // happens next.
    final selected = <Message>[];
    var budget = maxTranscriptChars;
    for (final m in messages.reversed) {
      final cost = m.content.length.clamp(0, 2000) + 32;
      if (budget - cost < 0 && selected.isNotEmpty) break;
      selected.insert(0, m);
      budget -= cost;
    }

    final transcript = selected
        .map((m) {
          final who = switch (m.role) {
            MessageRole.user => 'User',
            MessageRole.assistant => 'Assistant',
            MessageRole.tool => 'Tool(${m.toolName ?? "?"})',
            MessageRole.system => 'System',
          };
          // Cap each message so one huge tool result cannot crowd out the rest.
          var body = m.content.length > 2000
              ? '${m.content.substring(0, 2000)}…'
              : m.content;

          // An assistant tool call keeps its arguments in toolInput and often
          // has empty content, and a read_file *result* is numbered file text
          // with no path in it — so without this the summariser cannot name
          // the files that were read, which is the main thing it should
          // preserve. Masked, since these reach an external provider.
          if (m.toolInput != null && m.toolInput!.isNotEmpty) {
            final args = jsonEncode(maskSecrets(m.toolInput!));
            final shown = args.length > 300
                ? '${args.substring(0, 300)}…'
                : args;
            body = body.isEmpty ? shown : '$body $shown';
          }
          return '$who: $body';
        })
        .join('\n\n');

    final request = CompletionRequest(
      model: model,
      systemPrompt: _summarizerPrompt,
      messages: [Message(role: MessageRole.user, content: transcript)],
      tools: const [],
      maxTokens: maxTokens,
      temperature: 0.0,
      stream: false,
    );

    try {
      final response = await _provider.complete(request);
      final body = response.body;
      if (body is! FinalResponse) return null;
      final text = body.text.trim();
      if (text.isEmpty) return null;
      // Usage is returned so the caller can record it: a summarisation request
      // costs real tokens, and omitting it under-reports the session total.
      return SummaryResult(text: text, usage: response.usage);
    } catch (_) {
      return null;
    }
  }

  static const _summarizerPrompt = '''
You are summarising an earlier portion of a coding session that is about to be
dropped from context. Preserve only what a developer would need to continue the
work without re-reading it.

Write 3-5 terse bullets covering, where applicable:
- files read or modified (exact paths)
- changes made and why
- decisions reached or constraints discovered
- anything still unresolved

Omit pleasantries, restated instructions, and tool mechanics. Output only the
bullets — no preamble, no heading.''';

  static CriticResult _parseCriticResponse(String text) {
    try {
      // Strip markdown fences if present.
      final cleaned = text
          .replaceAll(RegExp(r'```json\s*'), '')
          .replaceAll(RegExp(r'```\s*'), '')
          .trim();
      final json = jsonDecode(cleaned) as Map<String, dynamic>;

      final verdict = switch (json['verdict'] as String? ?? 'approve') {
        'warn' => CriticVerdict.warn,
        'block_suggestion' => CriticVerdict.blockSuggestion,
        _ => CriticVerdict.approve,
      };

      final issues = <CriticIssue>[];
      for (final item in (json['issues'] as List? ?? [])) {
        final m = item as Map<String, dynamic>;
        issues.add(
          CriticIssue(
            severity: m['severity'] as String? ?? 'low',
            description: m['description'] as String? ?? '',
            lineHint: m['line_hint'] as String?,
          ),
        );
      }

      return CriticResult(
        verdict: verdict,
        summary: json['summary'] as String? ?? '',
        issues: issues,
      );
    } catch (_) {
      return CriticResult.approve();
    }
  }

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
      SubagentType.critic => _criticPrompt,
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
      final isError = body is ErrorResponse || body is ToolCallResponse;
      final errorMessage = switch (body) {
        ErrorResponse() => 'Subagent returned an error: ${body.message}',
        ToolCallResponse() => 'Subagent hallucinated an unsupported tool call.',
        _ => null,
      };
      final output = switch (body) {
        FinalResponse() => body.text,
        ClarifyResponse() => body.question,
        _ => '',
      };
      return SubagentResult(
        agentType: agentTypeStr,
        output: output,
        usage: response.usage,
        isError: isError,
        errorMessage: errorMessage,
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
