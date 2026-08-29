import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// Result of a version check.
class UpdateInfo {
  final String currentVersion;
  final String latestVersion;

  const UpdateInfo({required this.currentVersion, required this.latestVersion});

  /// The one-line command that installs the latest release.
  String get installCommand => Platform.isWindows
      ? 'irm https://raw.githubusercontent.com/jizzel/proxima/main/install.ps1 | iex'
      : 'curl -fsSL https://raw.githubusercontent.com/jizzel/proxima/main/install.sh | sh';
}

/// Checks GitHub for a newer release.
///
/// Deliberately *never* installs anything. Proxima has filesystem and shell
/// access, so silently replacing its own binary would make a compromised
/// release channel equivalent to remote code execution. The user is shown the
/// install command and runs it themselves — which also sidesteps needing sudo
/// for `/usr/local/bin` and the problem of overwriting a running executable.
class UpdateChecker {
  static const _releasesUrl =
      'https://api.github.com/repos/jizzel/proxima/releases/latest';

  /// How long a check result stays fresh.
  static const cacheDuration = Duration(hours: 24);

  final String _currentVersion;
  final String _cachePath;
  final http.Client _client;

  UpdateChecker({
    required String currentVersion,
    required String homeDir,
    http.Client? client,
  }) : _currentVersion = currentVersion,
       _cachePath = p.join(homeDir, '.proxima', 'update_check.json'),
       _client = client ?? http.Client();

  /// Returns update details when a newer release exists and the user has not
  /// skipped it, else null.
  ///
  /// Never throws and never blocks meaningfully: any failure — no network,
  /// rate limiting, malformed JSON, unwritable cache — yields null.
  Future<UpdateInfo?> check() async {
    // A source build has no comparable version.
    if (_currentVersion == 'dev' || _currentVersion.isEmpty) return null;

    try {
      final cache = await _readCache();

      final skipped = cache['skipped_version'] as String?;
      final lastChecked = cache['last_checked'] as String?;
      final cachedLatest = cache['latest_version'] as String?;

      String? latest;
      final checkedAt = lastChecked == null
          ? null
          : DateTime.tryParse(lastChecked);
      final isFresh =
          checkedAt != null &&
          DateTime.now().difference(checkedAt) < cacheDuration;

      if (isFresh && cachedLatest != null) {
        latest = cachedLatest;
      } else {
        latest = await _fetchLatest();
        if (latest == null) return null;
        await _writeCache({
          ...cache,
          'last_checked': DateTime.now().toIso8601String(),
          'latest_version': latest,
        });
      }

      if (latest == skipped) return null;
      if (!isNewer(latest, _currentVersion)) return null;

      return UpdateInfo(currentVersion: _currentVersion, latestVersion: latest);
    } catch (_) {
      return null;
    }
  }

  /// Records [version] as skipped so it is never announced again.
  Future<void> skipVersion(String version) async {
    try {
      final cache = await _readCache();
      await _writeCache({...cache, 'skipped_version': version});
    } catch (_) {
      // A cache we cannot write is not worth failing a session over.
    }
  }

  /// Clears the cached timestamp so the next start re-checks.
  Future<void> remindLater() async {
    try {
      final cache = await _readCache()
        ..remove('last_checked');
      await _writeCache(cache);
    } catch (_) {
      // Non-fatal.
    }
  }

  Future<String?> _fetchLatest() async {
    final response = await _client
        .get(
          Uri.parse(_releasesUrl),
          headers: {'Accept': 'application/vnd.github+json'},
        )
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) return null;

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = json['tag_name'] as String?;
    if (tag == null || tag.isEmpty) return null;
    return tag.startsWith('v') ? tag.substring(1) : tag;
  }

  Future<Map<String, dynamic>> _readCache() async {
    final file = File(_cachePath);
    if (!await file.exists()) return {};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  Future<void> _writeCache(Map<String, dynamic> data) async {
    final file = File(_cachePath);
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(data));
  }

  /// Semantic-version comparison, ignoring any pre-release suffix.
  ///
  /// Compares numerically so `1.10.0` correctly beats `1.9.0`, which a string
  /// comparison would get wrong.
  static bool isNewer(String candidate, String current) {
    List<int> parse(String v) => v
        .split('-')
        .first
        .split('.')
        .map((part) => int.tryParse(part) ?? 0)
        .toList();

    final a = parse(candidate);
    final b = parse(current);
    for (var i = 0; i < 3; i++) {
      final left = i < a.length ? a[i] : 0;
      final right = i < b.length ? b[i] : 0;
      if (left != right) return left > right;
    }
    return false;
  }
}
