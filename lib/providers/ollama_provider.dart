import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/types.dart';
import 'provider_interface.dart';

/// Ollama provider using /api/chat (OpenAI-compatible format).
/// Also compatible with LM Studio.
class OllamaProvider implements LLMProvider {
  final String _model;
  final String _baseUrl;
  final http.Client _client;

  OllamaProvider({
    required String model,
    String baseUrl = 'http://localhost:11434',
    http.Client? client,
  }) : _model = model,
       _baseUrl = baseUrl,
       _client = client ?? http.Client();

  @override
  String get name => 'ollama';

  @override
  String get model => _model;

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    nativeToolUse: false,
    streaming: true,
    contextWindow: 32768,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    final body = _buildRequestBody(request, stream: false);
    final response = await _client.post(
      Uri.parse('$_baseUrl/api/chat'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw LLMError(
        LLMErrorKind.unknown,
        'Ollama HTTP ${response.statusCode}: ${response.body}',
      );
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return _parseResponse(json);
  }

  @override
  Stream<LLMChunk> stream(CompletionRequest request) async* {
    final body = _buildRequestBody(request, stream: true);
    final httpRequest = http.Request('POST', Uri.parse('$_baseUrl/api/chat'))
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(body);

    final response = await _client.send(httpRequest);

    if (response.statusCode != 200) {
      final errorBody = await response.stream.bytesToString();
      throw LLMError(
        LLMErrorKind.unknown,
        'Ollama HTTP ${response.statusCode}: $errorBody',
      );
    }

    final buffer = StringBuffer();
    TokenUsage? finalUsage;

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer.write(chunk);
      final raw = buffer.toString();
      final lines = raw.split('\n');
      buffer.clear();
      buffer.write(lines.last);

      for (final line in lines.take(lines.length - 1)) {
        if (line.trim().isEmpty) continue;
        try {
          final event = jsonDecode(line) as Map<String, dynamic>;
          final message = event['message'] as Map<String, dynamic>?;
          final text = message?['content'] as String? ?? '';
          final done = event['done'] as bool? ?? false;

          if (done) {
            final promptTokens = event['prompt_eval_count'] as int? ?? 0;
            final evalTokens = event['eval_count'] as int? ?? 0;
            finalUsage = TokenUsage(
              inputTokens: promptTokens,
              outputTokens: evalTokens,
              totalTokens: promptTokens + evalTokens,
            );
            yield LLMChunk(text: '', isDone: true, finalUsage: finalUsage);
            return;
          }

          if (text.isNotEmpty) {
            yield LLMChunk(text: text);
          }
        } catch (_) {
          // Ignore malformed lines.
        }
      }
    }

    yield LLMChunk(text: '', isDone: true, finalUsage: finalUsage);
  }

  @override
  Future<List<String>> listModels() async {
    try {
      final response = await _client.get(Uri.parse('$_baseUrl/api/tags'));
      if (response.statusCode != 200) return [];
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final models = json['models'] as List<dynamic>? ?? [];
      return models
          .map((m) => (m as Map<String, dynamic>)['name'] as String? ?? '')
          .where((n) => n.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  Map<String, dynamic> _buildRequestBody(
    CompletionRequest request, {
    required bool stream,
  }) {
    final messages = <Map<String, dynamic>>[];

    if (request.systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': request.systemPrompt});
    }

    for (final m in request.messages) {
      if (m.role == MessageRole.system) continue;
      messages.add({
        'role': switch (m.role) {
          MessageRole.user => 'user',
          MessageRole.assistant => 'assistant',
          MessageRole.tool => 'tool',
          MessageRole.system => 'system',
        },
        'content': m.content,
      });
    }

    return {
      'model': _model,
      'messages': messages,
      'stream': stream,
      'options': {
        'temperature': request.temperature,
        'num_predict': request.maxTokens,
      },
    };
  }

  LLMResponse _parseResponse(Map<String, dynamic> json) {
    final message = json['message'] as Map<String, dynamic>?;
    final text = message?['content'] as String? ?? '';
    final promptTokens = json['prompt_eval_count'] as int? ?? 0;
    final evalTokens = json['eval_count'] as int? ?? 0;
    final usage = TokenUsage(
      inputTokens: promptTokens,
      outputTokens: evalTokens,
      totalTokens: promptTokens + evalTokens,
    );
    return LLMResponse(body: FinalResponse(text), usage: usage, rawText: text);
  }
}
