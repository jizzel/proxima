import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/tools/shell/run_tests_tool.dart';

void main() {
  late Directory tempDir;
  late RunTestsTool tool;

  /// Creates a marker file that makes the temp dir look like a given project.
  Future<void> marker(String name, [String content = '']) =>
      File(p.join(tempDir.path, name)).writeAsString(content);

  /// The command the tool *would* run — dryRun is the seam that exercises
  /// detection and quoting without spawning anything.
  Future<String> preview([Map<String, dynamic> args = const {}]) async =>
      (await tool.dryRun(args, tempDir.path)).preview;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_runtests_');
    tool = RunTestsTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('framework detection', () {
    test('detects Dart from pubspec.yaml', () async {
      await marker('pubspec.yaml');
      expect(await preview(), contains('dart test'));
    });

    test('detects Node from package.json', () async {
      await marker('package.json');
      expect(await preview(), contains('npm test'));
    });

    test('detects Rust from Cargo.toml', () async {
      await marker('Cargo.toml');
      expect(await preview(), contains('cargo test'));
    });

    test('detects Go from go.mod', () async {
      await marker('go.mod');
      expect(await preview(), contains('go test'));
    });

    test('detects Python from any of three markers', () async {
      for (final file in ['requirements.txt', 'setup.py', 'pyproject.toml']) {
        final dir = await Directory.systemTemp.createTemp('proxima_py_');
        await File(p.join(dir.path, file)).writeAsString('');
        final result = await tool.dryRun({}, dir.path);
        expect(result.preview, contains('pytest'), reason: file);
        await dir.delete(recursive: true);
      }
    });

    test('detection order puts Dart ahead of Node', () async {
      // A Flutter app with a package.json for tooling must still run dart test.
      await marker('pubspec.yaml');
      await marker('package.json');
      expect(await preview(), contains('dart test'));
      expect(await preview(), isNot(contains('npm')));
    });

    test('reports no framework for an empty directory', () async {
      expect(await preview(), contains('Could not detect'));
    });

    test('execute throws when no framework is detected', () async {
      await expectLater(
        tool.execute({}, tempDir.path),
        throwsA(isA<ToolError>()),
      );
    });
  });

  group('per-framework arguments', () {
    test('Dart takes a path and a --name filter', () async {
      await marker('pubspec.yaml');
      final command = await preview({
        'path': 'test/foo_test.dart',
        'filter': 'my case',
      });
      expect(command, contains('test/foo_test.dart'));
      expect(command, contains('--name'));
    });

    test('Node ignores path and uses --testNamePattern', () async {
      await marker('package.json');
      final command = await preview({
        'path': 'test/foo.spec.js',
        'filter': 'my case',
      });
      expect(command, contains('--testNamePattern'));
      expect(command, isNot(contains('foo.spec.js')));
    });

    test('Go defaults to ./... and uses -run', () async {
      await marker('go.mod');
      expect(await preview(), contains('./...'));
      expect(await preview({'filter': 'TestFoo'}), contains('-run'));
    });

    test('Python uses -k for the filter', () async {
      await marker('pyproject.toml');
      expect(await preview({'filter': 'my case'}), contains('-k'));
    });

    test('Rust passes the filter positionally', () async {
      await marker('Cargo.toml');
      final command = await preview({'filter': 'my_test'});
      expect(command, contains('cargo test'));
      expect(command, contains('my_test'));
    });
  });

  group('injection defence', () {
    // Two layers: _sanitize strips shell metacharacters, then _shellQuote wraps
    // what survives. Both are asserted, since either alone would be brittle.
    setUp(() async => marker('pubspec.yaml'));

    test('strips a command separator', () async {
      final command = await preview({'filter': 'x; rm -rf /'});
      expect(command, isNot(contains(';')));
    });

    test('strips command substitution', () async {
      for (final payload in [r'$(whoami)', '`whoami`', r'${HOME}']) {
        final command = await preview({'filter': payload});
        expect(command, isNot(contains(r'$(')), reason: payload);
        expect(command, isNot(contains('`')), reason: payload);
      }
    });

    test('strips quotes that could escape the quoted context', () async {
      final command = await preview({'filter': "a' && echo pwned && '"});
      expect(command, isNot(contains('&&')));
    });

    test('strips pipes and redirects', () async {
      final command = await preview({'filter': 'a | tee /tmp/x > /tmp/y'});
      expect(command, isNot(contains('|')));
      expect(command, isNot(contains('>')));
    });

    test('quotes the surviving value', () async {
      final command = await preview({'filter': 'two words'});
      expect(command, contains("'two words'"));
    });

    test('a filter of only metacharacters is dropped entirely', () async {
      // _sanitize returns null for an empty result, so no flag is emitted.
      final command = await preview({'filter': r'$();|&'});
      expect(command, isNot(contains('--name')));
    });

    test('keeps legitimate characters', () async {
      final command = await preview({'filter': 'my_test.case-1/sub:x'});
      expect(command, contains('my_test.case-1/sub:x'));
    });
  });

  group('contract', () {
    test('is classified confirm — runs arbitrary commands', () {
      expect(tool.riskLevel, equals(RiskLevel.confirm));
    });

    test('path and filter are both optional', () {
      expect(tool.inputSchema['required'], isEmpty);
    });

    test('dryRun spawns nothing', () async {
      await marker('pubspec.yaml');
      final canary = File(p.join(tempDir.path, 'ran.txt'));
      await tool.dryRun({'filter': 'x'}, tempDir.path);
      expect(await canary.exists(), isFalse);
    });
  });
}
