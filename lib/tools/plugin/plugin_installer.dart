import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// One plugin as published in the official catalogue.
class CatalogEntry {
  final String name;
  final String displayName;
  final String description;
  final String version;
  final String riskLevel;
  final String author;
  final List<String> tags;
  final String downloadUrl;
  final String checksumSha256;

  const CatalogEntry({
    required this.name,
    required this.displayName,
    required this.description,
    required this.version,
    required this.riskLevel,
    required this.author,
    required this.tags,
    required this.downloadUrl,
    required this.checksumSha256,
  });

  static CatalogEntry? fromJson(Map<String, dynamic> json) {
    final name = json['name'] as String?;
    final downloadUrl = json['download_url'] as String?;
    final checksum = json['checksum_sha256'] as String?;
    // Without these three an entry cannot be installed, so drop it rather
    // than offering the user something that will fail.
    if (name == null || downloadUrl == null || checksum == null) return null;

    return CatalogEntry(
      name: name,
      displayName: json['display_name'] as String? ?? name,
      description: json['description'] as String? ?? '',
      version: json['version'] as String? ?? '0.0.0',
      riskLevel: json['risk_level'] as String? ?? 'confirm',
      author: json['author'] as String? ?? 'unknown',
      tags: (json['tags'] as List?)?.map((t) => '$t').toList() ?? const [],
      downloadUrl: downloadUrl,
      checksumSha256: checksum,
    );
  }
}

/// Raised when an install cannot proceed. Carries a message already phrased
/// for the user.
class PluginInstallError implements Exception {
  final String message;
  const PluginInstallError(this.message);
  @override
  String toString() => message;
}

/// Downloads, verifies, and installs official plugins.
///
/// Two properties are load-bearing:
///
/// **Nothing is written to disk before verification.** The archive is fetched
/// to a temp directory, its SHA-256 checked against the catalogue, and its
/// entries validated — only then is anything moved into place.
///
/// **The catalogue is never a hard dependency.** Every network path degrades:
/// `list` falls back to what is installed locally, `install` reports a clear
/// error, and the REPL keeps working.
class PluginInstaller {
  /// Published alongside every release. HTTPS only — no plain-HTTP fallback.
  static const catalogUrl =
      'https://github.com/jizzel/proxima/releases/latest/download/catalog.json';

  static const _fetchTimeout = Duration(seconds: 10);
  static const _downloadTimeout = Duration(seconds: 60);

  final http.Client _client;
  final String _installRoot;

  PluginInstaller({http.Client? client, String? installRoot})
    : _client = client ?? http.Client(),
      _installRoot = installRoot ?? _defaultInstallRoot();

  static String _defaultInstallRoot() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    return p.join(home, '.proxima', 'plugins');
  }

  /// Where plugins are installed.
  String get installRoot => _installRoot;

  /// Fetches the official catalogue.
  ///
  /// Returns null when it cannot be reached, so callers can fall back rather
  /// than fail — an offline user must still be able to list what they have.
  Future<List<CatalogEntry>?> fetchCatalog() async {
    try {
      final response = await _client
          .get(Uri.parse(catalogUrl))
          .timeout(_fetchTimeout);
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final plugins = json['plugins'] as List?;
      if (plugins == null) return null;

      return plugins
          .map((e) => CatalogEntry.fromJson(e as Map<String, dynamic>))
          .whereType<CatalogEntry>()
          .toList();
    } catch (_) {
      return null;
    }
  }

  /// Names of plugins present in the install root.
  Future<List<String>> listInstalled() async {
    try {
      final root = Directory(_installRoot);
      if (!await root.exists()) return [];
      final names = <String>[];
      await for (final entry in root.list(followLinks: false)) {
        if (entry is Directory) names.add(p.basename(entry.path));
      }
      names.sort();
      return names;
    } catch (_) {
      return [];
    }
  }

  /// Downloads, verifies, and installs [name] from the catalogue.
  ///
  /// Throws [PluginInstallError] with a user-facing message on any failure.
  Future<CatalogEntry> install(String name) async {
    final catalog = await fetchCatalog();
    if (catalog == null) {
      throw const PluginInstallError(
        'Could not reach plugin catalogue. '
        'Check your connection or install manually.',
      );
    }

    final entry = catalog.where((e) => e.name == name).firstOrNull;
    if (entry == null) {
      throw PluginInstallError(
        'Plugin "$name" is not in the catalogue. '
        'Run "proxima plugin list" to see what is available.',
      );
    }

    final bytes = await _download(entry);
    _verifyChecksum(entry, bytes);

    final archive = _decode(bytes);
    final files = _validateEntries(archive, name);

    await _extract(files, name);
    return entry;
  }

  /// Deletes an installed plugin. Returns false when it was not installed.
  ///
  /// Only ever touches the install root — a plugin placed manually under a
  /// project's `.proxima/plugins/` is never removed.
  Future<bool> remove(String name) async {
    final dir = Directory(_pluginDir(name));
    if (!await dir.exists()) return false;
    await dir.delete(recursive: true);
    return true;
  }

  /// Resolves a plugin's directory, refusing anything that is not a single
  /// safe path component.
  ///
  /// Without this, `plugin remove ../../Documents` resolved outside the
  /// install root and `delete(recursive: true)` would take an arbitrary
  /// directory with it.
  String _pluginDir(String name) {
    final normalized = name.replaceAll(r'\', '/');
    if (normalized.isEmpty ||
        normalized.contains('/') ||
        normalized == '.' ||
        normalized == '..') {
      throw PluginInstallError(
        'Invalid plugin name "$name": expected a single name, not a path.',
      );
    }

    final resolved = p.normalize(p.join(_installRoot, normalized));
    if (!p.isWithin(_installRoot, resolved)) {
      throw PluginInstallError(
        'Invalid plugin name "$name": resolves outside the plugin directory.',
      );
    }
    return resolved;
  }

  Future<List<int>> _download(CatalogEntry entry) async {
    final uri = Uri.parse(entry.downloadUrl);
    if (uri.scheme != 'https') {
      throw PluginInstallError(
        'Refusing to download "${entry.name}" over ${uri.scheme}. '
        'Plugin downloads must use HTTPS.',
      );
    }
    try {
      final response = await _client.get(uri).timeout(_downloadTimeout);
      if (response.statusCode != 200) {
        throw PluginInstallError(
          'Download failed for "${entry.name}" '
          '(HTTP ${response.statusCode}).',
        );
      }
      return response.bodyBytes;
    } on PluginInstallError {
      rethrow;
    } catch (e) {
      throw PluginInstallError('Download failed for "${entry.name}": $e');
    }
  }

  void _verifyChecksum(CatalogEntry entry, List<int> bytes) {
    final actual = sha256.convert(bytes).toString();
    if (actual.toLowerCase() != entry.checksumSha256.toLowerCase()) {
      // Nothing has touched disk at this point, so there is nothing to undo.
      throw PluginInstallError(
        'Checksum mismatch for "${entry.name}" — refusing to install. '
        'Expected ${entry.checksumSha256}, got $actual.',
      );
    }
  }

  Archive _decode(List<int> bytes) {
    try {
      return ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw PluginInstallError('Downloaded archive is not a valid zip: $e');
    }
  }

  /// Rejects any archive entry that would escape the plugin directory.
  ///
  /// A checksum proves the archive matches the catalogue, not that its contents
  /// are safe — a compromised or malicious plugin could carry `../` entries and
  /// write anywhere the user can. SPECS §21.1 does not mention this; it is
  /// guarded regardless.
  List<ArchiveFile> _validateEntries(Archive archive, String name) {
    final target = _pluginDir(name);
    final files = <ArchiveFile>[];

    for (final file in archive) {
      if (!file.isFile) continue;

      // Validate the *same* string that extraction will use. Checking the raw
      // entry name let `..\..\escape.sh` through on POSIX — `path` treats a
      // backslash as an ordinary character, so the check passed, and the later
      // separator conversion then wrote outside the directory.
      final relative = _relativePathFor(file.name, name);
      if (relative.isEmpty) continue;

      final resolved = p.normalize(p.join(target, relative));
      if (!p.isWithin(target, resolved)) {
        throw PluginInstallError(
          'Refusing to install "$name": the archive contains an entry that '
          'would write outside the plugin directory ("${file.name}").',
        );
      }
      files.add(file);
    }

    if (files.isEmpty) {
      throw PluginInstallError('Archive for "$name" contains no files.');
    }
    return files;
  }

  Future<void> _extract(List<ArchiveFile> files, String name) async {
    final target = Directory(_pluginDir(name));
    final stamp = DateTime.now().microsecondsSinceEpoch;

    // Stage in a sibling directory, then swap — a failure part-way through
    // must not leave a half-installed plugin behind.
    final staging = Directory(p.join(_installRoot, '.staging-$name-$stamp'));
    // An update moves the existing install aside rather than deleting it, so a
    // failed rename can put it back. Deleting first meant a transient failure
    // (permissions, a Windows file lock) uninstalled a working plugin.
    final backup = Directory(p.join(_installRoot, '.backup-$name-$stamp'));
    var backedUp = false;

    try {
      await staging.create(recursive: true);

      for (final file in files) {
        final relative = _relativePathFor(file.name, name);
        if (relative.isEmpty) continue;

        final out = File(p.join(staging.path, relative));
        await out.parent.create(recursive: true);
        await out.writeAsBytes(file.content as List<int>);
      }

      await _restoreExecutableBits(staging, files, name);

      if (await target.exists()) {
        await target.rename(backup.path);
        backedUp = true;
      }
      await staging.rename(target.path);

      // Only now is the previous version unreachable.
      if (backedUp) {
        await backup.delete(recursive: true).catchError((_) => backup);
      }
    } catch (e) {
      if (await staging.exists()) {
        await staging.delete(recursive: true).catchError((_) => staging);
      }
      // Put the working plugin back before reporting the failure.
      if (backedUp && !await target.exists()) {
        await backup.rename(target.path).catchError((_) => backup);
      } else if (backedUp) {
        await backup.delete(recursive: true).catchError((_) => backup);
      }
      if (e is PluginInstallError) rethrow;
      throw PluginInstallError('Could not install "$name": $e');
    }
  }

  /// Restores the execute bit on the plugin's entry point.
  ///
  /// `writeAsBytes` cannot carry POSIX permissions, and `plugin.json` allows
  /// any executable name — matching only `*.sh` left an extensionless or
  /// differently-named entry point unrunnable, so `PluginLoader` would skip
  /// the plugin it had just installed.
  Future<void> _restoreExecutableBits(
    Directory staging,
    List<ArchiveFile> files,
    String name,
  ) async {
    if (Platform.isWindows) return;

    final executables = <String>{};

    // The descriptor names the entry point; that is the authoritative one.
    // It is attacker-controlled, so it gets the same containment check as an
    // archive entry — a declared `../../victim.sh` would otherwise chmod +x a
    // file outside the plugin, and PluginLoader would then follow that same
    // escaped path and register it under the descriptor's name and risk level.
    // Rejected rather than skipped: the plugin cannot work, and installing it
    // anyway leaves that escaped path for the loader to follow.
    String? declared;
    try {
      final descriptor = File(p.join(staging.path, 'plugin.json'));
      if (await descriptor.exists()) {
        final json =
            jsonDecode(await descriptor.readAsString()) as Map<String, dynamic>;
        declared = json['executable'] as String?;
      }
    } catch (_) {
      // A malformed descriptor is PluginLoader's problem to report, not ours.
    }

    if (declared != null && declared.isNotEmpty) {
      final relative = declared.replaceAll(r'\', '/');
      final resolved = p.normalize(p.join(staging.path, relative));
      if (!p.isWithin(staging.path, resolved)) {
        throw PluginInstallError(
          'Refusing to install "$name": plugin.json declares an executable '
          'outside the plugin directory ("$declared").',
        );
      }
      executables.add(relative);
    }

    // Script extensions as a fallback for helper scripts the descriptor does
    // not name.
    for (final file in files) {
      final relative = _relativePathFor(file.name, name);
      if (const [
        '.sh',
        '.bash',
        '.zsh',
        '.py',
        '.pl',
        '.rb',
      ].any(relative.endsWith)) {
        executables.add(relative);
      }
    }

    for (final relative in executables) {
      // Single choke point: no path reaches chmod without a containment check,
      // whatever added it.
      final path = p.normalize(p.join(staging.path, relative));
      if (!p.isWithin(staging.path, path)) continue;
      if (await File(path).exists()) {
        await Process.run('chmod', ['+x', path]);
      }
    }
  }

  /// The path an archive entry will be written to, relative to the plugin
  /// directory: separators normalised, and a wrapping `<name>/` removed.
  ///
  /// Both validation and extraction go through this, so the string that is
  /// checked is always the string that is written.
  static String _relativePathFor(String path, String name) {
    final normalized = path.replaceAll(r'\', '/');
    final prefix = '$name/';
    return normalized.startsWith(prefix)
        ? normalized.substring(prefix.length)
        : normalized;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
