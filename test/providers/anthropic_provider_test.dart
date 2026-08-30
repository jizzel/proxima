import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/providers/provider_interface.dart';
import 'package:proxima/providers/anthropic_provider.dart';

const _textResponse = '''
{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4-6",
 "content":[{"type":"text","text":"hello there"}],
 "stop_reason":"end_turn",
 "usage":{"input_tokens":12,"output_tokens":3}}
''';

const _toolUseResponse = '''
{"id":"msg_2","type":"message","role":"assistant","model":"claude-sonnet-4-6",
 "content":[{"type":"thinking","thinking":"I should read the file."},
            {"type":"tool_use","id":"toolu_abc123","name":"read_file",
             "input":{"path":"lib/main.dart"}}],
 "stop_reason":"tool_use",
 "usage":{"input_tokens":20,"output_tokens":8}}
''';

void main() {
  /// Builds a provider over a MockClient, capturing decoded request bodies and
  /// the headers sent.
  ({
    AnthropicProvider provider,
    List<Map<String, dynamic>> bodies,
    List<Map<String, String>> headers,
  })
  makeProvider(String cannedResponse, {int statusCode = 200}) {
    final bodies = <Map<String, dynamic>>[];
    final headers = <Map<String, String>>[];
    final client = MockClient((request) async {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      headers.add(request.headers);
      return http.Response(
        cannedResponse,
        statusCode,
        headers: {'content-type': 'application/json'},
      );
    });
    return (
      provider: AnthropicProvider(
        model: 'claude-sonnet-4-6',
        apiKey: 'test-key',
        client: client,
      ),
      bodies: bodies,
      headers: headers,
    );
  }

  CompletionRequest requestWith({
    String model = 'claude-sonnet-4-6',
    String systemPrompt = '',
    List<Message> messages = const [],
    List<ToolDefinition> tools = const [],
  }) => CompletionRequest(
    model: model,
    systemPrompt: systemPrompt,
    messages: messages,
    tools: tools,
  );

  final userHi = [Message(role: MessageRole.user, content: 'hi')];

  group('AnthropicProvider request shape', () {
    test('sends the system prompt as a top-level field', () async {
      // The inverse of OpenAI, which sends it as the first message.
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(systemPrompt: 'You are Proxima.', messages: userHi),
      );

      expect(h.bodies.single['system'], equals('You are Proxima.'));
      final messages = h.bodies.single['messages'] as List;
      expect((messages.first as Map)['role'], equals('user'));
    });

    test('omits system entirely when the prompt is empty', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(requestWith(messages: userHi));
      expect(h.bodies.single.containsKey('system'), isFalse);
    });

    test('sends the api key and pinned api version headers', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(requestWith(messages: userHi));

      expect(h.headers.single['x-api-key'], equals('test-key'));
      expect(h.headers.single['anthropic-version'], equals('2023-06-01'));
    });

    test('sends tools with a flat input_schema', () async {
      // Anthropic's shape; OpenAI nests the same data under function.parameters.
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: userHi,
          tools: const [
            ToolDefinition(
              name: 'read_file',
              description: 'Read a file',
              inputSchema: {'type': 'object'},
            ),
          ],
        ),
      );

      final tool = (h.bodies.single['tools'] as List).single as Map;
      expect(tool['name'], equals('read_file'));
      expect(tool['input_schema'], isA<Map>());
      expect(tool.containsKey('function'), isFalse);
    });

    test('omits tools when none are supplied', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(requestWith(messages: userHi));
      expect(h.bodies.single.containsKey('tools'), isFalse);
    });

    test('sends request.model verbatim', () async {
      // Deliberately unlike OpenAI, where the bare id must be sent instead.
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(model: 'claude-opus-4-6', messages: userHi),
      );
      expect(h.bodies.single['model'], equals('claude-opus-4-6'));
    });

    test('filters out system-role messages from the array', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: [
            Message(role: MessageRole.system, content: 'ignored'),
            ...userHi,
          ],
        ),
      );

      final messages = h.bodies.single['messages'] as List;
      expect(messages.length, equals(1));
      expect((messages.single as Map)['role'], equals('user'));
    });
  });

  group('AnthropicProvider message serialisation', () {
    test(
      'a tool result becomes a user message with a tool_result block',
      () async {
        final h = makeProvider(_textResponse);
        await h.provider.complete(
          requestWith(
            messages: [
              Message(
                role: MessageRole.tool,
                content: 'file contents',
                toolName: 'read_file',
                toolCallId: 'toolu_abc123',
              ),
            ],
          ),
        );

        final msg = (h.bodies.single['messages'] as List).single as Map;
        expect(msg['role'], equals('user'), reason: 'not a tool role');
        final block = (msg['content'] as List).single as Map;
        expect(block['type'], equals('tool_result'));
        expect(block['tool_use_id'], equals('toolu_abc123'));
        expect(block['content'], equals('file contents'));
      },
    );

    test('a tool result with no call id sends an empty string', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: [
            Message(
              role: MessageRole.tool,
              content: 'x',
              toolName: 'read_file',
            ),
          ],
        ),
      );

      final block =
          (((h.bodies.single['messages'] as List).single as Map)['content']
                      as List)
                  .single
              as Map;
      expect(block['tool_use_id'], equals(''));
    });

    test('an assistant tool call sends input as a raw map', () async {
      // OpenAI requires a JSON-encoded *string* here; Anthropic takes an object.
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: [
            Message(
              role: MessageRole.assistant,
              content: 'reading',
              toolName: 'read_file',
              toolCallId: 'toolu_abc123',
              toolInput: {'path': 'lib/main.dart'},
            ),
          ],
        ),
      );

      final block =
          (((h.bodies.single['messages'] as List).single as Map)['content']
                      as List)
                  .single
              as Map;
      expect(block['type'], equals('tool_use'));
      expect(block['id'], equals('toolu_abc123'));
      expect(block['name'], equals('read_file'));
      expect(block['input'], isA<Map>());
      expect(block['input'], equals({'path': 'lib/main.dart'}));
    });

    test(
      'an assistant tool call falls back to call_0 and an empty name',
      () async {
        final h = makeProvider(_textResponse);
        await h.provider.complete(
          requestWith(
            messages: [
              Message(
                role: MessageRole.assistant,
                content: '',
                toolInput: {'path': 'x'},
              ),
            ],
          ),
        );

        final block =
            (((h.bodies.single['messages'] as List).single as Map)['content']
                        as List)
                    .single
                as Map;
        expect(block['id'], equals('call_0'));
        expect(block['name'], equals(''));
      },
    );

    test('a plain assistant message sends bare content', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: [
            Message(role: MessageRole.assistant, content: 'plain reply'),
          ],
        ),
      );

      final msg = (h.bodies.single['messages'] as List).single as Map;
      expect(msg['role'], equals('assistant'));
      expect(msg['content'], equals('plain reply'));
    });
  });

  group('AnthropicProvider response parsing', () {
    test('parses a text response', () async {
      final h = makeProvider(_textResponse);
      final response = await h.provider.complete(requestWith(messages: userHi));

      expect(response.body, isA<FinalResponse>());
      expect((response.body as FinalResponse).text, equals('hello there'));
      expect(response.rawText, equals('hello there'));
    });

    test('computes totalTokens as a sum', () async {
      // Anthropic sends no total_tokens field, unlike OpenAI.
      final h = makeProvider(_textResponse);
      final response = await h.provider.complete(requestWith(messages: userHi));

      expect(response.usage.inputTokens, equals(12));
      expect(response.usage.outputTokens, equals(3));
      expect(response.usage.totalTokens, equals(15));
    });

    test('treats missing usage as zero', () async {
      final h = makeProvider('{"content":[{"type":"text","text":"x"}]}');
      final response = await h.provider.complete(requestWith(messages: userHi));
      expect(response.usage.totalTokens, equals(0));
    });

    test('parses a tool call, preserving the id', () async {
      final h = makeProvider(_toolUseResponse);
      final response = await h.provider.complete(requestWith(messages: userHi));

      expect(response.body, isA<ToolCallResponse>());
      final call = (response.body as ToolCallResponse).toolCall;
      expect(call.tool, equals('read_file'));
      expect(call.args, equals({'path': 'lib/main.dart'}));
      expect(call.callId, equals('toolu_abc123'));
    });

    test('uses thinking blocks as the tool call reasoning', () async {
      final h = makeProvider(_toolUseResponse);
      final response = await h.provider.complete(requestWith(messages: userHi));

      final call = (response.body as ToolCallResponse).toolCall;
      expect(call.reasoning, contains('I should read the file'));
    });

    test('joins multiple thinking blocks', () async {
      final h = makeProvider('''
{"content":[{"type":"thinking","thinking":"first"},
            {"type":"thinking","thinking":"second"},
            {"type":"tool_use","id":"t1","name":"read_file","input":{}}],
 "stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}
''');
      final response = await h.provider.complete(requestWith(messages: userHi));
      final call = (response.body as ToolCallResponse).toolCall;
      expect(call.reasoning, contains('first'));
      expect(call.reasoning, contains('second'));
    });

    test(
      'falls through to text when stop_reason lies about a tool block',
      () async {
        // stop_reason says tool_use but no tool_use block is present — this must
        // not crash.
        final h = makeProvider('''
{"content":[{"type":"text","text":"actually just text"}],
 "stop_reason":"tool_use","usage":{"input_tokens":1,"output_tokens":1}}
''');
        final response = await h.provider.complete(
          requestWith(messages: userHi),
        );

        expect(response.body, isA<FinalResponse>());
        expect(
          (response.body as FinalResponse).text,
          equals('actually just text'),
        );
      },
    );

    test('handles an empty content list', () async {
      final h = makeProvider('{"content":[],"usage":{}}');
      final response = await h.provider.complete(requestWith(messages: userHi));
      expect((response.body as FinalResponse).text, isEmpty);
    });
  });

  group('AnthropicProvider errors', () {
    Future<void> expectKind(int status, LLMErrorKind kind) async {
      final h = makeProvider(
        '{"error":{"message":"nope"}}',
        statusCode: status,
      );
      await expectLater(
        h.provider.complete(requestWith(messages: userHi)),
        throwsA(isA<LLMError>().having((e) => e.kind, 'kind', kind)),
      );
    }

    test('maps 401 to auth', () => expectKind(401, LLMErrorKind.auth));

    test('maps 403 to auth', () => expectKind(403, LLMErrorKind.auth));

    test(
      'maps 429 to rateLimit',
      () => expectKind(429, LLMErrorKind.rateLimit),
    );

    test(
      'maps other statuses to unknown',
      () => expectKind(500, LLMErrorKind.unknown),
    );

    test('maps a non-JSON body to unknown', () async {
      final h = makeProvider('<html>502</html>', statusCode: 502);
      await expectLater(
        h.provider.complete(requestWith(messages: userHi)),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.unknown),
        ),
      );
    });
  });

  group('AnthropicProvider streaming', () {
    AnthropicProvider streamingProvider(List<String> lines) {
      final client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(lines.map((l) => '$l\n').join())),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      return AnthropicProvider(
        model: 'claude-sonnet-4-6',
        apiKey: 'k',
        client: client,
      );
    }

    test('yields text deltas then exactly one done chunk', () async {
      final provider = streamingProvider([
        'data: {"type":"content_block_delta","delta":{"text":"Hel"}}',
        'data: {"type":"content_block_delta","delta":{"text":"lo"}}',
        'data: {"type":"message_delta","usage":{"input_tokens":5,"output_tokens":2}}',
        'data: {"type":"message_stop"}',
      ]);

      final chunks = await provider.stream(requestWith()).toList();
      final text = chunks.where((c) => !c.isDone).map((c) => c.text).join();
      final done = chunks.where((c) => c.isDone).toList();

      expect(text, equals('Hello'));
      expect(done.length, equals(1));
      expect(done.single.finalUsage?.totalTokens, equals(7));
      expect(done.single.hasToolUse, isFalse);
    });

    test('sets hasToolUse when a tool_use block starts', () async {
      final provider = streamingProvider([
        'data: {"type":"content_block_start","content_block":{"type":"tool_use"}}',
        'data: {"type":"message_stop"}',
      ]);

      final done = (await provider.stream(requestWith()).toList()).singleWhere(
        (c) => c.isDone,
      );
      expect(done.hasToolUse, isTrue);
    });

    test('suppresses text once a tool call has started', () async {
      final provider = streamingProvider([
        'data: {"type":"content_block_start","content_block":{"type":"tool_use"}}',
        'data: {"type":"content_block_delta","delta":{"text":"leaked"}}',
        'data: {"type":"message_stop"}',
      ]);

      final chunks = await provider.stream(requestWith()).toList();
      expect(chunks.where((c) => !c.isDone).map((c) => c.text).join(), isEmpty);
    });

    test('reassembles an SSE line split across chunk boundaries', () async {
      // The buffering keeps the trailing partial line; a naive implementation
      // would drop this delta entirely.
      final client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.fromIterable([
            utf8.encode('data: {"type":"content_block_delta","delta":{"te'),
            utf8.encode('xt":"split"}}\ndata: {"type":"message_stop"}\n'),
          ]),
          200,
        );
      });
      final provider = AnthropicProvider(
        model: 'c',
        apiKey: 'k',
        client: client,
      );

      final chunks = await provider.stream(requestWith()).toList();
      expect(
        chunks.where((c) => !c.isDone).map((c) => c.text).join(),
        equals('split'),
      );
    });

    test('ignores malformed SSE lines', () async {
      final provider = streamingProvider([
        'data: {not json',
        ': a comment',
        'data: {"type":"content_block_delta","delta":{"text":"ok"}}',
        'data: {"type":"message_stop"}',
      ]);

      final chunks = await provider.stream(requestWith()).toList();
      expect(
        chunks.where((c) => !c.isDone).map((c) => c.text).join(),
        equals('ok'),
      );
    });

    test('terminates cleanly without message_stop', () async {
      final provider = streamingProvider([
        'data: {"type":"content_block_delta","delta":{"text":"hi"}}',
      ]);
      final chunks = await provider.stream(requestWith()).toList();
      expect(chunks.where((c) => c.isDone).length, equals(1));
    });
  });

  group('AnthropicProvider capabilities and models', () {
    test('advertises native tool use and streaming', () {
      final h = makeProvider(_textResponse);
      expect(h.provider.capabilities.nativeToolUse, isTrue);
      expect(h.provider.capabilities.streaming, isTrue);
      expect(h.provider.capabilities.contextWindow, greaterThan(0));
    });

    test('listModels returns a static list without any network call', () async {
      var called = false;
      final provider = AnthropicProvider(
        model: 'c',
        apiKey: 'k',
        client: MockClient((request) async {
          called = true;
          return http.Response('{}', 200);
        }),
      );

      final models = await provider.listModels();
      expect(models, isNotEmpty);
      expect(called, isFalse, reason: 'Anthropic has no models endpoint');
    });
  });
}
