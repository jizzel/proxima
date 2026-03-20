import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/core/session.dart';
import 'package:proxima/core/config.dart';
import 'package:proxima/providers/provider_interface.dart';
import 'package:proxima/tools/tool_registry.dart';
import 'package:proxima/tools/file/read_file_tool.dart';
import 'package:proxima/permissions/risk_classifier.dart';
import 'package:proxima/permissions/audit_log.dart';
import 'package:proxima/permissions/permission_gate.dart';
import 'package:proxima/context/context_builder.dart';
import 'package:proxima/agent/agent_loop.dart';
import 'dart:io';

// Mock provider that returns predetermined responses (non-streaming).
class MockProvider implements LLMProvider {
  final List<LLMResponse> responses;
  int _callCount = 0;

  MockProvider(this.responses);

  @override
  String get name => 'mock';

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

// Mock streaming provider that emits chunks for a final response.
class MockStreamingProvider implements LLMProvider {
  final List<LLMChunk> chunks;

  /// If set, complete() is called as fallback and tracked here.
  bool completeCalled = false;

  MockStreamingProvider({required this.chunks});

  @override
  String get name => 'mock-streaming';

  @override
  String get model => 'mock/streaming-model';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    nativeToolUse: true,
    streaming: true,
    contextWindow: 10000,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    completeCalled = true;
    return LLMResponse(
      body: FinalResponse('fallback complete response'),
      usage: const TokenUsage(inputTokens: 5, outputTokens: 5, totalTokens: 10),
    );
  }

  @override
  Stream<LLMChunk> stream(CompletionRequest request) async* {
    for (final chunk in chunks) {
      yield chunk;
    }
  }

  @override
  Future<List<String>> listModels() async => [];
}

// Streaming provider whose stream() always throws to exercise fallback.
class MockStreamingFailProvider implements LLMProvider {
  bool completeCalled = false;

  @override
  String get name => 'mock-streaming-fail';

  @override
  String get model => 'mock/streaming-fail-model';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    nativeToolUse: true,
    streaming: true,
    contextWindow: 10000,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    completeCalled = true;
    return LLMResponse(
      body: FinalResponse('fallback response after stream error'),
      usage: const TokenUsage(inputTokens: 5, outputTokens: 5, totalTokens: 10),
    );
  }

  @override
  Stream<LLMChunk> stream(CompletionRequest request) async* {
    throw LLMError(LLMErrorKind.network, 'simulated stream failure');
  }

  @override
  Future<List<String>> listModels() async => [];
}

// Mock callbacks that capture events.
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
    return false; // abort by default in tests
  }

  @override
  void onChunk(String text) => events.add('chunk: $text');
}

void main() {
  late Directory tempDir;
  late ProximaConfig config;
  late ToolRegistry toolRegistry;
  late PermissionGate permissionGate;
  late ContextBuilder contextBuilder;
  late AuditLog auditLog;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_agent_');
    config = ProximaConfig.defaults().copyWith(workingDir: tempDir.path);
    toolRegistry = ToolRegistry();
    toolRegistry.register(ReadFileTool());
    auditLog = AuditLog(tempDir.path);
    final classifier = RiskClassifier(toolRegistry);
    permissionGate = PermissionGate(
      classifier: classifier,
      auditLog: auditLog,
      mode: SessionMode.auto,
      allowedTools: {},
      prompt: (toolCall, riskLevel) async => true,
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

  test('final response after one tool call', () async {
    // Create a test file.
    final file = File('${tempDir.path}/hello.txt');
    await file.writeAsString('hello world');

    final provider = MockProvider([
      LLMResponse(
        body: ToolCallResponse(
          ToolCall(
            tool: 'read_file',
            args: {'path': 'hello.txt'},
            reasoning: 'reading file',
          ),
        ),
        usage: const TokenUsage(
          inputTokens: 10,
          outputTokens: 5,
          totalTokens: 15,
        ),
      ),
      LLMResponse(
        body: FinalResponse('The file contains: hello world'),
        usage: const TokenUsage(
          inputTokens: 20,
          outputTokens: 10,
          totalTokens: 30,
        ),
      ),
    ]);

    final callbacks = MockCallbacks();
    final session = ProximaSession.create(config);
    final result = await makeLoop(
      provider,
    ).runTurn(session, 'read hello.txt', callbacks);

    expect(result.status, TaskStatus.completed);
    expect(
      callbacks.events.any((e) => e.startsWith('tool: read_file')),
      isTrue,
    );
    expect(callbacks.events.any((e) => e.startsWith('final:')), isTrue);
    expect(result.cumulativeUsage.totalTokens, 45);
  });

  test('detects stuck agent', () async {
    // Provider always returns the same tool call.
    final provider = MockProvider(
      List.generate(
        10,
        (_) => LLMResponse(
          body: ToolCallResponse(
            ToolCall(tool: 'list_files', args: {}, reasoning: 'listing files'),
          ),
          usage: TokenUsage.zero,
        ),
      ),
    );

    final callbacks = MockCallbacks();
    final session = ProximaSession.create(config);
    final result = await makeLoop(
      provider,
    ).runTurn(session, 'do something', callbacks);

    expect(result.status, TaskStatus.failed);
    expect(callbacks.events.any((e) => e == 'stuck'), isTrue);
  });

  test('max iterations reached', () async {
    // Provider always returns tool calls, never final.
    final calls = List.generate(
      15,
      (i) => LLMResponse(
        body: ToolCallResponse(
          ToolCall(
            tool: 'read_file',
            args: {'path': 'file_$i.txt'},
            reasoning: 'reading',
          ),
        ),
        usage: TokenUsage.zero,
      ),
    );

    final provider = MockProvider(calls);
    final callbacks = MockCallbacks();
    final session = ProximaSession.create(config);
    final result = await makeLoop(
      provider,
    ).runTurn(session, 'read all files', callbacks);

    expect(result.status, TaskStatus.failed);
    expect(callbacks.events.any((e) => e.contains('error')), isTrue);
  });

  test('streams response when provider supports streaming', () async {
    // Three text chunks followed by a done chunk with usage.
    final provider = MockStreamingProvider(
      chunks: [
        const LLMChunk(text: 'Hello'),
        const LLMChunk(text: ', world'),
        const LLMChunk(text: '!'),
        LLMChunk(
          text: '',
          isDone: true,
          finalUsage: const TokenUsage(
            inputTokens: 10,
            outputTokens: 3,
            totalTokens: 13,
          ),
        ),
      ],
    );

    final callbacks = MockCallbacks();
    final session = ProximaSession.create(config);
    final result = await makeLoop(
      provider,
    ).runTurn(session, 'say hello', callbacks);

    expect(result.status, TaskStatus.completed);

    // All three text chunks should have been forwarded via onChunk.
    expect(callbacks.events.any((e) => e == 'chunk: Hello'), isTrue);
    expect(callbacks.events.any((e) => e == 'chunk: , world'), isTrue);
    expect(callbacks.events.any((e) => e == 'chunk: !'), isTrue);

    // Session history must contain the fully assembled text.
    final assistantMessages = result.history
        .where((m) => m.role == MessageRole.assistant)
        .toList();
    expect(assistantMessages.isNotEmpty, isTrue);
    expect(assistantMessages.last.content, 'Hello, world!');

    // Token usage from the final chunk must be recorded.
    expect(result.cumulativeUsage.totalTokens, 13);

    // complete() must NOT have been called — streaming was used.
    expect(provider.completeCalled, isFalse);
  });

  test('falls back to complete() when streaming not supported', () async {
    // MockProvider has streaming: false, so complete() must be used.
    final provider = MockProvider([
      LLMResponse(
        body: FinalResponse('non-streaming response'),
        usage: const TokenUsage(
          inputTokens: 4,
          outputTokens: 4,
          totalTokens: 8,
        ),
      ),
    ]);

    final callbacks = MockCallbacks();
    final session = ProximaSession.create(config);
    final result = await makeLoop(
      provider,
    ).runTurn(session, 'say something', callbacks);

    expect(result.status, TaskStatus.completed);

    // No chunk events — complete() was used.
    expect(callbacks.events.any((e) => e.startsWith('chunk:')), isFalse);

    // onFinalResponse was called with the full text (not empty).
    expect(
      callbacks.events.any((e) => e == 'final: non-streaming response'),
      isTrue,
    );

    expect(result.cumulativeUsage.totalTokens, 8);
  });

  test('falls back to complete() when stream() throws', () async {
    final provider = MockStreamingFailProvider();
    final callbacks = MockCallbacks();
    final session = ProximaSession.create(config);
    final result = await makeLoop(
      provider,
    ).runTurn(session, 'say something', callbacks);

    expect(result.status, TaskStatus.completed);

    // complete() must have been invoked as fallback.
    expect(provider.completeCalled, isTrue);

    // A debug warning should have been emitted.
    expect(
      callbacks.events.any(
        (e) => e.contains('Streaming failed') || e.contains('debug'),
      ),
      isTrue,
    );

    // The fallback response text should appear in session history.
    final assistantMessages = result.history
        .where((m) => m.role == MessageRole.assistant)
        .toList();
    expect(assistantMessages.isNotEmpty, isTrue);
    expect(
      assistantMessages.last.content,
      'fallback response after stream error',
    );
  });
}
