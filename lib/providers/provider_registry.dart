import '../core/types.dart';
import 'provider_interface.dart';
import 'anthropic_provider.dart';
import 'ollama_provider.dart';
import 'react_fallback.dart';

/// Creates providers from config strings like "anthropic/claude-sonnet-4-6"
/// or "ollama/qwen2.5-coder:32b".
class ProviderRegistry {
  final Map<String, String> _env;

  ProviderRegistry({Map<String, String>? env}) : _env = env ?? const {};

  /// Parse "provider/model" string and return configured provider.
  LLMProvider create(String providerModel) {
    final parts = providerModel.split('/');
    if (parts.length < 2) {
      throw ArgumentError(
        'Invalid model spec "$providerModel". Expected "provider/model".',
      );
    }

    final providerName = parts[0].toLowerCase();
    final modelName = parts.sublist(1).join('/');

    return switch (providerName) {
      'anthropic' => _createAnthropic(modelName),
      'ollama' => _createOllama(modelName),
      _ => throw ArgumentError('Unknown provider "$providerName".'),
    };
  }

  LLMProvider _createAnthropic(String model) {
    final apiKey = _env['ANTHROPIC_API_KEY'] ?? '';
    if (apiKey.isEmpty) {
      throw LLMError(
        LLMErrorKind.auth,
        'ANTHROPIC_API_KEY environment variable is not set.',
      );
    }
    return AnthropicProvider(model: model, apiKey: apiKey);
  }

  LLMProvider _createOllama(String model) {
    final baseUrl = _env['OLLAMA_BASE_URL'] ?? 'http://localhost:11434';
    final provider = OllamaProvider(model: model, baseUrl: baseUrl);
    // Ollama models don't have native tool use — wrap with ReAct fallback.
    return ReActFallback(provider);
  }
}
