import 'dart:async';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/providers/transport.dart';

void main() {
  /// A client whose every request fails at the transport layer.
  http.Client deadClient([String message = 'Connection refused']) => MockClient(
    (request) async => throw http.ClientException(message, request.url),
  );

  group('transportMessage', () {
    test('tells an Ollama user how to start the server', () {
      // A refused connection to a *local* server almost always means it is not
      // running — which the user can fix directly.
      final message = transportMessage(
        const SocketException('Connection refused'),
        'ollama',
        'http://localhost:11434',
      );
      expect(message, contains('Ollama not detected'));
      expect(message, contains('ollama serve'));
    });

    test('names the host for a refused cloud connection', () {
      final message = transportMessage(
        const SocketException('Connection refused'),
        'openai',
        'https://api.openai.com/v1',
      );
      expect(message, contains('api.openai.com'));
      expect(message, contains('Check your connection'));
      expect(message, isNot(contains('ollama serve')));
    });

    test('recognises the errno form of a refused connection', () {
      // macOS surfaces this as "errno = 61" rather than the text form.
      final message = transportMessage(
        'ClientException: OS Error: errno = 61',
        'anthropic',
        'https://api.anthropic.com',
      );
      expect(message, contains('Could not reach'));
    });

    test('distinguishes a DNS failure from a refused connection', () {
      final message = transportMessage(
        'Failed host lookup: no-such-host.example',
        'openai',
        'https://no-such-host.example/v1',
      );
      expect(message, contains('Could not resolve'));
      expect(message, contains('no-such-host.example'));
    });

    test('recognises the macOS DNS failure wording', () {
      final message = transportMessage(
        'nodename nor servname provided, or not known',
        'openai',
        'https://api.openai.com/v1',
      );
      expect(message, contains('Could not resolve'));
    });

    test('reports a timeout as a timeout', () {
      final message = transportMessage(
        TimeoutException('timed out'),
        'openai',
        'https://api.openai.com/v1',
      );
      expect(message, contains('timed out'));
    });

    test('falls back to the raw error for anything unrecognised', () {
      final message = transportMessage(
        'some novel TLS failure',
        'openai',
        'https://api.openai.com/v1',
      );
      expect(message, contains('failed'));
      expect(message, contains('some novel TLS failure'));
    });

    test('degrades gracefully when baseUrl is not a URL', () {
      final message = transportMessage(
        const SocketException('Connection refused'),
        'openai',
        'not a url',
      );
      expect(message, isNotEmpty);
    });
  });

  group('withTransportErrors', () {
    test('converts a transport failure to LLMError(network)', () {
      expect(
        () => withTransportErrors(
          () async => throw http.ClientException('Connection refused'),
          providerName: 'openai',
          baseUrl: 'https://api.openai.com/v1',
        ),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.network),
        ),
      );
    });

    test('does not double-wrap an LLMError', () {
      // A provider that already produced a typed error must keep its kind and
      // message rather than being reported as a network failure.
      expect(
        () => withTransportErrors(
          () async => throw LLMError(LLMErrorKind.auth, 'bad key'),
          providerName: 'openai',
          baseUrl: 'https://api.openai.com/v1',
        ),
        throwsA(
          isA<LLMError>()
              .having((e) => e.kind, 'kind', LLMErrorKind.auth)
              .having((e) => e.message, 'message', 'bad key'),
        ),
      );
    });

    test('passes a successful result through untouched', () async {
      final result = await withTransportErrors(
        () async => 'ok',
        providerName: 'openai',
        baseUrl: 'https://api.openai.com/v1',
      );
      expect(result, equals('ok'));
    });
  });

  group('withStreamTransportErrors', () {
    test('converts a mid-stream failure to LLMError(network)', () {
      final source = Stream<String>.fromFuture(
        Future.error(http.ClientException('Connection refused')),
      );

      expect(
        withStreamTransportErrors(
          source,
          providerName: 'ollama',
          baseUrl: 'http://localhost:11434',
        ).toList(),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.network),
        ),
      );
    });

    test('passes data through untouched', () async {
      final chunks = await withStreamTransportErrors(
        Stream.fromIterable(['a', 'b']),
        providerName: 'openai',
        baseUrl: 'https://api.openai.com/v1',
      ).toList();
      expect(chunks, equals(['a', 'b']));
    });
  });

  group('transportPost / transportSend', () {
    test('transportPost converts a dead client', () {
      expect(
        () => transportPost(
          deadClient(),
          Uri.parse('https://api.openai.com/v1/chat/completions'),
          headers: const {},
          body: '{}',
          providerName: 'openai',
          baseUrl: 'https://api.openai.com/v1',
        ),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.network),
        ),
      );
    });

    test('transportSend converts a dead client', () {
      expect(
        () => transportSend(
          deadClient(),
          http.Request('POST', Uri.parse('https://api.openai.com/v1/x')),
          providerName: 'openai',
          baseUrl: 'https://api.openai.com/v1',
        ),
        throwsA(
          isA<LLMError>().having((e) => e.kind, 'kind', LLMErrorKind.network),
        ),
      );
    });
  });
}
