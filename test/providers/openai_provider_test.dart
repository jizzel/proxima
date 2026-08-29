import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/providers/provider_interface.dart';
import 'package:proxima/providers/openai_provider.dart';

/// Canned non-streaming response with a plain text answer.
const _textResponse = '''
{"id":"chatcmpl-1","object":"chat.completion","model":"gpt-4o",
 "choices":[{"index":0,"message":{"role":"assistant","content":"hello there"},
 "finish_reason":"stop"}],
 "usage":{"prompt_tokens":12,"completion_tokens":3,"total_tokens":15}}
''';

/// Canned non-streaming response containing a tool call.
const _toolCallResponse = '''
{"id":"chatcmpl-2","object":"chat.completion","model":"gpt-4o",
 "choices":[{"index":0,"message":{"role":"assistant","content":null,
 "tool_calls":[{"id":"call_abc123","type":"function",
 "function":{"name":"read_file","arguments":"{\\"path\\":\\"lib/main.dart\\"}"}}]},
 "finish_reason":"tool_calls"}],
 "usage":{"prompt_tokens":20,"completion_tokens":8,"total_tokens":28}}
''';

void main() {
  /// Builds a provider whose HTTP layer is a MockClient, and captures the
  /// decoded request body for assertion.
  ({OpenAIProvider provider, List<Map<String, dynamic>> bodies}) makeProvider(
    String cannedResponse, {
    int statusCode = 200,
  }) {
    final bodies = <Map<String, dynamic>>[];
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response(
        cannedResponse,
        statusCode,
        headers: {'content-type': 'application/json'},
      );
    });
    return (
      provider: OpenAIProvider(
        model: 'gpt-4o',
        apiKey: 'test-key',
        client: client,
      ),
      bodies: bodies,
    );
  }

  CompletionRequest requestWith({
    String systemPrompt = '',
    List<Message> messages = const [],
    List<ToolDefinition> tools = const [],
  }) => CompletionRequest(
    model: 'gpt-4o',
    systemPrompt: systemPrompt,
    messages: messages,
    tools: tools,
  );

  group('OpenAIProvider request shape', () {
    test('sends the system prompt as the first message, not a field', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          systemPrompt: 'You are Proxima.',
          messages: [Message(role: MessageRole.user, content: 'hi')],
        ),
      );

      final body = h.bodies.single;
      expect(body['system'], isNull, reason: 'system must not be top-level');
      final messages = body['messages'] as List;
      expect((messages.first as Map)['role'], equals('system'));
      expect((messages.first as Map)['content'], equals('You are Proxima.'));
      expect((messages[1] as Map)['role'], equals('user'));
    });

    test('nests tool schema under function with parameters', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: [Message(role: MessageRole.user, content: 'hi')],
          tools: const [
            ToolDefinition(
              name: 'read_file',
              description: 'Read a file',
              inputSchema: {
                'type': 'object',
                'properties': {
                  'path': {'type': 'string'},
                },
              },
            ),
          ],
        ),
      );

      final tool = (h.bodies.single['tools'] as List).single as Map;
      expect(tool['type'], equals('function'));
      final fn = tool['function'] as Map;
      expect(fn['name'], equals('read_file'));
      expect(fn['description'], equals('Read a file'));
      // OpenAI calls it `parameters`; Anthropic calls it `input_schema`.
      expect(fn['parameters'], isA<Map>());
      expect(tool['input_schema'], isNull);
    });

    test('serialises a tool result as role:tool with tool_call_id', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: [
            Message(role: MessageRole.user, content: 'read it'),
            Message(
              role: MessageRole.tool,
              content: 'file contents here',
              toolName: 'read_file',
              toolCallId: 'call_abc123',
            ),
          ],
        ),
      );

      final toolMsg = (h.bodies.single['messages'] as List).last as Map;
      expect(toolMsg['role'], equals('tool'));
      expect(toolMsg['tool_call_id'], equals('call_abc123'));
      expect(toolMsg['content'], equals('file contents here'));
    });

    test('serialises assistant tool call arguments as a JSON string', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: [
            Message(
              role: MessageRole.assistant,
              content: 'reading the file',
              toolName: 'read_file',
              toolCallId: 'call_abc123',
              toolInput: {'path': 'lib/main.dart'},
            ),
          ],
        ),
      );

      final msg = (h.bodies.single['messages'] as List).single as Map;
      expect(msg['role'], equals('assistant'));
      final call = (msg['tool_calls'] as List).single as Map;
      expect(call['id'], equals('call_abc123'));
      expect(call['type'], equals('function'));

      final args = (call['function'] as Map)['arguments'];
      // Must be a String, not a Map — this is the most common porting bug.
      expect(args, isA<String>());
      expect(jsonDecode(args as String), equals({'path': 'lib/main.dart'}));
    });

    test('sends the bare model id, not the provider/model spec', () async {
      // Regression: sending request.model ("openai/gpt-4o") verbatim gets a
      // 400 "invalid model ID" from the API. The bare id comes from the
      // constructor, which ProviderRegistry has already split.
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        CompletionRequest(
          model: 'openai/gpt-4o',
          systemPrompt: '',
          messages: [Message(role: MessageRole.user, content: 'hi')],
        ),
      );
      expect(h.bodies.single['model'], equals('gpt-4o'));
    });

    test('omits temperature for o-series reasoning models', () async {
      // Regression: o1/o3/o4 accept only their default temperature and reject
      // an explicit value — including 0.0 — with a 400.
      for (final model in ['o3', 'o3-mini', 'o1-preview', 'o4-mini']) {
        final bodies = <Map<String, dynamic>>[];
        final client = MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(_textResponse, 200);
        });
        await OpenAIProvider(
          model: model,
          apiKey: 'test-key',
          client: client,
        ).complete(
          requestWith(
            messages: [Message(role: MessageRole.user, content: 'hi')],
          ),
        );
        expect(
          bodies.single.containsKey('temperature'),
          isFalse,
          reason: '$model must not receive temperature',
        );
      }
    });

    test('sends temperature for gpt models', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: [Message(role: MessageRole.user, content: 'hi')],
        ),
      );
      expect(h.bodies.single['temperature'], equals(0.0));
    });

    test('requests usage on streamed calls', () async {
      final h = makeProvider(_textResponse);
      // Drain the stream; MockClient returns a non-SSE body which simply
      // produces no chunks, but the request body is what we assert on.
      await h.provider
          .stream(
            requestWith(
              messages: [Message(role: MessageRole.user, content: 'hi')],
            ),
          )
          .toList();

      expect(h.bodies.single['stream'], isTrue);
      expect(
        h.bodies.single['stream_options'],
        equals({'include_usage': true}),
      );
    });
  });

  group('OpenAIProvider response parsing', () {
    test('parses a plain text response', () async {
      final h = makeProvider(_textResponse);
      final response = await h.provider.complete(
        requestWith(
          messages: [Message(role: MessageRole.user, content: 'hi')],
        ),
      );

      expect(response.body, isA<FinalResponse>());
      expect((response.body as FinalResponse).text, equals('hello there'));
    });

    test('maps usage from prompt_tokens/completion_tokens', () async {
      final h = makeProvider(_textResponse);
      final response = await h.provider.complete(
        requestWith(
          messages: [Message(role: MessageRole.user, content: 'hi')],
        ),
      );

      expect(response.usage.inputTokens, equals(12));
      expect(response.usage.outputTokens, equals(3));
      expect(response.usage.totalTokens, equals(15));
    });

    test('parses a tool call and preserves the callId', () async {
      final h = makeProvider(_toolCallResponse);
      final response = await h.provider.complete(
        requestWith(
          messages: [Message(role: MessageRole.user, content: 'hi')],
        ),
      );

      expect(response.body, isA<ToolCallResponse>());
      final call = (response.body as ToolCallResponse).toolCall;
      expect(call.tool, equals('read_file'));
      expect(call.args, equals({'path': 'lib/main.dart'}));
      // Load-bearing: OpenAI rejects a tool_call_id it did not issue, and the
      // agent loop replays this value on the following request.
      expect(call.callId, equals('call_abc123'));
    });

    test('throws schemaViolation on malformed tool arguments', () async {
      const malformed = '''
{"choices":[{"index":0,"message":{"role":"assistant","content":null,
 "tool_calls":[{"id":"call_x","type":"function",
 "function":{"name":"read_file","arguments":"{not valid json"}}]},
 "finish_reason":"tool_calls"}],"usage":{}}
''';
      final h = makeProvider(malformed);

      expect(
        () => h.provider.complete(
          requestWith(
            messages: [Message(role: MessageRole.user, content: 'hi')],
          ),
        ),
        throwsA(
          isA<LLMError>().having(
            (e) => e.kind,
            'kind',
            LLMErrorKind.schemaViolation,
          ),
        ),
      );
    });

    test('handles an empty choices list without crashing', () async {
      final h = makeProvider('{"choices":[],"usage":{}}');
      final response = await h.provider.complete(
        requestWith(
          messages: [Message(role: MessageRole.user, content: 'hi')],
        ),
      );
      expect(response.body, isA<FinalResponse>());
      expect((response.body as FinalResponse).text, isEmpty);
    });
  });

  group('OpenAIProvider errors', () {
    test('maps 401 to auth so FallbackProvider does not fall back', () async {
      final h = makeProvider(
        '{"error":{"message":"Incorrect API key provided"}}',
        statusCode: 401,
      );
      expect(
        () => h.provider.complete(
          requestWith(
            messages: [Message(role: MessageRole.user, content: 'hi')],
          ),
        ),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.auth),
        ),
      );
    });

    test('maps 403 to auth', () async {
      final h = makeProvider(
        '{"error":{"message":"forbidden"}}',
        statusCode: 403,
      );
      expect(
        () => h.provider.complete(
          requestWith(
            messages: [Message(role: MessageRole.user, content: 'hi')],
          ),
        ),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.auth),
        ),
      );
    });

    test('maps 429 to rateLimit', () async {
      final h = makeProvider(
        '{"error":{"message":"slow down"}}',
        statusCode: 429,
      );
      expect(
        () => h.provider.complete(
          requestWith(
            messages: [Message(role: MessageRole.user, content: 'hi')],
          ),
        ),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.rateLimit),
        ),
      );
    });

    test('maps a non-JSON error body to unknown', () async {
      final h = makeProvider('<html>502 Bad Gateway</html>', statusCode: 502);
      expect(
        () => h.provider.complete(
          requestWith(
            messages: [Message(role: MessageRole.user, content: 'hi')],
          ),
        ),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.unknown),
        ),
      );
    });
  });

  group('OpenAIProvider streaming', () {
    /// Builds a provider whose client returns [lines] as an SSE byte stream.
    OpenAIProvider streamingProvider(List<String> lines) {
      final client = MockClient.streaming((request, bodyStream) async {
        final body = lines.map((l) => '$l\n').join();
        return http.StreamedResponse(
          Stream.value(utf8.encode(body)),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      return OpenAIProvider(
        model: 'gpt-4o',
        apiKey: 'test-key',
        client: client,
      );
    }

    test('yields text deltas then exactly one done chunk', () async {
      final provider = streamingProvider([
        'data: {"choices":[{"index":0,"delta":{"content":"Hel"}}]}',
        'data: {"choices":[{"index":0,"delta":{"content":"lo"}}]}',
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}',
        'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2,'
            '"total_tokens":7}}',
        'data: [DONE]',
      ]);

      final chunks = await provider.stream(requestWith()).toList();
      final text = chunks.where((c) => !c.isDone).map((c) => c.text).join();
      final done = chunks.where((c) => c.isDone).toList();

      expect(text, equals('Hello'));
      expect(done.length, equals(1), reason: 'exactly one done chunk');
      expect(done.single.hasToolUse, isFalse);
      expect(done.single.finalUsage?.totalTokens, equals(7));
    });

    test('sets hasToolUse when a tool_calls delta appears', () async {
      final provider = streamingProvider([
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,'
            '"id":"call_x","function":{"name":"read_file","arguments":""}}]}}]}',
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}',
        'data: [DONE]',
      ]);

      final chunks = await provider.stream(requestWith()).toList();
      final done = chunks.singleWhere((c) => c.isDone);
      expect(done.hasToolUse, isTrue);
    });

    test('suppresses text once a tool call is detected', () async {
      final provider = streamingProvider([
        'data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,'
            '"id":"call_x","function":{"name":"f","arguments":""}}]}}]}',
        'data: {"choices":[{"index":0,"delta":{"content":"leaked"}}]}',
        'data: [DONE]',
      ]);

      final chunks = await provider.stream(requestWith()).toList();
      final text = chunks.where((c) => !c.isDone).map((c) => c.text).join();
      expect(text, isEmpty);
    });

    test('ignores malformed SSE lines', () async {
      final provider = streamingProvider([
        'data: {not json at all',
        ': a comment line',
        'data: {"choices":[{"index":0,"delta":{"content":"ok"}}]}',
        'data: [DONE]',
      ]);

      final chunks = await provider.stream(requestWith()).toList();
      final text = chunks.where((c) => !c.isDone).map((c) => c.text).join();
      expect(text, equals('ok'));
    });

    test('terminates cleanly when the stream ends without [DONE]', () async {
      final provider = streamingProvider([
        'data: {"choices":[{"index":0,"delta":{"content":"hi"}}]}',
      ]);

      final chunks = await provider.stream(requestWith()).toList();
      expect(chunks.where((c) => c.isDone).length, equals(1));
    });
  });

  group('OpenAIProvider listModels', () {
    OpenAIProvider modelsProvider(String body, {int statusCode = 200}) {
      final client = MockClient(
        (request) async => http.Response(
          body,
          statusCode,
          headers: {'content-type': 'application/json'},
        ),
      );
      return OpenAIProvider(
        model: 'gpt-4o',
        apiKey: 'test-key',
        client: client,
      );
    }

    test('returns chat models sorted, filtering non-chat entries', () async {
      final provider = modelsProvider('''
{"data":[{"id":"gpt-4o"},{"id":"text-embedding-3-small"},{"id":"o3"},
         {"id":"whisper-1"},{"id":"dall-e-3"},{"id":"gpt-4-turbo"}]}
''');
      final models = await provider.listModels();
      expect(models, equals(['gpt-4-turbo', 'gpt-4o', 'o3']));
    });

    test('returns an unknown future gpt model without a code change', () async {
      // The point of live fetching: new releases appear automatically.
      final provider = modelsProvider('{"data":[{"id":"gpt-9-ultra"}]}');
      expect(await provider.listModels(), equals(['gpt-9-ultra']));
    });

    test('keeps chat models from OpenAI-compatible endpoints', () async {
      // Regression: an allow-list keyed on gpt/o<n> filtered out every Groq,
      // Together, OpenRouter, and LM Studio model, leaving the picker empty
      // against endpoints the provider explicitly supports.
      final provider = modelsProvider('''
{"data":[{"id":"llama-3.3-70b-versatile"},{"id":"mixtral-8x7b-32768"},
         {"id":"meta-llama/Llama-3-70b-chat-hf"},
         {"id":"anthropic/claude-sonnet-4"},
         {"id":"qwen2.5-coder-32b-instruct"}]}
''');
      final models = await provider.listModels();
      expect(models, contains('llama-3.3-70b-versatile'));
      expect(models, contains('meta-llama/Llama-3-70b-chat-hf'));
      expect(models, contains('anthropic/claude-sonnet-4'));
      expect(models, contains('qwen2.5-coder-32b-instruct'));
    });

    test('still drops non-chat modalities from any endpoint', () async {
      final provider = modelsProvider('''
{"data":[{"id":"text-embedding-3-small"},{"id":"whisper-large-v3"},
         {"id":"dall-e-3"},{"id":"tts-1"},{"id":"bge-reranker"},
         {"id":"stable-diffusion-xl"},{"id":"llama-guard-3-8b"},
         {"id":"gpt-4o"}]}
''');
      expect(await provider.listModels(), equals(['gpt-4o']));
    });

    test('returns empty on a non-200 rather than throwing', () async {
      final provider = modelsProvider('{"error":{}}', statusCode: 401);
      expect(await provider.listModels(), isEmpty);
    });

    test('returns empty on a malformed body rather than throwing', () async {
      final provider = modelsProvider('not json');
      expect(await provider.listModels(), isEmpty);
    });
  });
}
