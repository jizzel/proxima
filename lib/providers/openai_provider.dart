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

    final response = await transportPost(
      _client,
      Uri.parse('$_baseUrl/chat/completions'),
      headers: _headers(),
      body: jsonEncode(body),
      providerName: name,
      baseUrl: _baseUrl,
    );

    if (response.statusCode != 200) {
      // The API names the parameter it will not accept; drop it and retry once
      // rather than trying to predict per-model support from the name.
      final retryBody = _adjustedBody(body, response.statusCode, response.body);
      if (retryBody != null) {
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

    var response = await transportSend(
      _client,
      httpRequest,
      providerName: name,
      baseUrl: _baseUrl,
    );

    if (response.statusCode != 200) {
      final errorBody = await response.stream.bytesToString();
      // Retry here rather than leaning on the agent loop's complete() fallback:
      // that fallback works, but prints a debug warning on *every* turn for a
      // model with an unsupported parameter, which reads as a broken session.
      final retryBody = _adjustedBody(body, response.statusCode, errorBody);
      if (retryBody == null) {
        throw _parseError(response.statusCode, errorBody);
      }
      final retryRequest =
          http.Request('POST', Uri.parse('$_baseUrl/chat/completions'))
            ..headers.addAll(_headers())
            ..body = jsonEncode(retryBody);
      response = await transportSend(
        _client,
        retryRequest,
        providerName: name,
        baseUrl: _baseUrl,
      );
      if (response.statusCode != 200) {
        throw _parseError(
          response.statusCode,
          await response.stream.bytesToString(),
        );
      }
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

      return _parseModelList(response.body);
    } catch (_) {
      return [];
    }
  }

  /// Narrows the catalogue to the newest few generations for the `/model`
  /// picker.
  ///
  /// OpenAI's catalogue carries every generation ever shipped — 69 chat-capable
  /// ids at the time of writing, of which 29 are dated snapshots duplicating an
  /// alias they are identical to. Presenting all of them makes the picker a
  /// scrolling wall rather than a choice, so this keeps only [_keptGenerations]
  /// version families.
  ///
  /// Nothing is made unreachable: `--model openai/gpt-4o`, the config file, and
  /// `/model <id>` all accept any id the endpoint serves. Tab completion still
  /// offers the full [listModels] list.
  ///
  /// Falls back to the full list whenever curation cannot be applied
  /// meaningfully — an endpoint whose ids carry no `name-<major>.<minor>`
  /// version (Groq, LM Studio, OpenRouter) would otherwise yield an empty
  /// picker.
  /// Decodes and orders the ids from a `/models` body.
  static List<String> _parseModelList(String body) {
    final json = jsonDecode(body) as Map<String, dynamic>;
    final data = json['data'] as List<dynamic>? ?? [];
    return data
        .map((m) => (m as Map<String, dynamic>)['id'] as String? ?? '')
        .where(_isChatModel)
        .toList()
      ..sort((a, b) {
        final rank = _modelRank(a).compareTo(_modelRank(b));
        return rank != 0 ? rank : a.compareTo(b);
      });
  }

  /// [listModels] with the reason for a failure preserved, so the picker can
  /// say why OpenAI contributed nothing instead of silently showing a short
  /// list. A 401 here is by far the most common cause and used to be invisible.
  Future<ModelDiscovery> discoverModels() async {
    try {
      final response = await _client.get(
        Uri.parse('$_baseUrl/models'),
        headers: _headers(),
      );
      if (response.statusCode != 200) {
        return ModelDiscovery.failed(
          _discoveryError(response.statusCode, response.body),
        );
      }
      return ModelDiscovery(_parseModelList(response.body));
    } catch (e) {
      return ModelDiscovery.failed(transportMessage(e, name, _baseUrl));
    }
  }

  /// A one-line reason for a non-200 from `/models`.
  static String _discoveryError(int statusCode, String body) {
    final apiMessage = _errorMessage(body);
    return switch (statusCode) {
      401 => 'invalid API key (401)',
      403 => 'access denied (403)',
      429 => 'rate limited (429)',
      _ =>
        apiMessage == null
            ? 'HTTP $statusCode'
            : 'HTTP $statusCode — $apiMessage',
    };
  }

  /// Pulls `error.message` out of an API error body, if present.
  static String? _errorMessage(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final error = json['error'];
      if (error is Map<String, dynamic>) return error['message'] as String?;
    } catch (_) {
      // Not JSON — the status code alone is the whole story.
    }
    return null;
  }

  /// Fetches the catalogue already narrowed for the `/model` picker.
  Future<List<String>> listCuratedModels() async => curate(await listModels());

  /// Narrows an already-fetched model list. A pure function so the REPL can
  /// curate its cached list without a second network round-trip — the cache is
  /// kept complete because tab completion still resolves older ids.
  static List<String> curate(List<String> all) {
    final undated = all.where((id) => !_datedSnapshot.hasMatch(id)).toList();
    if (undated.isEmpty) return all;

    // Rank versions *within* each family, never across the catalogue. A single
    // global ordering compared unrelated families — `llama-3.3` and `gpt-5.4`
    // are not the same generation, and ranking them together dropped whichever
    // family numbered lower.
    final newestPerFamily = <String, List<double>>{};
    for (final id in undated) {
      final parsed = _parseFamily(id);
      if (parsed == null) continue;
      (newestPerFamily[parsed.family] ??= []).add(parsed.version);
    }
    final keep = <String, Set<double>>{};
    for (final entry in newestPerFamily.entries) {
      final versions = entry.value.toSet().toList()..sort();
      keep[entry.key] = versions.reversed.take(_keptGenerations).toSet();
    }

    final curated = undated.where((id) {
      final parsed = _parseFamily(id);
      // An id with no parseable `name-<major>.<minor>` is not an old
      // generation, just a differently-named one — `o3` and `o4-mini` are
      // current reasoning models. Dropping these would hide working models, so
      // only a *recognised but superseded* version is curated away.
      if (parsed == null) return true;
      return keep[parsed.family]?.contains(parsed.version) ?? true;
    }).toList();

    return curated.isEmpty ? all : curated;
  }

  /// How many versions of each family the picker shows. Three covers the
  /// current generation plus the two before it.
  static const _keptGenerations = 3;

  /// A pinned snapshot such as `gpt-5.2-2025-12-11`, which behaves identically
  /// to the alias it duplicates.
  static final _datedSnapshot = RegExp(r'-20\d\d-\d\d-\d\d$');

  /// Splits `gpt-5.4-mini` into its family (`gpt`) and a sortable version
  /// (5.04), or null when the id carries no recognisable version.
  ///
  /// The minor part is scaled by 100 rather than 10 so `gpt-5.10` sorts above
  /// `gpt-5.9` instead of tying with `gpt-5.1`.
  static ({String family, double version})? _parseFamily(String id) {
    final match = RegExp(
      r'^([a-z]+)-(\d+)(?:\.(\d+))?',
    ).firstMatch(id.toLowerCase());
    if (match == null) return null;
    final major = int.parse(match.group(2)!);
    final minor = int.parse(match.group(3) ?? '0');
    return (family: match.group(1)!, version: major + minor / 100.0);
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
      // Video generation — listed in the catalogue but cannot serve chat, so
      // offering it hands the user a model that fails on first use.
      'sora',
      'veo',
      'runway',
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

  /// Returns a request body adjusted for whatever a 400 says is unsupported,
  /// or null when the error is not one we know how to work around.
  static Map<String, dynamic>? _adjustedBody(
    Map<String, dynamic> body,
    int statusCode,
    String errorBody,
  ) {
    final unsupported = _unsupportedParameter(statusCode, errorBody);
    final needsEffortNone = _needsReasoningEffortNone(statusCode, errorBody);
    if ((unsupported == null || !body.containsKey(unsupported)) &&
        !needsEffortNone) {
      return null;
    }
    final adjusted = Map<String, dynamic>.from(body);
    if (unsupported != null) adjusted.remove(unsupported);
    if (needsEffortNone) adjusted['reasoning_effort'] = 'none';
    return adjusted;
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
