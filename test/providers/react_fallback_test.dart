import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/providers/provider_interface.dart';
import 'package:proxima/providers/react_fallback.dart';

// A provider whose stream() emits a preset list of text chunks.
class StreamingMockProvider implements LLMProvider {
  final List<String> chunks;
  int completeCallCount = 0;
  String? lastCompleteText;

  StreamingMockProvider(this.chunks);

  @override
  String get name => 'mock';
  @override
  String get model => 'mock/model';
  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    nativeToolUse: false,
    streaming: true,
    contextWindow: 10000,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    completeCallCount++;
    // Reassemble what stream() would have produced and parse it.
    final text = chunks.join();
    lastCompleteText = text;
    return LLMResponse(body: FinalResponse(text), usage: TokenUsage.zero);
  }

  @override
  Stream<LLMChunk> stream(CompletionRequest request) async* {
    for (final chunk in chunks) {
      yield LLMChunk(text: chunk);
    }
    yield LLMChunk(text: '', isDone: true, finalUsage: TokenUsage.zero);
  }

  @override
  Future<List<String>> listModels() async => [];
}

void main() {
  final dummyRequest = CompletionRequest(
    model: 'mock/model',
    systemPrompt: '',
    messages: [Message(role: MessageRole.user, content: 'hi')],
  );

  group('ReActFallback.stream()', () {
    test(
      'tool-call response: done chunk has hasToolUse=true, no text chunks forwarded',
      () async {
        const toolCallText =
            '<tool_call>{"tool": "write_file", "args": {"path": "DESC.md", "content": "# Hello"}, "reasoning": "user asked"}</tool_call>';
        final inner = StreamingMockProvider([toolCallText]);
        final fallback = ReActFallback(inner);

        final chunks = await fallback.stream(dummyRequest).toList();

        // Only the done chunk should be emitted (no text chunks).
        expect(chunks, hasLength(1));
        expect(chunks.last.isDone, isTrue);
        expect(chunks.last.hasToolUse, isTrue);
      },
    );

    test(
      'plain text response: text chunk forwarded, done chunk has hasToolUse=false',
      () async {
        final inner = StreamingMockProvider(['Hello, ', 'world!']);
        final fallback = ReActFallback(inner);

        final chunks = await fallback.stream(dummyRequest).toList();

        final textChunks = chunks.where((c) => !c.isDone).toList();
        final doneChunk = chunks.firstWhere((c) => c.isDone);

        expect(textChunks, isNotEmpty);
        expect(textChunks.map((c) => c.text).join(), contains('Hello'));
        expect(doneChunk.hasToolUse, isFalse);
      },
    );

    test(
      'complete() is called with same request when hasToolUse is detected by agent loop',
      () async {
        // This simulates the agent_loop _streamResponse fallback path:
        // stream() signals hasToolUse → caller invokes complete().
        const toolCallText =
            '<tool_call>{"tool": "write_file", "args": {"path": "f.md", "content": "x"}, "reasoning": "r"}</tool_call>';
        final inner = StreamingMockProvider([toolCallText]);
        final fallback = ReActFallback(inner);

        // Consume the stream — get hasToolUse signal.
        final chunks = await fallback.stream(dummyRequest).toList();
        expect(chunks.last.hasToolUse, isTrue);

        // Agent loop would now call complete().
        final response = await fallback.complete(dummyRequest);

        // complete() should have extracted the ToolCallResponse.
        expect(response.body, isA<ToolCallResponse>());
        final toolCall = (response.body as ToolCallResponse).toolCall;
        expect(toolCall.tool, 'write_file');
      },
    );
  });
}
