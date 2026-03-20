import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/types.dart';
import 'provider_interface.dart';

/// Anthropic Messages API provider with native tool use and SSE streaming.
class AnthropicProvider implements LLMProvider {
  final String _model;
  final String _apiKey;
  final String _baseUrl;
  final http.Client _client;

  AnthropicProvider({
    required String model,
    required String apiKey,
    String baseUrl = 'https://api.anthropic.com',
    http.Client? client,
  }) : _model = model,
       _apiKey = apiKey,
       _baseUrl = baseUrl,
       _client = client ?? http.Client();

  @override
  String get name => 'anthropic';

  @override
  String get model => _model;

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    nativeToolUse: true,
    streaming: true,
    contextWindow: 200000,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    final body = _buildRequestBody(request, stream: false);
    final response = await _client.post(
      Uri.parse('$_baseUrl/v1/messages'),
      headers: _headers(),
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      throw _parseError(response.statusCode, response.body);
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return _parseResponse(json);
  }

  @override
  Stream<LLMChunk> stream(CompletionRequest request) async* {
    final body = _buildRequestBody(request, stream: true);
    final httpRequest = http.Request('POST', Uri.parse('$_baseUrl/v1/messages'))
      ..headers.addAll(_headers())
      ..body = jsonEncode(body);

    final response = await _client.send(httpRequest);

    if (response.statusCode != 200) {
      final errorBody = await response.stream.bytesToString();
      throw _parseError(response.statusCode, errorBody);
    }

    final buffer = StringBuffer();
    TokenUsage? finalUsage;
    bool hasToolUse = false;

    await for (final chunk in response.stream.transform(utf8.decoder)) {
      buffer.write(chunk);
      final raw = buffer.toString();
      final lines = raw.split('\n');

      // Keep last (potentially incomplete) line in buffer.
      buffer.clear();
      buffer.write(lines.last);

      for (final line in lines.take(lines.length - 1)) {
        if (!line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data == '[DONE]' || data.isEmpty) continue;

        try {
          final event = jsonDecode(data) as Map<String, dynamic>;
          final type = event['type'] as String?;

          if (type == 'content_block_start') {
            // If the model is making a tool call, flag it so we can signal
            // the caller to fall back to complete() for proper parsing.
            final block = event['content_block'] as Map<String, dynamic>?;
            if (block?['type'] == 'tool_use') {
              hasToolUse = true;
            }
          } else if (type == 'content_block_delta') {
            if (!hasToolUse) {
              final delta = event['delta'] as Map<String, dynamic>?;
              final text = delta?['text'] as String? ?? '';
              if (text.isNotEmpty) {
                yield LLMChunk(text: text);
              }
            }
          } else if (type == 'message_delta') {
            final usage = event['usage'] as Map<String, dynamic>?;
            if (usage != null) {
              final inputTokens = usage['input_tokens'] as int? ?? 0;
              final outputTokens = usage['output_tokens'] as int? ?? 0;
              finalUsage = TokenUsage(
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                totalTokens: inputTokens + outputTokens,
              );
            }
          } else if (type == 'message_stop') {
            if (hasToolUse) {
              // Signal caller to re-fetch via complete() for tool-use parsing.
              yield LLMChunk(
                text: '',
                isDone: true,
                finalUsage: finalUsage,
                hasToolUse: true,
              );
            } else {
              yield LLMChunk(text: '', isDone: true, finalUsage: finalUsage);
            }
            return;
          }
        } catch (_) {
          // Ignore malformed SSE lines.
        }
      }
    }

    yield LLMChunk(text: '', isDone: true, finalUsage: finalUsage);
  }

  @override
  Future<List<String>> listModels() async => [
    'claude-opus-4-6',
    'claude-sonnet-4-6',
    'claude-haiku-4-5-20251001',
  ];

  Map<String, String> _headers() => {
    'Content-Type': 'application/json',
    'x-api-key': _apiKey,
    'anthropic-version': '2023-06-01',
  };

  Map<String, dynamic> _buildRequestBody(
    CompletionRequest request, {
    required bool stream,
  }) {
    final messages = request.messages
        .where((m) => m.role != MessageRole.system)
        .map(_messageToJson)
        .toList();

    final body = <String, dynamic>{
      'model': request.model,
      'max_tokens': request.maxTokens,
      'temperature': request.temperature,
      'messages': messages,
      'stream': stream,
    };

    if (request.systemPrompt.isNotEmpty) {
      body['system'] = request.systemPrompt;
    }

    if (request.tools.isNotEmpty) {
      body['tools'] = request.tools.map((t) => t.toJson()).toList();
    }

    return body;
  }

  Map<String, dynamic> _messageToJson(Message m) {
    if (m.role == MessageRole.tool) {
      return {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': m.toolCallId ?? '',
            'content': m.content,
          },
        ],
      };
    }

    if (m.role == MessageRole.assistant && m.toolInput != null) {
      return {
        'role': 'assistant',
        'content': [
          {
            'type': 'tool_use',
            'id': m.toolCallId ?? 'call_0',
            'name': m.toolName ?? '',
            'input': m.toolInput,
          },
        ],
      };
    }

    return {
      'role': m.role == MessageRole.user ? 'user' : 'assistant',
      'content': m.content,
    };
  }

  LLMResponse _parseResponse(Map<String, dynamic> json) {
    final usage = json['usage'] as Map<String, dynamic>?;
    final inputTokens = usage?['input_tokens'] as int? ?? 0;
    final outputTokens = usage?['output_tokens'] as int? ?? 0;
    final tokenUsage = TokenUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      totalTokens: inputTokens + outputTokens,
    );

    final content = json['content'] as List<dynamic>? ?? [];
    final stopReason = json['stop_reason'] as String?;

    // Native tool use.
    if (stopReason == 'tool_use') {
      final toolBlock =
          content.firstWhere(
                (c) => (c as Map)['type'] == 'tool_use',
                orElse: () => null,
              )
              as Map<String, dynamic>?;

      if (toolBlock != null) {
        final toolCall = ToolCall(
          tool: toolBlock['name'] as String,
          args: Map<String, dynamic>.from(toolBlock['input'] as Map? ?? {}),
          reasoning: _extractThinking(content),
          callId: toolBlock['id'] as String?,
        );
        return LLMResponse(body: ToolCallResponse(toolCall), usage: tokenUsage);
      }
    }

    // Text response.
    final textBlock =
        content.firstWhere(
              (c) => (c as Map)['type'] == 'text',
              orElse: () => null,
            )
            as Map<String, dynamic>?;

    final text = textBlock?['text'] as String? ?? '';

    return LLMResponse(
      body: FinalResponse(text),
      usage: tokenUsage,
      rawText: text,
    );
  }

  String _extractThinking(List<dynamic> content) {
    final thinking = content
        .where((c) => (c as Map)['type'] == 'thinking')
        .map((c) => (c as Map)['thinking'] as String? ?? '')
        .join('\n');
    return thinking;
  }

  LLMError _parseError(int statusCode, String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'] as Map<String, dynamic>?;
      final message = error?['message'] as String? ?? body;
      return switch (statusCode) {
        401 => LLMError(LLMErrorKind.auth, message),
        429 => LLMError(LLMErrorKind.rateLimit, message),
        _ => LLMError(LLMErrorKind.unknown, 'HTTP $statusCode: $message'),
      };
    } catch (_) {
      return LLMError(LLMErrorKind.unknown, 'HTTP $statusCode: $body');
    }
  }
}
