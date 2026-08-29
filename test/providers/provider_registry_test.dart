import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/providers/anthropic_provider.dart';
import 'package:proxima/providers/openai_provider.dart';
import 'package:proxima/providers/provider_registry.dart';
import 'package:proxima/providers/react_fallback.dart';

void main() {
  group('ProviderRegistry', () {
    test('creates an OpenAIProvider for an openai/ spec', () {
      final registry = ProviderRegistry(env: {'OPENAI_API_KEY': 'sk-test'});
      final provider = registry.create('openai/gpt-4o');
      expect(provider, isA<OpenAIProvider>());
      expect(provider.name, equals('openai'));
      expect(provider.model, equals('gpt-4o'));
    });

    test('does not wrap OpenAI in ReActFallback (native tool use)', () {
      final registry = ProviderRegistry(env: {'OPENAI_API_KEY': 'sk-test'});
      final provider = registry.create('openai/gpt-4o');
      expect(provider, isNot(isA<ReActFallback>()));
      expect(provider.capabilities.nativeToolUse, isTrue);
    });

    test('wraps Ollama in ReActFallback (no native tool use)', () {
      final registry = ProviderRegistry(env: const {});
      final provider = registry.create('ollama/qwen2.5-coder:32b');
      expect(provider, isA<ReActFallback>());
      expect(provider.capabilities.nativeToolUse, isFalse);
    });

    test('throws auth error when OPENAI_API_KEY is missing', () {
      final registry = ProviderRegistry(env: const {});
      expect(
        () => registry.create('openai/gpt-4o'),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.auth),
        ),
      );
    });

    test('creates an AnthropicProvider for an anthropic/ spec', () {
      final registry = ProviderRegistry(env: {'ANTHROPIC_API_KEY': 'sk-ant'});
      expect(
        registry.create('anthropic/claude-sonnet-4-6'),
        isA<AnthropicProvider>(),
      );
    });

    test('an env map with all provider keys serves every provider', () {
      // Regression: the write critic built its own registry with only the
      // Anthropic and Ollama keys, so an OpenAI-backed write_file threw an
      // auth error before the permission prompt. Both call sites now share
      // ProximaRepl._buildProviderRegistry().
      final registry = ProviderRegistry(
        env: {
          'ANTHROPIC_API_KEY': 'sk-ant',
          'OPENAI_API_KEY': 'sk-proj',
          'OPENAI_BASE_URL': 'https://api.openai.com/v1',
          'OLLAMA_BASE_URL': 'http://localhost:11434',
        },
      );
      expect(registry.create('openai/gpt-4o'), isA<OpenAIProvider>());
      expect(
        registry.create('anthropic/claude-sonnet-4-6'),
        isA<AnthropicProvider>(),
      );
      expect(registry.create('ollama/qwen2.5-coder:32b'), isA<ReActFallback>());
    });

    test('honours an injected OPENAI_BASE_URL', () {
      final registry = ProviderRegistry(
        env: {
          'OPENAI_API_KEY': 'sk-proj',
          'OPENAI_BASE_URL': 'https://api.groq.com/openai/v1',
        },
      );
      // Construction must succeed against a compatible endpoint.
      expect(
        registry.create('openai/llama-3.3-70b-versatile'),
        isA<OpenAIProvider>(),
      );
    });

    test('throws for an unknown provider name', () {
      final registry = ProviderRegistry(env: const {});
      expect(
        () => registry.create('gemini/gemini-2.5-pro'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('model names containing slashes are preserved', () {
      final registry = ProviderRegistry(env: {'OPENAI_API_KEY': 'sk-test'});
      expect(
        registry.create('openai/org/custom-model').model,
        equals('org/custom-model'),
      );
    });

    test('falls back to the secondary on a non-auth error', () async {
      // A bad base URL makes the primary fail with a network-ish error; the
      // fallback spec is best-effort and must not throw at construction.
      final registry = ProviderRegistry(env: {'OPENAI_API_KEY': 'sk-test'});
      final provider = registry.create(
        'openai/gpt-4o',
        fallbackModel: 'ollama/qwen2.5-coder:32b',
      );
      expect(provider.name, contains('fallback'));
    });

    test('returns the primary when the fallback spec is invalid', () {
      final registry = ProviderRegistry(env: {'OPENAI_API_KEY': 'sk-test'});
      final provider = registry.create(
        'openai/gpt-4o',
        fallbackModel: 'nonsense/model',
      );
      expect(provider, isA<OpenAIProvider>());
    });
  });
}
