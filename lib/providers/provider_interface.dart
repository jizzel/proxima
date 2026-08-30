import '../core/types.dart';

/// Capabilities advertised by a provider.
class ProviderCapabilities {
  final bool nativeToolUse;
  final bool streaming;
  final int contextWindow;
  final List<String> availableModels;

  /// Whether a secondary provider stands behind this one.
  ///
  /// The agent loop needs this to decide what to do when a stream fails
  /// against an unreachable server: with no fallback, calling `complete()`
  /// just repeats the same error, but with one it is the *only* path that
  /// reaches the secondary.
  final bool hasFallback;

  const ProviderCapabilities({
    required this.nativeToolUse,
    required this.streaming,
    required this.contextWindow,
    this.availableModels = const [],
    this.hasFallback = false,
  });
}

/// A streamed chunk from a provider.
class LLMChunk {
  final String text;
  final bool isDone;
  final TokenUsage? finalUsage;

  /// True when the done chunk signals the model made a tool call.
  /// The caller should re-fetch via complete() to get the parsed tool call.
  final bool hasToolUse;

  const LLMChunk({
    required this.text,
    this.isDone = false,
    this.finalUsage,
    this.hasToolUse = false,
  });
}

/// A tool definition sent to the LLM.
class ToolDefinition {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'input_schema': inputSchema,
  };
}

/// A fully structured request sent to a provider.
class CompletionRequest {
  final String model;
  final String systemPrompt;
  final List<Message> messages;
  final List<ToolDefinition> tools;
  final int maxTokens;
  final double temperature;
  final bool stream;

  const CompletionRequest({
    required this.model,
    required this.systemPrompt,
    required this.messages,
    this.tools = const [],
    this.maxTokens = 8192,
    this.temperature = 0.0,
    this.stream = false,
  });
}

/// A completed response from a provider.
class LLMResponse {
  final LLMResponseBody body;
  final TokenUsage usage;
  final String? rawText;

  const LLMResponse({required this.body, required this.usage, this.rawText});
}

/// Abstract LLM provider interface.
abstract class LLMProvider {
  String get name;
  String get model;
  ProviderCapabilities get capabilities;

  /// Single-shot completion.
  Future<LLMResponse> complete(CompletionRequest request);

  /// Streaming completion — yields chunks, final chunk has isDone=true.
  Stream<LLMChunk> stream(CompletionRequest request);

  /// List available models (optional — returns empty if not supported).
  ///
  /// Returns the provider's *complete* catalogue. Narrowing it for an
  /// interactive picker is the caller's job — see `OpenAIProvider.curate`,
  /// which the `/model` picker applies while tab completion keeps the full
  /// list so an older id still resolves.
  Future<List<String>> listModels() async => [];
}

/// Outcome of a model-discovery attempt.
///
/// [listModels] flattens every failure to an empty list, which makes a provider
/// that is unreachable, unauthorised, or simply not configured indistinguishable
/// from one that legitimately serves nothing — the `/model` picker silently
/// showed three Anthropic entries while OpenAI was failing. This keeps the
/// reason so callers can say *why* a provider contributed nothing.
class ModelDiscovery {
  final List<String> models;

  /// Human-readable reason discovery failed, or null when it succeeded.
  final String? error;

  const ModelDiscovery(this.models) : error = null;
  const ModelDiscovery.failed(this.error) : models = const [];

  bool get ok => error == null;
}

extension LLMProviderDiscovery on LLMProvider {
  /// [listModels] with the failure reason preserved.
  ///
  /// Defaults to treating any throw as a failure and any result — including an
  /// empty one — as a success, which is right for a provider with no discovery
  /// endpoint. Providers that talk to a real endpoint override this.
  Future<ModelDiscovery> discoverModels() async {
    try {
      return ModelDiscovery(await listModels());
    } catch (e) {
      return ModelDiscovery.failed(_shortError(e));
    }
  }
}

/// Trims an exception down to something fit for one terminal line.
String _shortError(Object e) {
  var text = e is LLMError ? e.message : e.toString();
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  const limit = 120;
  return text.length <= limit ? text : '${text.substring(0, limit - 1)}…';
}
