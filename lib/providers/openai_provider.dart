import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/types.dart';
import 'provider_interface.dart';

/// OpenAI Chat Completions provider with native tool use and SSE streaming.
///
/// [baseUrl] is injectable so this also serves any endpoint that speaks the
/// OpenAI wire format — Groq, Together, OpenRouter, LM Studio — without a
/// separate provider class.
///
/// Azure OpenAI is **not** supported: it needs an `api-key` header rather than
/// `Authorization: Bearer`, a `/openai/deployments/{deployment}/…` path, and an
/// `api-version` query parameter. Pointing [baseUrl] at Azure will fail with a
/// 401 or 404.
class OpenAIProvider implements LLMProvider {
  final String _model;
  final String _apiKey;
  final String _baseUrl;
  final http.Client _client;

  OpenAIProvider({
    required String model,
    required String apiKey,
    String baseUrl = 'https://api.openai.com/v1',
    http.Client? client,
  }) : _model = model,
       _apiKey = apiKey,
       _baseUrl = baseUrl,
       _client = client ?? http.Client();

  @override
  String get name => 'openai';

  @override
  String get model => _model;

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
    nativeToolUse: true,
    streaming: true,
    contextWindow: 128000,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    final body = _buildRequestBody(request, stream: false);
    final response = await _client.post(
      Uri.parse('$_baseUrl/chat/completions'),
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
    final httpRequest =
        http.Request('POST', Uri.parse('$_baseUrl/chat/completions'))
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
        if (data.isEmpty) continue;

        if (data == '[DONE]') {
          yield LLMChunk(
            text: '',
            isDone: true,
            finalUsage: finalUsage,
            hasToolUse: hasToolUse,
          );
          return;
        }

        try {
          final event = jsonDecode(data) as Map<String, dynamic>;

          // Usage arrives in its own final chunk when stream_options
          // include_usage is set; that chunk has an empty choices list.
          final usage = event['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            finalUsage = _parseUsage(usage);
          }

          final choices = event['choices'] as List<dynamic>?;
          if (choices == null || choices.isEmpty) continue;
          final choice = choices.first as Map<String, dynamic>;

          // A tool call is signalled by delta.tool_calls. We only need to
          // detect it — the agent loop discards the streamed buffer and
          // re-issues via complete() to parse the call properly.
          final delta = choice['delta'] as Map<String, dynamic>?;
          if (delta?['tool_calls'] != null) {
            hasToolUse = true;
          }

          if (!hasToolUse) {
            final text = delta?['content'] as String? ?? '';
            if (text.isNotEmpty) {
              yield LLMChunk(text: text);
            }
          }

          if (choice['finish_reason'] != null) {
            if (choice['finish_reason'] == 'tool_calls') {
              hasToolUse = true;
            }
            // Do not return yet — the usage chunk follows finish_reason when
            // include_usage is set. Termination happens on [DONE] or when the
            // stream closes.
          }
        } catch (_) {
          // Ignore malformed SSE lines.
        }
      }
    }

    yield LLMChunk(
      text: '',
      isDone: true,
      finalUsage: finalUsage,
      hasToolUse: hasToolUse,
    );
  }

  /// Fetches the live model list so newly released models appear without a
  /// code change. Returns an empty list on any failure — callers treat an
  /// empty list as "unavailable" and fall back to other providers' entries.
  @override
  Future<List<String>> listModels() async {
    try {
      final response = await _client.get(
        Uri.parse('$_baseUrl/models'),
        headers: _headers(),
      );
      if (response.statusCode != 200) return [];

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final data = json['data'] as List<dynamic>? ?? [];
      final ids =
          data
              .map((m) => (m as Map<String, dynamic>)['id'] as String? ?? '')
              .where(_isChatModel)
              .toList()
            ..sort();
      return ids;
    } catch (_) {
      return [];
    }
  }

  /// Filters the raw model catalogue down to chat-capable models.
  ///
  /// This is an **exclusion** filter, not an allow-list. `baseUrl` may point at
  /// any OpenAI-compatible endpoint — Groq, Together, OpenRouter, LM Studio —
  /// whose ids look nothing like OpenAI's (`llama-3.3-70b`,
  /// `meta-llama/Llama-3-70b`, `anthropic/claude-sonnet-4`). An allow-list
  /// keyed on `gpt`/`o<n>` would filter every one of those out and leave the
  /// picker empty against an endpoint that works fine.
  ///
  /// So: keep everything except ids that clearly name a non-chat modality.
  /// A new chat model appears automatically whatever it is called; the cost of
  /// the occasional false positive is one unusable entry in the picker.
  static bool _isChatModel(String id) {
    if (id.isEmpty) return false;
    const excluded = [
      'embed',
      'whisper',
      'tts',
      'dall-e',
      'moderation',
      'audio',
      'realtime',
      'image',
      'transcribe',
      'rerank',
      'stable-diffusion',
      'flux',
      'guard',
    ];
    final lower = id.toLowerCase();
    return !excluded.any(lower.contains);
  }

  /// Whether [model] accepts an explicit `temperature`.
  ///
  /// The o-series reasoning models (o1, o3, o4, …) support only their default
  /// and return a 400 for any explicit value, including 0.
  static bool _supportsTemperature(String model) {
    final id = model.toLowerCase();
    // Match a leading o<digit>, with or without a vendor prefix — proxy
    // endpoints such as OpenRouter namespace ids ("o3-mini", "openai/o3").
    return !RegExp(r'(^|/)o\d').hasMatch(id);
  }

  Map<String, String> _headers() => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $_apiKey',
  };

  Map<String, dynamic> _buildRequestBody(
    CompletionRequest request, {
    required bool stream,
  }) {
    final messages = <Map<String, dynamic>>[];

    // OpenAI takes the system prompt as the first message, not a top-level
    // field (Anthropic uses a top-level `system` string).
    if (request.systemPrompt.isNotEmpty) {
      messages.add({'role': 'system', 'content': request.systemPrompt});
    }
    messages.addAll(
      request.messages
          .where((m) => m.role != MessageRole.system)
          .map(_messageToJson),
    );

    final body = <String, dynamic>{
      // Use _model (the bare id from ProviderRegistry), not request.model —
      // the latter carries the full "openai/gpt-4o" spec, which the API
      // rejects with "invalid model ID".
      'model': _model,
      'max_completion_tokens': request.maxTokens,
      'messages': messages,
      'stream': stream,
    };

    // The o-series reasoning models accept only their default temperature and
    // reject an explicit value with a 400, so the field is omitted for them.
    if (_supportsTemperature(_model)) {
      body['temperature'] = request.temperature;
    }

    // Without this, streamed responses carry no usage and cost reports as zero.
    if (stream) {
      body['stream_options'] = {'include_usage': true};
    }

    if (request.tools.isNotEmpty) {
      body['tools'] = request.tools
          .map(
            (t) => {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.inputSchema,
              },
            },
          )
          .toList();
    }

    return body;
  }

  Map<String, dynamic> _messageToJson(Message m) {
    // Tool results are their own role in OpenAI; Anthropic nests them in a
    // user message instead.
    if (m.role == MessageRole.tool) {
      return {
        'role': 'tool',
        'tool_call_id': m.toolCallId ?? '',
        'content': m.content,
      };
    }

    // Assistant tool call. `arguments` must be a JSON-encoded *string*, not an
    // object — this is the most common source of 400s when porting from the
    // Anthropic shape.
    if (m.role == MessageRole.assistant && m.toolInput != null) {
      return {
        'role': 'assistant',
        'content': m.content.isEmpty ? null : m.content,
        'tool_calls': [
          {
            'id': m.toolCallId ?? 'call_0',
            'type': 'function',
            'function': {
              'name': m.toolName ?? '',
              'arguments': jsonEncode(m.toolInput),
            },
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
    final tokenUsage = _parseUsage(json['usage'] as Map<String, dynamic>?);

    final choices = json['choices'] as List<dynamic>? ?? [];
    if (choices.isEmpty) {
      return LLMResponse(body: FinalResponse(''), usage: tokenUsage);
    }

    final choice = choices.first as Map<String, dynamic>;
    final message = choice['message'] as Map<String, dynamic>? ?? {};
    final finishReason = choice['finish_reason'] as String?;
    final content = message['content'] as String?;

    if (finishReason == 'tool_calls') {
      final toolCalls = message['tool_calls'] as List<dynamic>? ?? [];
      if (toolCalls.isNotEmpty) {
        final call = toolCalls.first as Map<String, dynamic>;
        final fn = call['function'] as Map<String, dynamic>? ?? {};
        final rawArgs = fn['arguments'] as String? ?? '{}';

        Map<String, dynamic> args;
        try {
          args = rawArgs.trim().isEmpty
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(jsonDecode(rawArgs) as Map);
        } catch (e) {
          throw LLMError(
            LLMErrorKind.schemaViolation,
            'Malformed tool arguments JSON from OpenAI: $rawArgs',
          );
        }

        final toolCall = ToolCall(
          tool: fn['name'] as String? ?? '',
          args: args,
          // OpenAI has no thinking blocks; any prose alongside the call is
          // the closest equivalent.
          reasoning: content ?? '',
          // Must be preserved: OpenAI rejects a tool_call_id it did not issue,
          // and the agent loop replays this value on the next request.
          callId: call['id'] as String?,
        );
        return LLMResponse(body: ToolCallResponse(toolCall), usage: tokenUsage);
      }
    }

    final text = content ?? '';
    return LLMResponse(
      body: FinalResponse(text),
      usage: tokenUsage,
      rawText: text,
    );
  }

  TokenUsage _parseUsage(Map<String, dynamic>? usage) {
    final inputTokens = usage?['prompt_tokens'] as int? ?? 0;
    final outputTokens = usage?['completion_tokens'] as int? ?? 0;
    return TokenUsage(
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      totalTokens:
          usage?['total_tokens'] as int? ?? (inputTokens + outputTokens),
    );
  }

  LLMError _parseError(int statusCode, String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'] as Map<String, dynamic>?;
      final message = error?['message'] as String? ?? body;
      return switch (statusCode) {
        401 || 403 => LLMError(LLMErrorKind.auth, message),
        429 => LLMError(LLMErrorKind.rateLimit, message),
        _ => LLMError(LLMErrorKind.unknown, 'HTTP $statusCode: $message'),
      };
    } catch (_) {
      return LLMError(LLMErrorKind.unknown, 'HTTP $statusCode: $body');
    }
  }
}
