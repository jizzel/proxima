import '../core/types.dart';
import 'provider_interface.dart';

/// Wraps a primary [LLMProvider] with a secondary fallback.
///
/// On any [LLMError] except [LLMErrorKind.auth] (which indicates a
/// configuration problem the fallback cannot fix), the request is retried
/// transparently on the secondary provider. No changes to [AgentLoop] needed.
class FallbackProvider implements LLMProvider {
  final LLMProvider _primary;
  final LLMProvider _secondary;

  FallbackProvider(this._primary, this._secondary);

  @override
  String get name => '${_primary.name}+fallback(${_secondary.name})';

  @override
  String get model => _primary.model;

  @override
  ProviderCapabilities get capabilities => _primary.capabilities;

  @override
  Future<LLMResponse> complete(CompletionRequest request) async {
    try {
      return await _primary.complete(request);
    } on LLMError catch (e) {
      if (e.kind == LLMErrorKind.auth) rethrow;
      return await _secondary.complete(request);
    }
  }

  @override
  Stream<LLMChunk> stream(CompletionRequest request) async* {
    // Attempt primary stream. On non-auth failure, rethrow so that
    // _streamResponse's catch block falls back to complete(), which will
    // transparently try the secondary via our complete() override above.
    try {
      await for (final chunk in _primary.stream(request)) {
        yield chunk;
      }
    } on LLMError catch (e) {
      if (e.kind == LLMErrorKind.auth) rethrow;
      rethrow; // Let _streamResponse fall back to complete()
    }
  }

  @override
  Future<List<String>> listModels() async {
    try {
      return await _primary.listModels();
    } catch (_) {
      return _secondary.listModels();
    }
  }
}
