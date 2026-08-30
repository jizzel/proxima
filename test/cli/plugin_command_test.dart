import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/cli/plugin_command.dart';
import 'package:proxima/tools/plugin/plugin_installer.dart';

void main() {
  late Directory tempDir;
  late List<String> output;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_plugincli_');
    output = [];
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  void capture(String line) => output.add(line);
  String printed() => output.join('\n');

  List<int> zipOf(Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    return ZipEncoder().encode(archive);
  }

  /// An installer backed by an in-memory catalogue.
  PluginInstaller installer({
    List<String> names = const ['word-count'],
    bool offline = false,
  }) {
    final zip = zipOf({'plugin.json': '{}'});
    final catalog = jsonEncode({
      'version': '1',
      'plugins': [
        for (final name in names)
          {
            'name': name,
            'display_name': name,
            'description': 'the $name plugin',
            'version': '1.0.0',
            'risk_level': 'safe',
            'author': 'test',
            'tags': <String>[],
            'download_url': 'https://example.com/$name.zip',
            'checksum_sha256': sha256.convert(zip).toString(),
          },
      ],
    });

    return PluginInstaller(
      installRoot: tempDir.path,
      client: MockClient((request) async {
        if (request.url.path.endsWith('catalog.json')) {
          if (offline) throw http.ClientException('offline', request.url);
          return http.Response(catalog, 200);
        }
        return http.Response.bytes(zip, 200);
      }),
    );
  }

  group('usage', () {
    test('no subcommand prints usage and fails', () async {
      final code = await runPluginCommand(
        [],
        installer: installer(),
        out: capture,
      );
      expect(code, equals(1));
      expect(printed(), contains('Usage: proxima plugin'));
    });

    test('help succeeds', () async {
      final code = await runPluginCommand(
        ['help'],
        installer: installer(),
        out: capture,
      );
      expect(code, equals(0));
      expect(printed(), contains('install <name>'));
    });

    test('an unknown subcommand fails with usage', () async {
      final code = await runPluginCommand(
        ['frobnicate'],
        installer: installer(),
        out: capture,
      );
      expect(code, equals(1));
      expect(printed(), contains('Unknown plugin command'));
    });
  });

  group('list', () {
    test('shows catalogue entries', () async {
      await runPluginCommand(
        ['list'],
        installer: installer(names: ['word-count', 'git-summary']),
        out: capture,
      );
      expect(printed(), contains('word-count'));
      expect(printed(), contains('git-summary'));
    });

    test('marks installed entries', () async {
      await Directory(p.join(tempDir.path, 'word-count')).create();
      await runPluginCommand(['list'], installer: installer(), out: capture);
      expect(printed(), contains('✓'));
    });

    test('--installed skips the catalogue entirely', () async {
      await Directory(p.join(tempDir.path, 'local-only')).create();
      final code = await runPluginCommand(
        ['list', '--installed'],
        installer: installer(offline: true),
        out: capture,
      );
      expect(code, equals(0));
      expect(printed(), contains('local-only'));
    });

    test('offline falls back to installed with a note', () async {
      // Per SPECS §21.1: the catalogue is never a hard dependency.
      await Directory(p.join(tempDir.path, 'already-here')).create();
      final code = await runPluginCommand(
        ['list'],
        installer: installer(offline: true),
        out: capture,
      );
      expect(code, equals(0), reason: 'offline is not an error for list');
      expect(printed(), contains('already-here'));
      expect(printed(), contains('catalogue unavailable'));
    });
  });

  group('install', () {
    test('installs from the catalogue', () async {
      final code = await runPluginCommand(
        ['install', 'word-count'],
        installer: installer(),
        out: capture,
      );
      expect(code, equals(0));
      expect(
        await File(p.join(tempDir.path, 'word-count', 'plugin.json')).exists(),
        isTrue,
      );
    });

    test('requires a name', () async {
      final code = await runPluginCommand(
        ['install'],
        installer: installer(),
        out: capture,
      );
      expect(code, equals(1));
      expect(printed(), contains('Usage'));
    });

    test('prints the specified error when offline', () async {
      final code = await runPluginCommand(
        ['install', 'word-count'],
        installer: installer(offline: true),
        out: capture,
      );
      expect(code, equals(1));
      expect(printed(), contains('Could not reach plugin catalogue'));
    });
  });

  group('remove', () {
    test('removes an installed plugin', () async {
      await Directory(p.join(tempDir.path, 'gone')).create();
      final code = await runPluginCommand(
        ['remove', 'gone'],
        installer: installer(),
        out: capture,
      );
      expect(code, equals(0));
      expect(await Directory(p.join(tempDir.path, 'gone')).exists(), isFalse);
    });

    test('reports a plugin that is not installed', () async {
      final code = await runPluginCommand(
        ['remove', 'never'],
        installer: installer(),
        out: capture,
      );
      expect(code, equals(1));
      expect(printed(), contains('not installed'));
    });
  });

  group('update', () {
    test('reinstalls each installed plugin', () async {
      await Directory(p.join(tempDir.path, 'word-count')).create();
      final code = await runPluginCommand(
        ['update'],
        installer: installer(),
        out: capture,
      );
      expect(code, equals(0));
      expect(printed(), contains('Updated word-count'));
    });

    test('succeeds trivially when nothing is installed', () async {
      final code = await runPluginCommand(
        ['update'],
        installer: installer(),
        out: capture,
      );
      expect(code, equals(0));
      expect(printed(), contains('No plugins installed'));
    });

    test('one failure does not abandon the rest', () async {
      await Directory(p.join(tempDir.path, 'word-count')).create();
      await Directory(p.join(tempDir.path, 'not-in-catalogue')).create();

      final code = await runPluginCommand(
        ['update'],
        installer: installer(),
        out: capture,
      );
      expect(code, equals(1), reason: 'reports the failure');
      expect(printed(), contains('Updated word-count'));
      expect(printed(), contains('not-in-catalogue'));
    });
  });
}
