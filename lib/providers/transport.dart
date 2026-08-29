/// Shared transport-error handling for HTTP providers.
///
/// `http.Client` throws `ClientException` / `SocketException` when a request
/// never reaches the server — DNS failure, refused connection, TLS error,
/// timeout. Those are not `LLMError`, so without conversion they escape the
/// provider entirely: `FallbackProvider` (which catches only `LLMError`) never
/// tries the secondary during the outage it exists to cover, and the raw
/// socket text reaches the user's terminal.
///
/// Every provider routes its HTTP calls through these helpers so the behaviour
/// cannot drift between them again.
library;

import 'dart:async';
import 'package:http/http.dart' as http;
import '../core/types.dart';

/// Runs [send] and converts any transport failure into an [LLMError].
///
/// [providerName] and [baseUrl] are used to build an actionable message —
/// a refused connection to a local Ollama server needs different advice from
/// a refused connection to a cloud API.
Future<T> withTransportErrors<T>(
  Future<T> Function() send, {
  required String providerName,
  required String baseUrl,
}) async {
  try {
    return await send();
  } on LLMError {
    rethrow; // Already converted — do not double-wrap.
  } on Exception catch (e) {
    throw LLMError(
      LLMErrorKind.network,
      transportMessage(e, providerName, baseUrl),
    );
  }
}

/// Wraps a response body stream so a mid-transfer drop also surfaces as an
/// [LLMError] rather than crashing the turn.
Stream<T> withStreamTransportErrors<T>(
  Stream<T> source, {
  required String providerName,
  required String baseUrl,
}) => source.handleError(
  (Object e) => throw LLMError(
    LLMErrorKind.network,
    transportMessage(e, providerName, baseUrl),
  ),
  test: (e) => e is! LLMError,
);

/// Builds a human-readable message for a transport failure.
///
/// A connection refused by a *local* server almost always means the server is
/// not running, which the user can fix directly — so say that, rather than
/// printing a socket dump. The underlying detail is still appended for
/// `--debug`, but the actionable sentence comes first.
String transportMessage(Object error, String providerName, String baseUrl) {
  final text = error.toString();
  final refused =
      text.contains('Connection refused') || text.contains('errno = 61');

  if (refused) {
    if (providerName == 'ollama') {
      return 'Ollama not detected at $baseUrl. Run: ollama serve';
    }
    final host = Uri.tryParse(baseUrl)?.host ?? baseUrl;
    return 'Could not reach $host. Check your connection.';
  }

  if (text.contains('Failed host lookup') ||
      text.contains('nodename nor servname')) {
    final host = Uri.tryParse(baseUrl)?.host ?? baseUrl;
    return 'Could not resolve $host. Check your connection.';
  }

  if (text.contains('TimeoutException') || text.contains('timed out')) {
    return 'Request to $baseUrl timed out.';
  }

  return 'Request to $baseUrl failed: $error';
}

/// Convenience wrapper mirroring [http.Client.post].
Future<http.Response> transportPost(
  http.Client client,
  Uri url, {
  required Map<String, String> headers,
  required Object body,
  required String providerName,
  required String baseUrl,
}) => withTransportErrors(
  () => client.post(url, headers: headers, body: body),
  providerName: providerName,
  baseUrl: baseUrl,
);

/// Convenience wrapper mirroring [http.Client.send].
Future<http.StreamedResponse> transportSend(
  http.Client client,
  http.BaseRequest request, {
  required String providerName,
  required String baseUrl,
}) => withTransportErrors(
  () => client.send(request),
  providerName: providerName,
  baseUrl: baseUrl,
);
