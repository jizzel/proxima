import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/tools/file/glob_tool.dart';

void main() {
  late Directory tempDir;
  late GlobTool tool;

  Future<void> writeFile(String relPath) async {
    final file = File(p.join(tempDir.path, relPath));
    await file.parent.create(recursive: true);
    await file.writeAsString('x');
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_glob_');
    tool = GlobTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('GlobTool', () {
    test('** matches across directory levels', () async {
      await writeFile('a.dart');
      await writeFile('lib/b.dart');
      await writeFile('lib/nested/c.dart');

      final result = await tool.execute({'pattern': '**/*.dart'}, tempDir.path);
      expect(result, contains('a.dart'));
      expect(result, contains('b.dart'));
      expect(result, contains('c.dart'));
    });

    test('a single * does not cross directory separators', () async {
      await writeFile('top.dart');
      await writeFile('lib/nested.dart');

      final result = await tool.execute({'pattern': '*.dart'}, tempDir.path);
      expect(result, contains('top.dart'));
      expect(result, isNot(contains('nested.dart')));
    });

    test('filters by extension', () async {
      await writeFile('a.dart');
      await writeFile('b.txt');

      final result = await tool.execute({'pattern': '**/*.dart'}, tempDir.path);
      expect(result, contains('a.dart'));
      expect(result, isNot(contains('b.txt')));
    });

    test('honours the base directory', () async {
      await writeFile('lib/a.dart');
      await writeFile('test/b.dart');

      final result = await tool.execute({
        'pattern': '**/*.dart',
        'base': 'lib',
      }, tempDir.path);
      expect(result, contains('a.dart'));
      expect(result, isNot(contains('b.dart')));
    });

    test('skips ignored directories', () async {
      await writeFile('lib/a.dart');
      await writeFile('node_modules/pkg/b.dart');
      await writeFile('.git/c.dart');

      final result = await tool.execute({'pattern': '**/*.dart'}, tempDir.path);
      expect(result, contains('a.dart'));
      expect(result, isNot(contains('node_modules')));
      expect(result, isNot(contains('.git')));
    });

    test('reports no matches clearly', () async {
      await writeFile('a.txt');
      final result = await tool.execute({'pattern': '**/*.dart'}, tempDir.path);
      expect(result.toLowerCase(), anyOf(contains('no'), contains('0')));
    });

    test('results are sorted', () async {
      await writeFile('c.dart');
      await writeFile('a.dart');
      await writeFile('b.dart');

      final lines = (await tool.execute({
        'pattern': '**/*.dart',
      }, tempDir.path)).split('\n').where((l) => l.endsWith('.dart')).toList();
      expect(lines, equals([...lines]..sort()));
    });

    test('is classified safe', () {
      expect(tool.riskLevel, equals(RiskLevel.safe));
    });
  });
}
