import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/plugin/plugin_installer.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_installer_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  /// Builds a zip whose entries are exactly [files] (path -> contents).
  List<int> zipOf(Map<String, String> files) {
    final archive = Archive();
    for (final entry in files.entries) {
      final bytes = utf8.encode(entry.value);
      archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
    }
    return ZipEncoder().encode(archive);
  }

  String catalogJson(String name, List<int> zipBytes, {String? checksum}) =>
      jsonEncode({
        'version': '1',
        'plugins': [
          {
            'name': name,
            'display_name': name,
            'description': 'test plugin',
            'version': '1.0.0',
            'risk_level': 'safe',
            'author': 'test',
            'tags': <String>[],
            'download_url': 'https://example.com/$name.zip',
            'checksum_sha256': checksum ?? sha256.convert(zipBytes).toString(),
          },
        ],
      });

  /// An installer whose catalogue and download both come from memory.
  PluginInstaller installer({
    required String catalog,
    List<int>? zipBytes,
    int catalogStatus = 200,
    int downloadStatus = 200,
    bool catalogThrows = false,
  }) => PluginInstaller(
    installRoot: tempDir.path,
    client: MockClient((request) async {
      if (request.url.path.endsWith('catalog.json')) {
        if (catalogThrows) throw http.ClientException('offline', request.url);
        return http.Response(catalog, catalogStatus);
      }
      return http.Response.bytes(zipBytes ?? [], downloadStatus);
    }),
  );

  group('catalogue', () {
    test('parses entries', () async {
      final zip = zipOf({'plugin.json': '{}'});
      final catalog = await installer(
        catalog: catalogJson('word-count', zip),
        zipBytes: zip,
      ).fetchCatalog();

      expect(catalog, isNotNull);
      expect(catalog!.single.name, equals('word-count'));
      expect(catalog.single.version, equals('1.0.0'));
    });

    test('returns null when offline rather than throwing', () async {
      // The catalogue is never a hard dependency — the REPL must keep working.
      final catalog = await installer(
        catalog: '',
        catalogThrows: true,
      ).fetchCatalog();
      expect(catalog, isNull);
    });

    test('returns null on a non-200', () async {
      expect(
        await installer(catalog: '{}', catalogStatus: 404).fetchCatalog(),
        isNull,
      );
    });

    test('returns null on a malformed body', () async {
      expect(await installer(catalog: 'not json').fetchCatalog(), isNull);
    });

    test('drops entries that could never be installed', () async {
      // No download_url or checksum — offering these would guarantee a failure.
      final catalog = await installer(
        catalog: jsonEncode({
          'plugins': [
            {'name': 'incomplete'},
            {
              'name': 'ok',
              'download_url': 'https://example.com/ok.zip',
              'checksum_sha256': 'abc',
            },
          ],
        }),
      ).fetchCatalog();

      expect(catalog!.map((e) => e.name), equals(['ok']));
    });
  });

  group('install', () {
    test('extracts a verified plugin', () async {
      final zip = zipOf({
        'plugin.json': '{"name":"word-count"}',
        'run.sh': '#!/bin/sh\necho hi',
      });

      await installer(
        catalog: catalogJson('word-count', zip),
        zipBytes: zip,
      ).install('word-count');

      final root = p.join(tempDir.path, 'word-count');
      expect(await File(p.join(root, 'plugin.json')).exists(), isTrue);
      expect(await File(p.join(root, 'run.sh')).exists(), isTrue);
    });

    test('strips a wrapping top-level directory', () async {
      final zip = zipOf({
        'word-count/plugin.json': '{}',
        'word-count/run.sh': 'x',
      });

      await installer(
        catalog: catalogJson('word-count', zip),
        zipBytes: zip,
      ).install('word-count');

      expect(
        await File(p.join(tempDir.path, 'word-count', 'plugin.json')).exists(),
        isTrue,
      );
    });

    test('refuses a checksum mismatch and writes nothing', () async {
      final zip = zipOf({'plugin.json': '{}'});

      await expectLater(
        installer(
          catalog: catalogJson('word-count', zip, checksum: 'deadbeef'),
          zipBytes: zip,
        ).install('word-count'),
        throwsA(isA<PluginInstallError>()),
      );

      expect(
        await Directory(p.join(tempDir.path, 'word-count')).exists(),
        isFalse,
        reason: 'nothing may reach disk before verification',
      );
    });

    test('reports a clear error when the catalogue is unreachable', () async {
      await expectLater(
        installer(catalog: '', catalogThrows: true).install('word-count'),
        throwsA(
          isA<PluginInstallError>().having(
            (e) => e.message,
            'message',
            contains('Could not reach plugin catalogue'),
          ),
        ),
      );
    });

    test('reports an unknown plugin name', () async {
      final zip = zipOf({'plugin.json': '{}'});
      await expectLater(
        installer(
          catalog: catalogJson('word-count', zip),
          zipBytes: zip,
        ).install('no-such-plugin'),
        throwsA(
          isA<PluginInstallError>().having(
            (e) => e.message,
            'message',
            contains('not in the catalogue'),
          ),
        ),
      );
    });

    test('rejects a non-HTTPS download url', () async {
      final zip = zipOf({'plugin.json': '{}'});
      final catalog = jsonEncode({
        'plugins': [
          {
            'name': 'evil',
            'download_url': 'http://example.com/evil.zip',
            'checksum_sha256': sha256.convert(zip).toString(),
          },
        ],
      });

      await expectLater(
        installer(catalog: catalog, zipBytes: zip).install('evil'),
        throwsA(
          isA<PluginInstallError>().having(
            (e) => e.message,
            'message',
            contains('HTTPS'),
          ),
        ),
      );
    });

    test('reports a failed download', () async {
      final zip = zipOf({'plugin.json': '{}'});
      await expectLater(
        installer(
          catalog: catalogJson('word-count', zip),
          zipBytes: zip,
          downloadStatus: 404,
        ).install('word-count'),
        throwsA(isA<PluginInstallError>()),
      );
    });

    test('rejects an archive that is not a zip', () async {
      final notAZip = utf8.encode('this is not a zip file at all');
      await expectLater(
        installer(
          catalog: catalogJson('word-count', notAZip),
          zipBytes: notAZip,
        ).install('word-count'),
        throwsA(isA<PluginInstallError>()),
      );
    });

    test('rejects an empty archive', () async {
      final zip = zipOf({});
      await expectLater(
        installer(
          catalog: catalogJson('empty', zip),
          zipBytes: zip,
        ).install('empty'),
        throwsA(isA<PluginInstallError>()),
      );
    });

    test('replaces an existing installation', () async {
      final first = zipOf({'plugin.json': '{"v":1}'});
      await installer(
        catalog: catalogJson('word-count', first),
        zipBytes: first,
      ).install('word-count');

      final second = zipOf({'plugin.json': '{"v":2}'});
      await installer(
        catalog: catalogJson('word-count', second),
        zipBytes: second,
      ).install('word-count');

      final content = await File(
        p.join(tempDir.path, 'word-count', 'plugin.json'),
      ).readAsString();
      expect(content, contains('"v":2'));
    });
  });

  group('zip-slip', () {
    // A checksum proves the archive matches the catalogue, not that its
    // contents are safe. SPECS §21.1 omits this; it is guarded regardless.
    test('rejects a parent-directory traversal entry', () async {
      final zip = zipOf({'plugin.json': '{}', '../../../evil.sh': 'malicious'});

      await expectLater(
        installer(
          catalog: catalogJson('evil', zip),
          zipBytes: zip,
        ).install('evil'),
        throwsA(
          isA<PluginInstallError>().having(
            (e) => e.message,
            'message',
            contains('outside the plugin directory'),
          ),
        ),
      );
    });

    test('writes nothing at all when an entry escapes', () async {
      final zip = zipOf({'plugin.json': '{}', '../escaped.txt': 'x'});

      try {
        await installer(
          catalog: catalogJson('evil', zip),
          zipBytes: zip,
        ).install('evil');
      } on PluginInstallError {
        // expected
      }

      expect(await Directory(p.join(tempDir.path, 'evil')).exists(), isFalse);
      expect(
        await File(p.join(tempDir.path, 'escaped.txt')).exists(),
        isFalse,
        reason: 'the traversal target must not exist',
      );
    });

    test('allows legitimate nested paths', () async {
      final zip = zipOf({'plugin.json': '{}', 'lib/helper.sh': 'x'});

      await installer(
        catalog: catalogJson('nested', zip),
        zipBytes: zip,
      ).install('nested');

      expect(
        await File(p.join(tempDir.path, 'nested', 'lib', 'helper.sh')).exists(),
        isTrue,
      );
    });
  });

  group('list and remove', () {
    test('lists installed plugin directories', () async {
      await Directory(p.join(tempDir.path, 'a')).create(recursive: true);
      await Directory(p.join(tempDir.path, 'b')).create(recursive: true);

      final installed = await PluginInstaller(
        installRoot: tempDir.path,
      ).listInstalled();
      expect(installed, equals(['a', 'b']));
    });

    test('returns empty when the install root does not exist', () async {
      final installed = await PluginInstaller(
        installRoot: p.join(tempDir.path, 'nope'),
      ).listInstalled();
      expect(installed, isEmpty);
    });

    test('removes an installed plugin', () async {
      final dir = Directory(p.join(tempDir.path, 'gone'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, 'plugin.json')).writeAsString('{}');

      final removed = await PluginInstaller(
        installRoot: tempDir.path,
      ).remove('gone');

      expect(removed, isTrue);
      expect(await dir.exists(), isFalse);
    });

    test('reports false for a plugin that is not installed', () async {
      final removed = await PluginInstaller(
        installRoot: tempDir.path,
      ).remove('never-installed');
      expect(removed, isFalse);
    });
  });
  group('path traversal', () {
    test('remove refuses anything that is not a single name', () async {
      // Regression: `plugin remove ../../Documents` resolved outside the
      // install root, and delete(recursive: true) took it with it.
      final victim = Directory(p.join(tempDir.path, '..', 'victim_dir'));
      await victim.create();
      addTearDown(() async {
        if (await victim.exists()) await victim.delete(recursive: true);
      });

      final inst = PluginInstaller(installRoot: tempDir.path);
      for (final bad in [
        '../victim_dir',
        '../../etc',
        'nested/name',
        r'..\victim_dir',
        '..',
        '.',
        '',
      ]) {
        await expectLater(
          inst.remove(bad),
          throwsA(isA<PluginInstallError>()),
          reason: bad,
        );
      }

      expect(await victim.exists(), isTrue, reason: 'nothing was deleted');
    });

    test('rejects backslash traversal in archive entries', () async {
      // Regression: `path` treats a backslash as an ordinary character on
      // POSIX, so the containment check passed — then _stripLeadingDir
      // converted the separators and the write landed outside the directory.
      // Validation and extraction now share one normalised path.
      for (final entry in [
        r'..\..\escape.sh',
        r'..\escape.sh',
        '../../escape.sh',
      ]) {
        final zip = zipOf({'plugin.json': '{}', entry: 'pwned'});
        await expectLater(
          installer(
            catalog: catalogJson('evil', zip),
            zipBytes: zip,
          ).install('evil'),
          throwsA(isA<PluginInstallError>()),
          reason: entry,
        );
      }
    });
  });

  group('descriptor-declared executable', () {
    test(
      'rejects an executable outside the plugin directory',
      () async {
        // Regression: containment was applied to archive entries but not to the
        // path read *from* plugin.json, so a declared `../../victim.sh` chmod'ed
        // a file outside the plugin — and PluginLoader would then follow that
        // same escaped path and register it under the descriptor's name.
        for (final bad in [
          '../../victim.sh',
          r'..\..\victim.sh',
          '../victim.sh',
        ]) {
          final zip = zipOf({
            'plugin.json': jsonEncode({
              'name': 'evil',
              'description': 'd',
              'executable': bad,
              'input_schema': {'type': 'object'},
            }),
          });

          await expectLater(
            installer(
              catalog: catalogJson('evil', zip),
              zipBytes: zip,
            ).install('evil'),
            throwsA(isA<PluginInstallError>()),
            reason: bad,
          );
        }
      },
      skip: Platform.isWindows ? 'POSIX permissions only' : null,
    );

    test(
      'rejecting leaves nothing installed',
      () async {
        final zip = zipOf({
          'plugin.json': jsonEncode({
            'name': 'evil',
            'description': 'd',
            'executable': '../../escape.sh',
            'input_schema': {'type': 'object'},
          }),
        });

        try {
          await installer(
            catalog: catalogJson('evil', zip),
            zipBytes: zip,
          ).install('evil');
        } on PluginInstallError {
          // expected
        }

        expect(await Directory(p.join(tempDir.path, 'evil')).exists(), isFalse);
      },
      skip: Platform.isWindows ? 'POSIX permissions only' : null,
    );

    test('a contained executable still installs', () async {
      final zip = zipOf({
        'plugin.json': jsonEncode({
          'name': 'ok',
          'description': 'd',
          'executable': 'bin/runner',
          'input_schema': {'type': 'object'},
        }),
        'bin/runner': '#!/bin/sh',
      });

      await installer(
        catalog: catalogJson('good', zip),
        zipBytes: zip,
      ).install('good');

      final runner = File(p.join(tempDir.path, 'good', 'bin', 'runner'));
      expect(await runner.exists(), isTrue);
      if (!Platform.isWindows) {
        expect(runner.statSync().mode & 0x40, isNonZero);
      }
    });
  });

  group('failure-safe update', () {
    test('a failed update leaves the previous version installed', () async {
      // Regression: the existing plugin was deleted before the staged rename,
      // so a transient failure uninstalled a working plugin outright.
      final v1 = zipOf({'plugin.json': '{"v":1}'});
      await installer(
        catalog: catalogJson('wc', v1),
        zipBytes: v1,
      ).install('wc');

      final marker = File(p.join(tempDir.path, 'wc', 'plugin.json'));
      expect(await marker.readAsString(), contains('"v":1'));

      // Checksum matches v1 but the served bytes are garbage.
      final broken = PluginInstaller(
        installRoot: tempDir.path,
        client: MockClient((request) async {
          if (request.url.path.endsWith('catalog.json')) {
            return http.Response(catalogJson('wc', v1), 200);
          }
          return http.Response.bytes(utf8.encode('not a zip'), 200);
        }),
      );

      await expectLater(
        broken.install('wc'),
        throwsA(isA<PluginInstallError>()),
      );

      expect(await marker.exists(), isTrue, reason: 'v1 must survive');
      expect(await marker.readAsString(), contains('"v":1'));
    });

    test('a successful update leaves no staging or backup residue', () async {
      final v1 = zipOf({'plugin.json': '{"v":1}'});
      await installer(
        catalog: catalogJson('wc', v1),
        zipBytes: v1,
      ).install('wc');

      final v2 = zipOf({'plugin.json': '{"v":2}'});
      await installer(
        catalog: catalogJson('wc', v2),
        zipBytes: v2,
      ).install('wc');

      final residue = tempDir
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.startsWith('.staging') || n.startsWith('.backup'));
      expect(residue, isEmpty);
    });
  });

  group('executable permissions', () {
    test(
      'restores the descriptor-declared executable',
      () async {
        // Regression: only *.sh was chmod'ed, but plugin.json permits any
        // executable name — an extensionless entry point was left unrunnable
        // and PluginLoader would silently skip the plugin just installed.
        final zip = zipOf({
          'plugin.json':
              '{"name":"x","description":"d","executable":"runner",'
              '"input_schema":{"type":"object"}}',
          'runner': '#!/bin/sh\necho hi',
        });

        await installer(
          catalog: catalogJson('noext', zip),
          zipBytes: zip,
        ).install('noext');

        final runner = File(p.join(tempDir.path, 'noext', 'runner'));
        expect(await runner.exists(), isTrue);
        if (!Platform.isWindows) {
          expect(runner.statSync().mode & 0x40, isNonZero);
        }
      },
      skip: Platform.isWindows ? 'POSIX permissions only' : null,
    );

    test(
      'also restores helper scripts by extension',
      () async {
        final zip = zipOf({
          'plugin.json':
              '{"name":"x","description":"d","executable":"run.sh",'
              '"input_schema":{"type":"object"}}',
          'run.sh': '#!/bin/sh',
          'helper.py': 'print(1)',
        });

        await installer(
          catalog: catalogJson('scripts', zip),
          zipBytes: zip,
        ).install('scripts');

        if (!Platform.isWindows) {
          final helper = File(p.join(tempDir.path, 'scripts', 'helper.py'));
          expect(helper.statSync().mode & 0x40, isNonZero);
        }
      },
      skip: Platform.isWindows ? 'POSIX permissions only' : null,
    );
  });
}
