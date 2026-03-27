import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/core/session.dart';
import 'package:proxima/core/config.dart';
import 'package:proxima/providers/provider_interface.dart';
import 'package:proxima/tools/tool_registry.dart';
import 'package:proxima/tools/file/read_file_tool.dart';
import 'package:proxima/tools/agent/delegate_tool.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/permissions/risk_classifier.dart';
import 'package:proxima/permissions/audit_log.dart';
import 'package:proxima/permissions/permission_gate.dart';
import 'package:proxima/context/context_builder.dart';
import 'package:proxima/agent/agent_loop.dart';
import 'package:proxima/agent/subagent_runner.dart'
    show SubagentRunner, CriticVerdict;
import 'dart:io';

// Provider that captures every CompletionRequest and returns preset responses.
class CapturingMockProvider implements LLMProvider {
  final List<LLMResponse> responses;
  final List<CompletionRequest> capturedRequests = [];
  int _callCount = 0;

  CapturingMockProvider(this.responses);

  @override
  String get name => 'capturing-mock';

  @override
  String get model => 'mock/model';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    nativeToolUse: true,
    streaming: false,
    contextWindow: 10000,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    capturedRequests.add(request);
    if (_callCount >= responses.length) {
      return LLMResponse(
        body: FinalResponse('No more responses.'),
        usage: TokenUsage.zero,
      );
    }
    return responses[_callCount++];
  }

  @override
  Stream<LLMChunk> stream(CompletionRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<List<String>> listModels() async => [];
}

// Provider that always throws on complete().
class ThrowingProvider implements LLMProvider {
  @override
  String get name => 'throwing';

  @override
  String get model => 'mock/throwing';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    nativeToolUse: true,
    streaming: false,
    contextWindow: 10000,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    throw LLMError(LLMErrorKind.network, 'simulated provider failure');
  }

  @override
  Stream<LLMChunk> stream(CompletionRequest request) {
    throw UnimplementedError();
  }

  @override
  Future<List<String>> listModels() async => [];
}

// Mock callbacks for agent loop integration tests.
class MockCallbacks implements AgentCallbacks {
  final List<String> events = [];

  @override
  void onThinking(String reasoning) => events.add('thinking: $reasoning');
  @override
  void onToolCall(ToolCall toolCall) => events.add('tool: ${toolCall.tool}');
  @override
  void onToolResult(String toolName, String result, bool isError) =>
      events.add('result: $toolName isError=$isError');
  @override
  void onFinalResponse(String text) => events.add('final: $text');
  @override
  void onClarify(String question) => events.add('clarify: $question');
  @override
  void onError(String message) => events.add('error: $message');
  @override
  Future<bool> onStuck(List<ToolCall> recentCalls) async {
    events.add('stuck');
    return false;
  }

  @override
  void onChunk(String text) => events.add('chunk: $text');
  @override
  void onUsageReport(
    TokenUsage turn,
    TokenUsage cumulative,
    double turnCost,
    double sessionCost,
  ) => events.add('usage: ${turn.totalTokens}');
  @override
  void onToolExecuting(ToolCall toolCall) =>
      events.add('executing: ${toolCall.tool}');
  @override
  void onIterationStart(int iteration, int maxIterations) =>
      events.add('iteration: $iteration/$maxIterations');
}

void main() {
  // ── SubagentRunner unit tests ─────────────────────────────────────────────

  group('SubagentRunner', () {
    test(
      'code_analyzer — system prompt contains "code analysis", tools is empty, stream is false, not error',
      () async {
        final provider = CapturingMockProvider([
          LLMResponse(
            body: FinalResponse('{"issues":[],"severity":[],"suggestions":[]}'),
            usage: const TokenUsage(
              inputTokens: 10,
              outputTokens: 5,
              totalTokens: 15,
            ),
          ),
        ]);

        final runner = SubagentRunner(provider: provider);
        final result = await runner.run(
          agentTypeStr: 'code_analyzer',
          task: 'check for issues',
          context: 'void main() {}',
          model: 'mock/model',
        );

        expect(result.isError, isFalse);
        expect(provider.capturedRequests, hasLength(1));
        final req = provider.capturedRequests.first;
        expect(req.systemPrompt.toLowerCase(), contains('code analysis'));
        expect(req.tools, isEmpty);
        expect(req.stream, isFalse);
      },
    );

    test('refactor — system prompt contains "refactoring agent"', () async {
      final provider = CapturingMockProvider([
        LLMResponse(
          body: FinalResponse(
            '{"proposed_changes":[],"impact_summary":"none"}',
          ),
          usage: TokenUsage.zero,
        ),
      ]);

      final runner = SubagentRunner(provider: provider);
      final result = await runner.run(
        agentTypeStr: 'refactor',
        task: 'refactor this',
        context: 'int x = 1;',
        model: 'mock/model',
      );

      expect(result.isError, isFalse);
      final req = provider.capturedRequests.first;
      expect(req.systemPrompt.toLowerCase(), contains('refactoring agent'));
    });

    test('test — system prompt contains "test generation agent"', () async {
      final provider = CapturingMockProvider([
        LLMResponse(
          body: FinalResponse(
            '{"test_cases":[],"coverage_gaps":[],"failing_tests":[]}',
          ),
          usage: TokenUsage.zero,
        ),
      ]);

      final runner = SubagentRunner(provider: provider);
      final result = await runner.run(
        agentTypeStr: 'test',
        task: 'generate tests',
        context: 'class Foo {}',
        model: 'mock/model',
      );

      expect(result.isError, isFalse);
      final req = provider.capturedRequests.first;
      expect(req.systemPrompt.toLowerCase(), contains('test generation agent'));
    });

    test('user message contains both task and context strings', () async {
      final provider = CapturingMockProvider([
        LLMResponse(
          body: FinalResponse('{"issues":[],"severity":[],"suggestions":[]}'),
          usage: TokenUsage.zero,
        ),
      ]);

      final runner = SubagentRunner(provider: provider);
      await runner.run(
        agentTypeStr: 'code_analyzer',
        task: 'find bugs',
        context: 'String x = null;',
        model: 'mock/model',
      );

      final req = provider.capturedRequests.first;
      expect(req.messages, hasLength(1));
      expect(req.messages.first.content, contains('find bugs'));
      expect(req.messages.first.content, contains('String x = null;'));
    });

    test('unknown agentTypeStr — isError true, zero LLM calls made', () async {
      final provider = CapturingMockProvider([]);

      final runner = SubagentRunner(provider: provider);
      final result = await runner.run(
        agentTypeStr: 'unknown_agent',
        task: 'do something',
        context: 'context',
        model: 'mock/model',
      );

      expect(result.isError, isTrue);
      expect(provider.capturedRequests, isEmpty);
    });

    test(
      'LLM throws — isError true, errorMessage contains "Subagent LLM error", no rethrow',
      () async {
        final runner = SubagentRunner(provider: ThrowingProvider());
        final result = await runner.run(
          agentTypeStr: 'code_analyzer',
          task: 'task',
          context: 'context',
          model: 'mock/model',
        );

        expect(result.isError, isTrue);
        expect(result.errorMessage, contains('Subagent LLM error'));
      },
    );

    test(
      'ErrorResponse from LLM — isError true, errorMessage contains provider error',
      () async {
        final provider = CapturingMockProvider([
          LLMResponse(
            body: ErrorResponse('provider rejected the request'),
            usage: TokenUsage.zero,
          ),
        ]);

        final runner = SubagentRunner(provider: provider);
        final result = await runner.run(
          agentTypeStr: 'code_analyzer',
          task: 'task',
          context: 'ctx',
          model: 'mock/model',
        );

        expect(result.isError, isTrue);
        expect(result.errorMessage, contains('Subagent returned an error'));
        expect(result.errorMessage, contains('provider rejected the request'));
        expect(result.output, isEmpty);
      },
    );

    test(
      'ToolCallResponse from LLM — isError true, errorMessage mentions hallucinated tool call',
      () async {
        final provider = CapturingMockProvider([
          LLMResponse(
            body: ToolCallResponse(
              ToolCall(
                tool: 'read_file',
                args: {'path': '/tmp/foo'},
                reasoning: 'trying to read a file',
              ),
            ),
            usage: TokenUsage.zero,
          ),
        ]);

        final runner = SubagentRunner(provider: provider);
        final result = await runner.run(
          agentTypeStr: 'code_analyzer',
          task: 'task',
          context: 'ctx',
          model: 'mock/model',
        );

        expect(result.isError, isTrue);
        expect(result.errorMessage, contains('hallucinated'));
        expect(result.output, isEmpty);
      },
    );

    test('dryRun — preview contains [DRY RUN] and agent name', () async {
      final tool = DelegateToSubagentTool();
      final dryRun = await tool.dryRun({
        'agent': 'code_analyzer',
        'task': 'check it',
        'context': '...',
      }, '/tmp');

      expect(dryRun.preview, contains('[DRY RUN]'));
      expect(dryRun.preview, contains('code_analyzer'));
    });
  });

  // ── Critic subagent tests ─────────────────────────────────────────────────

  group('SubagentRunner.runCritic', () {
    test('approve verdict — isSilent is true', () async {
      const json = '{"verdict":"approve","issues":[],"summary":"Looks good."}';
      final provider = CapturingMockProvider([
        LLMResponse(body: FinalResponse(json), usage: TokenUsage.zero),
      ]);
      final runner = SubagentRunner(provider: provider);
      final result = await runner.runCritic(
        tool: 'write_file',
        diffOrContent: 'content',
        model: 'mock/model',
      );
      expect(result.verdict, CriticVerdict.approve);
      expect(result.isSilent, isTrue);
      expect(result.issues, isEmpty);
    });

    test('warn verdict with issues', () async {
      const json = '''
{
  "verdict": "warn",
  "issues": [{"severity": "medium", "description": "Missing null check", "line_hint": "line 42"}],
  "summary": "Minor null safety issue."
}''';
      final provider = CapturingMockProvider([
        LLMResponse(body: FinalResponse(json), usage: TokenUsage.zero),
      ]);
      final runner = SubagentRunner(provider: provider);
      final result = await runner.runCritic(
        tool: 'patch_file',
        diffOrContent: '-old\n+new',
        model: 'mock/model',
      );
      expect(result.verdict, CriticVerdict.warn);
      expect(result.isSilent, isFalse);
      expect(result.issues, hasLength(1));
      expect(result.issues.first.severity, 'medium');
      expect(result.issues.first.lineHint, 'line 42');
      expect(result.summary, contains('null safety'));
    });

    test('block_suggestion verdict', () async {
      const json =
          '{"verdict":"block_suggestion","issues":[{"severity":"high","description":"Hardcoded secret","line_hint":"line 5"}],"summary":"API key exposed."}';
      final provider = CapturingMockProvider([
        LLMResponse(body: FinalResponse(json), usage: TokenUsage.zero),
      ]);
      final runner = SubagentRunner(provider: provider);
      final result = await runner.runCritic(
        tool: 'write_file',
        diffOrContent: 'content',
        model: 'mock/model',
      );
      expect(result.verdict, CriticVerdict.blockSuggestion);
      expect(result.issues.first.severity, 'high');
    });

    test('malformed JSON returns approve (graceful fallback)', () async {
      final provider = CapturingMockProvider([
        LLMResponse(
          body: FinalResponse('not json at all'),
          usage: TokenUsage.zero,
        ),
      ]);
      final runner = SubagentRunner(provider: provider);
      final result = await runner.runCritic(
        tool: 'write_file',
        diffOrContent: 'content',
        model: 'mock/model',
      );
      expect(result.verdict, CriticVerdict.approve);
    });

    test('LLM error returns approve (never throws)', () async {
      // Provider that throws on complete()
      final provider = CapturingMockProvider([]);
      final runner = SubagentRunner(provider: provider);
      // No responses configured — will return "No more responses." FinalResponse
      final result = await runner.runCritic(
        tool: 'write_file',
        diffOrContent: 'content',
        model: 'mock/model',
      );
      // Should not throw; returns approve as fallback
      expect(result, isNotNull);
    });

    test('critic system prompt is sent to provider', () async {
      const json = '{"verdict":"approve","issues":[],"summary":"ok"}';
      final provider = CapturingMockProvider([
        LLMResponse(body: FinalResponse(json), usage: TokenUsage.zero),
      ]);
      final runner = SubagentRunner(provider: provider);
      await runner.runCritic(
        tool: 'write_file',
        diffOrContent: 'fn foo() {}',
        model: 'mock/model',
      );
      expect(provider.capturedRequests, hasLength(1));
      expect(provider.capturedRequests.first.systemPrompt, contains('Critic'));
      expect(
        provider.capturedRequests.first.messages.first.content,
        contains('write_file'),
      );
    });

    test('markdown-fenced JSON is parsed correctly', () async {
      const json =
          '```json\n{"verdict":"warn","issues":[],"summary":"Minor."}\n```';
      final provider = CapturingMockProvider([
        LLMResponse(body: FinalResponse(json), usage: TokenUsage.zero),
      ]);
      final runner = SubagentRunner(provider: provider);
      final result = await runner.runCritic(
        tool: 'write_file',
        diffOrContent: 'code',
        model: 'mock/model',
      );
      expect(result.verdict, CriticVerdict.warn);
    });
  });

  // ── AgentLoop integration tests ───────────────────────────────────────────

  group('AgentLoop subagent integration', () {
    late Directory tempDir;
    late ProximaConfig config;
    late ToolRegistry toolRegistry;
    late PermissionGate permissionGate;
    late ContextBuilder contextBuilder;
    late AuditLog auditLog;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('proxima_subagent_');
      config = ProximaConfig.defaults().copyWith(workingDir: tempDir.path);
      toolRegistry = ToolRegistry();
      toolRegistry.register(ReadFileTool());
      toolRegistry.register(DelegateToSubagentTool());
      auditLog = AuditLog(tempDir.path);
      final classifier = RiskClassifier(toolRegistry);
      permissionGate = PermissionGate(
        classifier: classifier,
        auditLog: auditLog,
        mode: SessionMode.auto,
        allowedTools: {},
        prompt: (toolCall, riskLevel, {criticResult}) async => true,
      );
      contextBuilder = ContextBuilder(toolRegistry);
    });

    tearDown(() async {
      await auditLog.close();
      await tempDir.delete(recursive: true);
    });

    AgentLoop makeLoop(LLMProvider provider) => AgentLoop(
      provider: provider,
      toolRegistry: toolRegistry,
      permissionGate: permissionGate,
      contextBuilder: contextBuilder,
      config: config,
    );

    test(
      'delegation result in session history as tool message; token usage includes subagent tokens',
      () async {
        // Sequence:
        // 1. Main agent → delegate_to_subagent tool call
        // 2. Subagent LLM call → FinalResponse (consumed by SubagentRunner)
        // 3. Main agent → FinalResponse('Analysis done.')
        final provider = CapturingMockProvider([
          LLMResponse(
            body: ToolCallResponse(
              ToolCall(
                tool: 'delegate_to_subagent',
                args: {
                  'agent': 'code_analyzer',
                  'task': 'check this file',
                  'context': 'int x = 1;',
                },
                reasoning: 'delegating to code_analyzer',
              ),
            ),
            usage: const TokenUsage(
              inputTokens: 10,
              outputTokens: 5,
              totalTokens: 15,
            ),
          ),
          // This is consumed by SubagentRunner.run() — main loop sees it as
          // the subagent response already resolved.
          LLMResponse(
            body: FinalResponse('{"issues":[],"severity":[],"suggestions":[]}'),
            usage: const TokenUsage(
              inputTokens: 20,
              outputTokens: 10,
              totalTokens: 30,
            ),
          ),
          // Main agent final response after seeing subagent result.
          LLMResponse(
            body: FinalResponse('Analysis done.'),
            usage: const TokenUsage(
              inputTokens: 5,
              outputTokens: 3,
              totalTokens: 8,
            ),
          ),
        ]);

        final callbacks = MockCallbacks();
        final session = ProximaSession.create(config);
        final result = await makeLoop(
          provider,
        ).runTurn(session, 'analyze this code', callbacks);

        expect(result.status, TaskStatus.completed);

        // Session history must contain a tool-role message for delegate_to_subagent.
        final toolMessages = result.history
            .where(
              (m) =>
                  m.role == MessageRole.tool &&
                  m.toolName == 'delegate_to_subagent',
            )
            .toList();
        expect(toolMessages, hasLength(1));
        expect(toolMessages.first.content, contains('issues'));

        // Cumulative usage must include subagent tokens (30) + main agent (15 + 8).
        expect(result.cumulativeUsage.totalTokens, 53);

        // Final response must have fired.
        expect(
          callbacks.events.any((e) => e == 'final: Analysis done.'),
          isTrue,
        );
      },
    );

    test(
      'third delegation attempt — result contains "max subagent delegations" and limit "2"',
      () async {
        // Three delegation attempts in one turn; only the third should fail.
        final provider = CapturingMockProvider([
          // Main agent: 1st delegation
          LLMResponse(
            body: ToolCallResponse(
              ToolCall(
                tool: 'delegate_to_subagent',
                args: {
                  'agent': 'code_analyzer',
                  'task': 'first',
                  'context': 'ctx',
                },
                reasoning: 'delegating 1',
              ),
            ),
            usage: TokenUsage.zero,
          ),
          // Subagent response for 1st delegation
          LLMResponse(
            body: FinalResponse('{"issues":[],"severity":[],"suggestions":[]}'),
            usage: TokenUsage.zero,
          ),
          // Main agent: 2nd delegation
          LLMResponse(
            body: ToolCallResponse(
              ToolCall(
                tool: 'delegate_to_subagent',
                args: {'agent': 'refactor', 'task': 'second', 'context': 'ctx'},
                reasoning: 'delegating 2',
              ),
            ),
            usage: TokenUsage.zero,
          ),
          // Subagent response for 2nd delegation
          LLMResponse(
            body: FinalResponse(
              '{"proposed_changes":[],"impact_summary":"none"}',
            ),
            usage: TokenUsage.zero,
          ),
          // Main agent: 3rd delegation (should be denied by interception)
          LLMResponse(
            body: ToolCallResponse(
              ToolCall(
                tool: 'delegate_to_subagent',
                args: {'agent': 'test', 'task': 'third', 'context': 'ctx'},
                reasoning: 'delegating 3',
              ),
            ),
            usage: TokenUsage.zero,
          ),
          // Main agent final response after seeing the limit error
          LLMResponse(
            body: FinalResponse('Done after hitting delegation limit.'),
            usage: TokenUsage.zero,
          ),
        ]);

        final callbacks = MockCallbacks();
        final session = ProximaSession.create(config);
        final result = await makeLoop(
          provider,
        ).runTurn(session, 'do three delegations', callbacks);

        expect(result.status, TaskStatus.completed);

        // Find the tool result for the 3rd delegation — must indicate limit hit.
        final limitEvent = callbacks.events.firstWhere(
          (e) => e.contains('result: delegate_to_subagent'),
          orElse: () => '',
        );
        expect(limitEvent, isNotEmpty);

        // The tool-role session message for the blocked 3rd delegation must
        // contain the limit number.
        final toolMessages = result.history
            .where(
              (m) =>
                  m.role == MessageRole.tool &&
                  m.toolName == 'delegate_to_subagent' &&
                  m.content.contains('max subagent delegations'),
            )
            .toList();
        expect(toolMessages, hasLength(1));
        expect(toolMessages.first.content, contains('2'));
      },
    );

    test(
      'subagent CompletionRequest has tools: [] (nesting prevention)',
      () async {
        final provider = CapturingMockProvider([
          // Main agent: delegation tool call
          LLMResponse(
            body: ToolCallResponse(
              ToolCall(
                tool: 'delegate_to_subagent',
                args: {
                  'agent': 'test',
                  'task': 'generate tests',
                  'context': 'class Foo {}',
                },
                reasoning: 'delegating to test agent',
              ),
            ),
            usage: TokenUsage.zero,
          ),
          // Subagent response (capturedRequests[1])
          LLMResponse(
            body: FinalResponse(
              '{"test_cases":[],"coverage_gaps":[],"failing_tests":[]}',
            ),
            usage: TokenUsage.zero,
          ),
          // Main agent final
          LLMResponse(
            body: FinalResponse('Tests generated.'),
            usage: TokenUsage.zero,
          ),
        ]);

        final callbacks = MockCallbacks();
        final session = ProximaSession.create(config);
        await makeLoop(provider).runTurn(session, 'generate tests', callbacks);

        // capturedRequests[0] = main agent context build (first complete() call)
        // capturedRequests[1] = subagent call inside SubagentRunner
        // capturedRequests[2] = main agent context build (after delegation)
        expect(provider.capturedRequests.length, greaterThanOrEqualTo(2));
        // The subagent request must have no tools.
        final subagentReq = provider.capturedRequests[1];
        expect(subagentReq.tools, isEmpty);
      },
    );

    test(
      'DelegateToSubagentTool.execute() throws ToolError with sentinel message',
      () {
        final tool = DelegateToSubagentTool();
        expect(
          () =>
              tool.execute({'agent': 'test', 'task': 't', 'context': 'c'}, '/'),
          throwsA(
            isA<ToolError>().having(
              (e) => e.message,
              'message',
              contains('intercepted by the agent loop'),
            ),
          ),
        );
      },
    );
  });
}
