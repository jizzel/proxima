import '../core/types.dart';

/// Capabilities advertised by a provider.
class ProviderCapabilities {
  final bool nativeToolUse;
  final bool streaming;
  final int contextWindow;
  final List<String> availableModels;

  const ProviderCapabilities({
    required this.nativeToolUse,
    required this.streaming,
    required this.contextWindow,
    this.availableModels = const [],
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
  Future<List<String>> listModels() async => [];
}
