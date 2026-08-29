/// Secret masking for data written to disk.
///
/// Tool arguments are persisted in two places — the audit log
/// (`~/.proxima/audit.jsonl`) and session files (`~/.proxima/sessions/*.json`).
/// A user who runs `curl -H "Authorization: Bearer sk-..."` or writes a `.env`
/// file would otherwise leave that secret on disk permanently.
///
/// Masking is applied at the serialisation boundary only — never to the live
/// in-memory session. `AnthropicProvider` sends `Message.toolInput` to the API
/// and `Compaction` reads `toolInput['path']`; masking those in memory would
/// corrupt what the model sees. Terminal output is likewise left untouched, so
/// the permission prompt always shows the real command being approved.
library;

/// Replacement written in place of a detected secret.
const String maskPlaceholder = '***';

/// Argument names whose value is replaced wholesale (case-insensitive
/// substring match on the key).
const List<String> _sensitiveKeyFragments = [
  'api_key',
  'apikey',
  'token',
  'secret',
  'password',
  'passwd',
  'auth',
  // `authorization` is listed explicitly: segment matching means it does not
  // match the `auth` fragment, and structured headers such as
  // {'headers': {'Authorization': 'Token abc'}} would otherwise be persisted
  // verbatim — the key is the only signal there.
  'authorization',
  'credential',
  'private_key',
];

/// Secret-shaped value patterns.
///
/// Order matters: more specific prefixes must precede the generic ones, or
/// `sk-[A-Za-z0-9]{20,}` would shadow `sk-ant-...` and mask only part of it.
final List<RegExp> _secretPatterns = [
  // Authorization headers. Matched first, and deliberately consumes the
  // optional auth scheme (Bearer/Basic/Token/Digest/APIKey) *and* the
  // credential after it — otherwise `Authorization: Basic dXNlcjpwYXNz`
  // masks only `Authorization: Basic` and leaves the credential in the clear.
  RegExp(
    r'''authorization\s*[:=]\s*(?:bearer|basic|token|digest|apikey)?\s*[^\s"'`,;]+''',
    caseSensitive: false,
  ),
  // A bare scheme + credential with no `Authorization:` prefix, e.g. a raw
  // `-H "Bearer abc123"` or a structured header value `'Token abc123'`.
  // Covers the same scheme set as the header rule above — a narrower set would
  // leak Digest/APIKey/Token credentials carried in structured arguments.
  // Requires a credential-shaped token (>=8 chars, no spaces) so ordinary prose
  // such as `git commit -m "basic cleanup"` is not mangled.
  RegExp(
    r'''\b(?:bearer|basic|digest|apikey)\s+[^\s"'`,;]{8,}''',
    caseSensitive: false,
  ),
  // `Token <cred>` is handled separately: `token` is a common English word, so
  // it additionally requires the credential to look like one (no spaces, mixed
  // alphanumeric, >=12 chars) to avoid mangling prose such as
  // `git commit -m "token refresh handling"`.
  RegExp(
    r'''\btoken\s+(?=[^\s"'`,;]*\d)[A-Za-z0-9_\-\.=+/]{12,}''',
    caseSensitive: false,
  ),
  // Anthropic.
  RegExp(r'sk-ant-[A-Za-z0-9_\-]{20,}'),
  // OpenAI project-scoped.
  RegExp(r'sk-proj-[A-Za-z0-9_\-]{20,}'),
  // OpenAI legacy (generic `sk-` — must come after the specific forms).
  RegExp(r'sk-[A-Za-z0-9]{20,}'),
  // GitHub personal/OAuth/server/user tokens.
  RegExp(r'gh[porsu]_[A-Za-z0-9]{36,}'),
  // AWS access key ID.
  RegExp(r'AKIA[0-9A-Z]{16}'),
  // JSON Web Token.
  RegExp(r'eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+'),
  // Slack.
  RegExp(r'xox[baprs]-[A-Za-z0-9\-]{10,}'),
];

/// Replaces secret-shaped substrings within [input].
///
/// Returns [input] unchanged when nothing matches.
String maskSecretsInString(String input) {
  var result = input;
  for (final pattern in _secretPatterns) {
    result = result.replaceAll(pattern, maskPlaceholder);
  }
  return result;
}

/// Returns true when [key] names a value that should be replaced wholesale.
///
/// Separators are normalised before matching so hyphenated, dotted, spaced, and
/// camelCase spellings all collapse to the same form: `api-key`, `x-api-key`,
/// `apiKey`, `api.key`, and `api key` all match the `api_key` fragment.
bool _isSensitiveKey(String key) {
  final normalised = key
      // camelCase / PascalCase -> snake_case before lowercasing.
      .replaceAllMapped(RegExp(r'([a-z0-9])([A-Z])'), (m) => '${m[1]}_${m[2]}')
      .toLowerCase()
      // Any run of separator characters collapses to a single underscore.
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_');
  // Match whole underscore-delimited segments, not raw substrings: `x-auth`
  // and `authToken` normalise to segments containing `auth` and match, while
  // `author` / `authors` do not. Multi-word fragments such as `api_key` are
  // matched as a contiguous run of segments.
  final segments = normalised.split('_').where((s) => s.isNotEmpty).toList();
  for (final fragment in _sensitiveKeyFragments) {
    final wanted = fragment.split('_').where((s) => s.isNotEmpty).toList();
    for (var i = 0; i + wanted.length <= segments.length; i++) {
      if (segments.sublist(i, i + wanted.length).join('_') ==
          wanted.join('_')) {
        return true;
      }
    }
  }
  return false;
}

/// Deep-copies [args], masking values by key name and by value pattern.
///
/// Never mutates [args]. Nested maps and lists are recursed into; non-string
/// scalars (numbers, booleans, null) are passed through unless their key is
/// sensitive.
Map<String, dynamic> maskSecrets(Map<String, dynamic> args) {
  return <String, dynamic>{
    for (final entry in args.entries)
      entry.key: _isSensitiveKey(entry.key)
          ? maskPlaceholder
          : _maskValue(entry.value),
  };
}

Object? _maskValue(Object? value) => switch (value) {
  String s => maskSecretsInString(s),
  Map<String, dynamic> m => maskSecrets(m),
  Map m => maskSecrets(Map<String, dynamic>.from(m)),
  List l => l.map(_maskValue).toList(),
  _ => value,
};
