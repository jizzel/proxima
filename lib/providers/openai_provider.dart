import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../core/types.dart';
import 'provider_interface.dart';
import 'transport.dart';

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
  final int _contextWindow;

  OpenAIProvider({
    required String model,
    required String apiKey,
    String baseUrl = 'https://api.openai.com/v1',
    http.Client? client,
    int? contextWindow,
  }) : _model = model,
       _apiKey = apiKey,
       _baseUrl = baseUrl,
       _client = client ?? http.Client(),
       _contextWindow = contextWindow ?? contextWindowFor(model);

  /// Best-effort context window for [model], in tokens.
  ///
  /// Advertising a single figure for every model is unsafe: `baseUrl` may point
  /// at an endpoint serving 4K or 8K models, and `ContextBuilder` derives the
  /// whole token budget — including a 10% output allowance — from this number.
  /// Over-reporting makes requests fail as a session grows.
  ///
  /// Known OpenAI families are matched by prefix; anything unrecognised gets a
  /// conservative 8K, which every chat model can honour. Override it with
  /// `openai_context_window` in config for a larger custom endpoint.
  static int contextWindowFor(String model) {
    final id = model.toLowerCase();
    // Strip any vendor prefix used by proxy endpoints (e.g. "openai/gpt-4o").
    final bare = id.contains('/') ? id.split('/').last : id;

    if (bare.startsWith('gpt-4.1') || bare.startsWith('gpt-4.5')) {
      return 1000000;
    }
    if (bare.startsWith('gpt-5')) return 400000;
    if (RegExp(r'^o\d').hasMatch(bare)) return 200000;
    if (bare.startsWith('gpt-4o') || bare.startsWith('gpt-4-turbo')) {
      return 128000;
    }
    if (bare.startsWith('gpt-4-32k')) return 32768;
    if (bare.startsWith('gpt-4')) return 8192;
    if (bare.startsWith('gpt-3.5-turbo-16k')) return 16384;
    if (bare.startsWith('gpt-3.5')) return 16385;
    // Unknown model, very likely a non-OpenAI compatible endpoint. Assume the
    // smallest window in common use rather than risk over-reporting.
    return 8192;
  }

  @override
  String get name => 'openai';

  @override
  String get model => _model;

  @override
  ProviderCapabilities get capabilities => ProviderCapabilities(
    nativeToolUse: true,
    streaming: true,
    contextWindow: _contextWindow,
  );

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    final body = _buildRequestBody(request, stream: false);

    final http.Response response;
    try {
      response = await _client.post(
        Uri.parse('$_baseUrl/chat/completions'),
        headers: _headers(),
        body: jsonEncode(body),
      );
    } on Exception catch (e) {
      // A transport failure (DNS, refused connection, TLS, timeout) surfaces
      // as ClientException/SocketException, not an HTTP response. It must
      // become an LLMError or FallbackProvider — which only catches LLMError —
      // will not try the secondary during the outage it exists to cover.
      throw LLMError(LLMErrorKind.network, 'Request to $_baseUrl failed: $e');
    }

    if (response.statusCode != 200) {
      // The API names the parameter it will not accept; drop it and retry once
      // rather than trying to predict per-model support from the name.
      final unsupported = _unsupportedParameter(
        response.statusCode,
        response.body,
      );
      final needsEffortNone = _needsReasoningEffortNone(
        response.statusCode,
        response.body,
      );
      if ((unsupported != null && body.containsKey(unsupported)) ||
          needsEffortNone) {
        final retryBody = Map<String, dynamic>.from(body);
        if (unsupported != null) retryBody.remove(unsupported);
        if (needsEffortNone) retryBody['reasoning_effort'] = 'none';
        final retry = await transportPost(
          _client,
          Uri.parse('$_baseUrl/chat/completions'),
          headers: _headers(),
          body: jsonEncode(retryBody),
          providerName: name,
          baseUrl: _baseUrl,
        );
        if (retry.statusCode != 200) {
          throw _parseError(retry.statusCode, retry.body);
        }
        return _parseResponse(jsonDecode(retry.body) as Map<String, dynamic>);
      }
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

    final http.StreamedResponse response;
    try {
      response = await _client.send(httpRequest);
    } on Exception catch (e) {
      throw LLMError(LLMErrorKind.network, 'Request to $_baseUrl failed: $e');
    }

    if (response.statusCode != 200) {
      final errorBody = await response.stream.bytesToString();
      // The agent loop re-issues via complete() when the stream fails, and
      // complete() performs the unsupported-parameter retry — so surfacing the
      // error here is enough; no need to duplicate the retry on this path.
      throw _parseError(response.statusCode, errorBody);
    }

    final buffer = StringBuffer();
    TokenUsage? finalUsage;
    bool hasToolUse = false;

    // A connection dropped mid-stream throws from the body stream too; it must
    // also surface as an LLMError so the agent loop and FallbackProvider can
    // handle it rather than crashing the turn.
    final decoded = withStreamTransportErrors(
      response.stream.transform(utf8.decoder),
      providerName: name,
      baseUrl: _baseUrl,
    );

    await for (final chunk in decoded) {
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
            ..sort((a, b) {
              final rank = _modelRank(a).compareTo(_modelRank(b));
              return rank != 0 ? rank : a.compareTo(b);
            });
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
    final lower = id.toLowerCase();

    // Non-chat modalities — these cannot serve a completion at all.
    const excludedSubstrings = [
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
    if (excludedSubstrings.any(lower.contains)) return false;

    // Legacy /v1/completions models. They appear in the catalogue but 404 on
    // /v1/chat/completions, so offering them in the picker is a trap.
    if (lower.startsWith('babbage') || lower.startsWith('davinci')) {
      return false;
    }
    // Only OpenAI's gpt-3.5-turbo-instruct is a completions model. "Instruct"
    // is standard naming for open-weight *chat* models (qwen2.5-coder-instruct,
    // mistral-instruct), so this must not be a blanket substring rule.
    if (lower.startsWith('gpt-3.5-turbo-instruct')) return false;

    // A bare alias, not a selectable model. Matched exactly rather than by
    // substring — `gpt-5.3-chat-latest` is a real model.
    if (lower == 'chat-latest') return false;

    // Codex models are listed in the catalogue but are not served by
    // /v1/chat/completions — they are either deprecated or Responses-API only.
    // Verified against the live API: gpt-5-codex and gpt-5.1-codex return
    // "deprecated", gpt-5.3-codex returns "not supported in this endpoint".
    if (lower.contains('-codex')) return false;

    return true;
  }

  /// Orders model ids so current families surface first.
  ///
  /// The catalogue is returned roughly alphabetically, which buries `gpt-5`
  /// and `gpt-4o` under a dozen deprecated `gpt-3.5-turbo-*` variants and
  /// makes the `/model` picker and tab completion hard to use.
  static int _modelRank(String id) {
    final lower = id.toLowerCase();
    if (lower.startsWith('gpt-5')) return 0;
    if (lower.startsWith('gpt-4.1') || lower.startsWith('gpt-4.5')) return 1;
    if (RegExp(r'^o\d').hasMatch(lower)) return 2;
    if (lower.startsWith('gpt-4o')) return 3;
    if (lower.startsWith('gpt-4')) return 4;
    return 5;
  }

  /// Extracts the request parameter that a 400 says is unsupported, if any.
  ///
  /// Which parameters a model accepts does not follow family boundaries and
  /// changes as models ship — verified live, `gpt-5` rejects `temperature`
  /// while `gpt-5.1` and `gpt-5.2` accept it. Rather than predict from the
  /// model name (which has been wrong repeatedly), let the API tell us and
  /// retry once without the offending field.
  ///
  /// Recognises the two shapes OpenAI uses:
  ///   "Unsupported value: 'temperature' does not support 0.0 with this model"
  ///   "Unsupported parameter: 'max_tokens' is not supported with this model"
  static String? _unsupportedParameter(int statusCode, String body) {
    if (statusCode != 400) return null;
    final match = RegExp(
      r"Unsupported (?:value|parameter):\s*'([^']+)'",
      caseSensitive: false,
    ).firstMatch(body);
    return match?.group(1);
  }

  /// Whether the API is asking for `reasoning_effort: "none"` to allow tools.
  ///
  /// Some reasoning models refuse function tools while reasoning is active:
  ///   "Function tools with reasoning_effort are not supported for X in
  ///    /v1/chat/completions. … or set reasoning_effort to 'none'."
  /// The message names the remedy, so apply it rather than maintaining a list
  /// of which models need it.
  static bool _needsReasoningEffortNone(int statusCode, String body) =>
      statusCode == 400 &&
      body.contains('reasoning_effort') &&
      body.contains('Function tools');

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

    // Sent unconditionally. Support does not follow model families — verified
    // live, `gpt-5` rejects an explicit temperature while `gpt-5.1` accepts it
    // — so instead of predicting from the name, complete() retries once
    // without whichever parameter a 400 names as unsupported.
    body['temperature'] = request.temperature;

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
