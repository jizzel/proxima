import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/core/update_checker.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_update_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  UpdateChecker checker(
    String currentVersion, {
    String tag = 'v1.4.0',
    int statusCode = 200,
    String? rawBody,
  }) => UpdateChecker(
    currentVersion: currentVersion,
    homeDir: tempDir.path,
    client: MockClient(
      (request) async =>
          http.Response(rawBody ?? '{"tag_name":"$tag"}', statusCode),
    ),
  );

  Future<Map<String, dynamic>> readCache() async {
    final file = File(p.join(tempDir.path, '.proxima', 'update_check.json'));
    if (!await file.exists()) return {};
    return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  }

  group('isNewer', () {
    test('compares numerically, not as strings', () {
      // A string comparison would rank 1.9.0 above 1.10.0.
      expect(UpdateChecker.isNewer('1.10.0', '1.9.0'), isTrue);
      expect(UpdateChecker.isNewer('1.9.0', '1.10.0'), isFalse);
    });

    test('detects major, minor, and patch bumps', () {
      expect(UpdateChecker.isNewer('2.0.0', '1.9.9'), isTrue);
      expect(UpdateChecker.isNewer('1.4.0', '1.3.9'), isTrue);
      expect(UpdateChecker.isNewer('1.3.1', '1.3.0'), isTrue);
    });

    test('is false for equal or older versions', () {
      expect(UpdateChecker.isNewer('1.3.0', '1.3.0'), isFalse);
      expect(UpdateChecker.isNewer('1.2.0', '1.3.0'), isFalse);
    });

    test('ignores pre-release suffixes', () {
      expect(UpdateChecker.isNewer('1.4.0-rc.1', '1.3.0'), isTrue);
      expect(UpdateChecker.isNewer('1.3.0-rc.1', '1.3.0'), isFalse);
    });
  });

  group('check', () {
    test('reports an available update', () async {
      final info = await checker('1.3.0').check();
      expect(info, isNotNull);
      expect(info!.currentVersion, equals('1.3.0'));
      expect(info.latestVersion, equals('1.4.0'));
    });

    test('returns null when already current', () async {
      expect(await checker('1.4.0').check(), isNull);
    });

    test('never checks from a source build', () async {
      var called = false;
      final c = UpdateChecker(
        currentVersion: 'dev',
        homeDir: tempDir.path,
        client: MockClient((request) async {
          called = true;
          return http.Response('{"tag_name":"v9.9.9"}', 200);
        }),
      );
      expect(await c.check(), isNull);
      expect(called, isFalse, reason: 'no network call for a dev build');
    });

    test('returns null on a non-200 rather than throwing', () async {
      expect(await checker('1.3.0', statusCode: 403).check(), isNull);
    });

    test('returns null on a malformed body rather than throwing', () async {
      expect(await checker('1.3.0', rawBody: 'not json').check(), isNull);
    });

    test('strips the leading v from the tag', () async {
      final info = await checker('1.3.0', tag: 'v2.0.0').check();
      expect(info!.latestVersion, equals('2.0.0'));
    });

    test('handles a tag with no leading v', () async {
      final info = await checker('1.3.0', tag: '2.0.0').check();
      expect(info!.latestVersion, equals('2.0.0'));
    });
  });

  group('caching', () {
    test('writes the result to the cache', () async {
      await checker('1.3.0').check();
      final cache = await readCache();
      expect(cache['latest_version'], equals('1.4.0'));
      expect(cache['last_checked'], isNotNull);
    });

    test('serves a fresh cache without hitting the network', () async {
      await checker('1.3.0').check(); // populates cache

      var called = false;
      final second = UpdateChecker(
        currentVersion: '1.3.0',
        homeDir: tempDir.path,
        client: MockClient((request) async {
          called = true;
          return http.Response('{"tag_name":"v9.9.9"}', 200);
        }),
      );

      final info = await second.check();
      expect(called, isFalse, reason: 'cache is under 24h old');
      expect(info!.latestVersion, equals('1.4.0'));
    });

    test('re-checks once the cache is stale', () async {
      final file = File(p.join(tempDir.path, '.proxima', 'update_check.json'));
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'last_checked': DateTime.now()
              .subtract(const Duration(hours: 25))
              .toIso8601String(),
          'latest_version': '1.3.5',
        }),
      );

      final info = await checker('1.3.0').check();
      expect(info!.latestVersion, equals('1.4.0'), reason: 'refetched');
    });
  });

  group('skip', () {
    test('a skipped version is never announced again', () async {
      final c = checker('1.3.0');
      expect(await c.check(), isNotNull);

      await c.skipVersion('1.4.0');
      expect(await c.check(), isNull);
    });

    test('a newer version is still announced after skipping one', () async {
      await checker('1.3.0').skipVersion('1.4.0');
      final info = await checker('1.3.0', tag: 'v1.5.0').check();
      expect(info, isNotNull);
      expect(info!.latestVersion, equals('1.5.0'));
    });

    test(
      'remindLater clears the timestamp so the next start re-checks',
      () async {
        final c = checker('1.3.0');
        await c.check();
        expect((await readCache())['last_checked'], isNotNull);

        await c.remindLater();
        expect((await readCache())['last_checked'], isNull);
      },
    );
  });

  group('install command', () {
    test('names the platform installer', () {
      const info = UpdateInfo(currentVersion: '1.3.0', latestVersion: '1.4.0');
      expect(
        info.installCommand,
        Platform.isWindows ? contains('install.ps1') : contains('install.sh'),
      );
    });
  });
}
