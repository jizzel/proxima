import 'package:test/test.dart';
import 'package:proxima/core/secret_masker.dart';

void main() {
  group('maskSecretsInString', () {
    test('masks an Anthropic key', () {
      final masked = maskSecretsInString(
        'export ANTHROPIC_API_KEY=sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123',
      );
      expect(masked, contains('***'));
      expect(masked, isNot(contains('sk-ant-api03')));
    });

    test('masks an OpenAI project key', () {
      final masked = maskSecretsInString(
        'key is sk-proj-EXAMPLEfakeKEY0123456789abcdefGHIJKLMNOPqrstuvwx',
      );
      expect(masked, contains('***'));
      expect(masked, isNot(contains('sk-proj-EXAMPLE')));
    });

    test('masks an Anthropic key fully, not just the sk- prefix', () {
      // Guards pattern ordering: the generic sk- rule must not shadow sk-ant-.
      final masked = maskSecretsInString(
        'sk-ant-api03-AbCdEfGhIjKlMnOpQrStUvWxYz0123456789',
      );
      expect(masked, equals('***'));
      expect(masked, isNot(contains('ant')));
    });

    test('masks a GitHub token', () {
      final masked = maskSecretsInString(
        'ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789',
      );
      expect(masked, equals('***'));
    });

    test('masks an AWS access key id', () {
      final masked = maskSecretsInString('AKIAIOSFODNN7EXAMPLE');
      expect(masked, equals('***'));
    });

    test('masks a JWT', () {
      final masked = maskSecretsInString(
        'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NSJ9.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk',
      );
      expect(masked, equals('***'));
    });

    test('masks a Slack token', () {
      final masked = maskSecretsInString('xoxb-123456789012-abcdefghijkl');
      expect(masked, equals('***'));
    });

    test('masks an authorization header including the scheme', () {
      final masked = maskSecretsInString(
        'curl -H "Authorization: Bearer sk-ant-AbCdEfGhIjKlMnOpQrStUvWx"',
      );
      expect(masked, isNot(contains('sk-ant-')));
      expect(masked, isNot(contains('Bearer sk')));
      expect(masked, contains('***'));
    });

    test('leaves ordinary text untouched', () {
      const input = 'dart test --name "reads a file"';
      expect(maskSecretsInString(input), equals(input));
    });

    test('leaves short sk- lookalikes untouched', () {
      const input = 'sk-short';
      expect(maskSecretsInString(input), equals(input));
    });

    test('returns empty string unchanged', () {
      expect(maskSecretsInString(''), equals(''));
    });
  });

  group('maskSecrets', () {
    test('masks a value whose key name is sensitive', () {
      final masked = maskSecrets({'api_key': 'anything-at-all'});
      expect(masked['api_key'], equals('***'));
    });

    test('matches sensitive key names case-insensitively', () {
      final masked = maskSecrets({'ANTHROPIC_API_KEY': 'abc', 'Token': 'xyz'});
      expect(masked['ANTHROPIC_API_KEY'], equals('***'));
      expect(masked['Token'], equals('***'));
    });

    test('masks a secret embedded in a command string', () {
      final masked = maskSecrets({
        'command':
            'curl -H "Authorization: Bearer sk-ant-AbCdEfGhIjKlMnOpQrSt"',
      });
      expect(masked['command'], isNot(contains('sk-ant-')));
      expect(masked['command'], contains('curl'));
    });

    test('leaves non-secret args untouched', () {
      final args = {'path': 'lib/main.dart', 'max_results': 100};
      final masked = maskSecrets(args);
      expect(masked['path'], equals('lib/main.dart'));
      expect(masked['max_results'], equals(100));
    });

    test('passes through non-string scalars', () {
      final masked = maskSecrets({'count': 5, 'enabled': true, 'none': null});
      expect(masked['count'], equals(5));
      expect(masked['enabled'], isTrue);
      expect(masked['none'], isNull);
    });

    test('recurses into nested maps', () {
      final masked = maskSecrets({
        'config': {'token': 'abc', 'host': 'localhost'},
      });
      final nested = masked['config'] as Map<String, dynamic>;
      expect(nested['token'], equals('***'));
      expect(nested['host'], equals('localhost'));
    });

    test('recurses into lists', () {
      final masked = maskSecrets({
        'commands': ['ls -la', 'echo sk-ant-AbCdEfGhIjKlMnOpQrStUv'],
      });
      final list = masked['commands'] as List;
      expect(list[0], equals('ls -la'));
      expect(list[1], isNot(contains('sk-ant-')));
    });

    test('recurses into maps nested inside lists', () {
      final masked = maskSecrets({
        'headers': [
          {'name': 'Accept', 'value': 'application/json'},
          {'name': 'X-Api', 'secret': 'hunter2'},
        ],
      });
      final list = masked['headers'] as List;
      expect((list[0] as Map)['value'], equals('application/json'));
      expect((list[1] as Map)['secret'], equals('***'));
    });

    test('does not mutate the input map', () {
      final original = {'api_key': 'sk-ant-AbCdEfGhIjKlMnOpQrStUvWx'};
      maskSecrets(original);
      expect(original['api_key'], equals('sk-ant-AbCdEfGhIjKlMnOpQrStUvWx'));
    });

    test('returns an empty map unchanged', () {
      expect(maskSecrets({}), isEmpty);
    });
  });
  group('maskSecretsInString — Authorization schemes', () {
    // Regression: the original pattern consumed the scheme as its \S+ token,
    // so `Authorization: Basic <cred>` masked only `Authorization: Basic` and
    // wrote the credential to disk verbatim.
    test('masks the credential after Basic', () {
      final masked = maskSecretsInString(
        'Authorization: Basic dXNlcjpwYXNzd29yZA==',
      );
      expect(masked, isNot(contains('dXNlcjpwYXNzd29yZA')));
      expect(masked, contains('***'));
    });

    test('masks an opaque bearer credential with no provider prefix', () {
      final masked = maskSecretsInString(
        'Authorization: Bearer opaque-token-value-here',
      );
      expect(masked, isNot(contains('opaque-token')));
      expect(masked, contains('***'));
    });

    test('masks Token and Digest schemes', () {
      expect(
        maskSecretsInString('authorization=Token abc123def456ghi'),
        isNot(contains('abc123def456ghi')),
      );
      expect(
        maskSecretsInString('Authorization: Digest xyz789abc123def'),
        isNot(contains('xyz789abc123def')),
      );
    });

    test('masks a bare scheme with no Authorization prefix', () {
      final masked = maskSecretsInString('-H "Bearer rawtokenvalue123"');
      expect(masked, isNot(contains('rawtokenvalue123')));
    });

    test('preserves the surrounding command and closing quote', () {
      final masked = maskSecretsInString(
        'curl -H "Authorization: Basic dXNlcjpwYXNz" https://api.example.com',
      );
      expect(masked, isNot(contains('dXNlcjpwYXNz')));
      expect(masked, startsWith('curl -H "'));
      expect(masked, endsWith('" https://api.example.com'));
    });

    test('does not mangle ordinary prose containing scheme words', () {
      // `basic`/`bearer` appear in normal commit messages and test names.
      for (final input in [
        'git commit -m "basic cleanup"',
        'echo "bearer of bad news"',
        'dart test --name "basic auth flow"',
      ]) {
        expect(maskSecretsInString(input), equals(input), reason: input);
      }
    });
  });

  group('maskSecrets — key-name separator normalisation', () {
    // Regression: lowercasing alone missed hyphenated names, so a plugin
    // argument called `api-key` was persisted unmasked.
    test('masks hyphenated, dotted, and camelCase spellings', () {
      for (final key in [
        'api-key',
        'x-api-key',
        'private-key',
        'access-token',
        'client-secret',
        'user.password',
        'apiKey',
        'authToken',
        'privateKey',
        'API-KEY',
        'AUTH_TOKEN',
      ]) {
        expect(
          maskSecrets({key: 'PLAINSECRETVALUE'})[key],
          equals('***'),
          reason: key,
        );
      }
    });

    test('does not mask names that merely contain a fragment', () {
      // Matching is per underscore-delimited segment, so `author` does not
      // collide with `auth`, nor `tokenizer` with `token`.
      for (final key in [
        'author',
        'authors',
        'authentic',
        'tokenizer',
        'secretary',
        'keyword',
        'path',
        'pattern',
        'max_results',
      ]) {
        expect(
          maskSecrets({key: 'ordinary-value'})[key],
          equals('ordinary-value'),
          reason: key,
        );
      }
    });

    test('masks a hyphenated key holding a non-pattern secret', () {
      // The value has no recognisable provider prefix — only the key name
      // makes it detectable.
      final masked = maskSecrets({'api-key': 'zzzz-internal-format-9999'});
      expect(masked['api-key'], equals('***'));
    });
  });
}
