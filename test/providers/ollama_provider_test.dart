import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/providers/provider_interface.dart';
import 'package:proxima/providers/openai_provider.dart';
import 'package:proxima/providers/ollama_provider.dart';

const _textResponse = '''
{"model":"qwen2.5-coder:32b","message":{"role":"assistant","content":"hello there"},
 "done":true,"prompt_eval_count":12,"eval_count":3}
''';

void main() {
  ({OllamaProvider provider, List<Map<String, dynamic>> bodies, List<Uri> urls})
  makeProvider(String cannedResponse, {int statusCode = 200}) {
    final bodies = <Map<String, dynamic>>[];
    final urls = <Uri>[];
    final client = MockClient((request) async {
      urls.add(request.url);
      if (request.body.isNotEmpty) {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      }
      return http.Response(
        cannedResponse,
        statusCode,
        headers: {'content-type': 'application/json'},
      );
    });
    return (
      provider: OllamaProvider(model: 'qwen2.5-coder:32b', client: client),
      bodies: bodies,
      urls: urls,
    );
  }

  CompletionRequest requestWith({
    String model = 'qwen2.5-coder:32b',
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

  group('OllamaProvider request shape', () {
    test('posts to /api/chat', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(requestWith(messages: userHi));
      expect(h.urls.single.path, equals('/api/chat'));
    });

    test('sends the system prompt as the first message', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(systemPrompt: 'You are Proxima.', messages: userHi),
      );

      expect(h.bodies.single.containsKey('system'), isFalse);
      final messages = h.bodies.single['messages'] as List;
      expect((messages.first as Map)['role'], equals('system'));
      expect((messages.first as Map)['content'], equals('You are Proxima.'));
    });

    test('sends the constructor model, not request.model', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(model: 'ollama/some-other-model', messages: userHi),
      );
      expect(h.bodies.single['model'], equals('qwen2.5-coder:32b'));
    });

    test('nests temperature and num_predict under options', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(requestWith(messages: userHi));

      expect(h.bodies.single.containsKey('temperature'), isFalse);
      final options = h.bodies.single['options'] as Map;
      expect(options.containsKey('temperature'), isTrue);
      expect(options.containsKey('num_predict'), isTrue);
    });

    test('never sends a tools array — tool use goes through ReAct', () async {
      // Ollama's capabilities report nativeToolUse: false, and the registry
      // wraps it in ReActFallback, which puts tools in the system prompt.
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

      expect(h.bodies.single.containsKey('tools'), isFalse);
    });

    test('drops tool metadata, sending only role and content', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: [
            Message(
              role: MessageRole.assistant,
              content: 'reading',
              toolName: 'read_file',
              toolCallId: 'c1',
              toolInput: {'path': 'lib/main.dart'},
            ),
          ],
        ),
      );

      final msg =
          (h.bodies.single['messages'] as List).single as Map<String, dynamic>;
      expect(msg.keys.toSet(), equals({'role', 'content'}));
    });

    test('maps the tool role through', () async {
      final h = makeProvider(_textResponse);
      await h.provider.complete(
        requestWith(
          messages: [
            Message(
              role: MessageRole.tool,
              content: 'r',
              toolName: 'read_file',
            ),
          ],
        ),
      );
      final msg = (h.bodies.single['messages'] as List).single as Map;
      expect(msg['role'], equals('tool'));
    });

    test('sends no auth header', () async {
      var authHeader = 'unset';
      final provider = OllamaProvider(
        model: 'q',
        client: MockClient((request) async {
          authHeader = request.headers['authorization'] ?? 'absent';
          return http.Response(_textResponse, 200);
        }),
      );
      await provider.complete(requestWith(messages: userHi));
      expect(authHeader, equals('absent'));
    });
  });

  group('OllamaProvider response parsing', () {
    test('parses text from message.content', () async {
      final h = makeProvider(_textResponse);
      final response = await h.provider.complete(requestWith(messages: userHi));
      expect((response.body as FinalResponse).text, equals('hello there'));
    });

    test('maps usage from prompt_eval_count and eval_count', () async {
      final h = makeProvider(_textResponse);
      final response = await h.provider.complete(requestWith(messages: userHi));

      expect(response.usage.inputTokens, equals(12));
      expect(response.usage.outputTokens, equals(3));
      expect(response.usage.totalTokens, equals(15));
    });

    test('always returns FinalResponse — there is no tool-call path', () async {
      final h = makeProvider(_textResponse);
      final response = await h.provider.complete(requestWith(messages: userHi));
      expect(response.body, isA<FinalResponse>());
    });

    test('handles a missing message field', () async {
      final h = makeProvider('{"done":true}');
      final response = await h.provider.complete(requestWith(messages: userHi));
      expect((response.body as FinalResponse).text, isEmpty);
    });
  });

  group('OllamaProvider errors', () {
    test('reports a non-200 with the Ollama prefix', () async {
      final h = makeProvider('server exploded', statusCode: 500);
      await expectLater(
        h.provider.complete(requestWith(messages: userHi)),
        throwsA(
          isA<LLMError>().having(
            (e) => e.message,
            'message',
            contains('Ollama HTTP 500'),
          ),
        ),
      );
    });

    test('maps 429 to rateLimit so retries can back off', () async {
      // A remote Ollama or LM Studio behind a proxy can rate-limit; a blanket
      // `unknown` gave the caller nothing to act on.
      final h = makeProvider('rate limited', statusCode: 429);
      await expectLater(
        h.provider.complete(requestWith(messages: userHi)),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.rateLimit),
        ),
      );
    });
  });

  group('OllamaProvider streaming (NDJSON)', () {
    OllamaProvider streamingProvider(List<String> lines) {
      final client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.value(utf8.encode(lines.map((l) => '$l\n').join())),
          200,
        );
      });
      return OllamaProvider(model: 'q', client: client);
    }

    test('yields deltas from bare JSON lines, with no data: prefix', () async {
      final provider = streamingProvider([
        '{"message":{"content":"Hel"},"done":false}',
        '{"message":{"content":"lo"},"done":false}',
        '{"done":true,"prompt_eval_count":5,"eval_count":2}',
      ]);

      final chunks = await provider.stream(requestWith()).toList();
      final text = chunks.where((c) => !c.isDone).map((c) => c.text).join();
      final done = chunks.where((c) => c.isDone).toList();

      expect(text, equals('Hello'));
      expect(done.length, equals(1));
      expect(done.single.finalUsage?.totalTokens, equals(7));
    });

    test('never reports hasToolUse', () async {
      final provider = streamingProvider([
        '{"message":{"content":"x"},"done":false}',
        '{"done":true}',
      ]);
      final done = (await provider.stream(requestWith()).toList()).singleWhere(
        (c) => c.isDone,
      );
      expect(done.hasToolUse, isFalse);
    });

    test('ignores malformed and blank lines', () async {
      final provider = streamingProvider([
        '{not json',
        '',
        '{"message":{"content":"ok"},"done":false}',
        '{"done":true}',
      ]);
      final chunks = await provider.stream(requestWith()).toList();
      expect(
        chunks.where((c) => !c.isDone).map((c) => c.text).join(),
        equals('ok'),
      );
    });

    test('reassembles a line split across chunk boundaries', () async {
      final client = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(
          Stream.fromIterable([
            utf8.encode('{"message":{"cont'),
            utf8.encode('ent":"split"},"done":false}\n{"done":true}\n'),
          ]),
          200,
        );
      });
      final provider = OllamaProvider(model: 'q', client: client);

      final chunks = await provider.stream(requestWith()).toList();
      expect(
        chunks.where((c) => !c.isDone).map((c) => c.text).join(),
        equals('split'),
      );
    });

    test('terminates cleanly when the stream ends without done', () async {
      final provider = streamingProvider([
        '{"message":{"content":"hi"},"done":false}',
      ]);
      final chunks = await provider.stream(requestWith()).toList();
      expect(chunks.where((c) => c.isDone).length, equals(1));
    });
  });

  group('OllamaProvider listModels', () {
    OllamaProvider modelsProvider(String body, {int statusCode = 200}) =>
        OllamaProvider(
          model: 'q',
          client: MockClient(
            (request) async => http.Response(body, statusCode),
          ),
        );

    test('reads names from /api/tags', () async {
      final provider = modelsProvider(
        '{"models":[{"name":"qwen2.5-coder:32b"},{"name":"mistral:latest"}]}',
      );
      expect(
        await provider.listModels(),
        equals(['qwen2.5-coder:32b', 'mistral:latest']),
      );
    });

    test('returns empty for a missing models key', () async {
      expect(await modelsProvider('{}').listModels(), isEmpty);
    });

    // Locally-pulled tags are a short, user-chosen list whose `name:tag` form
    // carries no version family, so picker curation must leave them intact.
    test('locally pulled tags survive picker curation', () async {
      final models = await modelsProvider(
        '{"models":[{"name":"qwen2.5-coder:32b"},{"name":"llama3.2:1b"},'
        '{"name":"mistral:latest"}]}',
      ).listModels();
      expect(OpenAIProvider.curate(models), equals(models));
    });

    test('skips entries with no name', () async {
      final provider = modelsProvider('{"models":[{"size":1},{"name":"a"}]}');
      expect(await provider.listModels(), equals(['a']));
    });

    test('returns empty on a non-200 rather than throwing', () async {
      expect(
        await modelsProvider('nope', statusCode: 500).listModels(),
        isEmpty,
      );
    });

    test('returns empty on a malformed body rather than throwing', () async {
      expect(await modelsProvider('not json').listModels(), isEmpty);
    });
  });

  group('OllamaProvider capabilities', () {
    test('reports no native tool use, which drives the ReAct wrapper', () {
      final h = makeProvider(_textResponse);
      expect(h.provider.capabilities.nativeToolUse, isFalse);
      expect(h.provider.capabilities.streaming, isTrue);
    });
  });
}
