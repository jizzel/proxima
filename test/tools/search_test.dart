import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/tools/search/search_tool.dart';

void main() {
  late Directory tempDir;
  late SearchTool tool;

  Future<void> writeFile(String relPath, String content) async {
    final file = File(p.join(tempDir.path, relPath));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_search_');
    tool = SearchTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('SearchTool', () {
    test('finds a literal match and reports its file', () async {
      await writeFile('a.dart', 'void main() {\n  // TODO: fix\n}\n');

      final result = await tool.execute({'pattern': 'TODO'}, tempDir.path);
      expect(result, contains('TODO'));
      expect(result, contains('a.dart'));
    });

    test('supports regex patterns', () async {
      await writeFile('a.dart', 'int x = 42;\nString s = "hi";\n');

      final result = await tool.execute({
        'pattern': r'int\s+\w+\s*=',
        'context_lines': 0,
      }, tempDir.path);
      // Matched lines are marked with '>'; without context, only they appear.
      expect(result, contains('int x'));
      expect(result, isNot(contains('String s')));
    });

    test('is case-sensitive by default', () async {
      await writeFile('a.dart', 'todo lowercase\n');
      final result = await tool.execute({'pattern': 'TODO'}, tempDir.path);
      expect(result.toLowerCase(), anyOf(contains('no match'), contains('0')));
    });

    test('honours case_insensitive', () async {
      await writeFile('a.dart', 'todo lowercase\n');
      final result = await tool.execute({
        'pattern': 'TODO',
        'case_insensitive': true,
      }, tempDir.path);
      expect(result, contains('todo'));
    });

    test('filters files with file_pattern', () async {
      await writeFile('a.dart', 'MATCH here\n');
      await writeFile('b.txt', 'MATCH here\n');

      final result = await tool.execute({
        'pattern': 'MATCH',
        'file_pattern': '*.dart',
      }, tempDir.path);
      expect(result, contains('a.dart'));
      expect(result, isNot(contains('b.txt')));
    });

    test('searches a single file when given one', () async {
      await writeFile('a.dart', 'MATCH\n');
      await writeFile('b.dart', 'MATCH\n');

      final result = await tool.execute({
        'pattern': 'MATCH',
        'path': 'a.dart',
      }, tempDir.path);
      expect(result, contains('a.dart'));
      expect(result, isNot(contains('b.dart')));
    });

    test('does not walk ignored directories', () async {
      await writeFile('lib/a.dart', 'NEEDLE\n');
      await writeFile('node_modules/pkg/b.js', 'NEEDLE\n');

      final result = await tool.execute({'pattern': 'NEEDLE'}, tempDir.path);
      expect(result, contains('a.dart'));
      expect(result, isNot(contains('node_modules')));
    });

    test('reports no matches clearly', () async {
      await writeFile('a.dart', 'nothing here\n');
      final result = await tool.execute({'pattern': 'ABSENT'}, tempDir.path);
      expect(result.toLowerCase(), anyOf(contains('no match'), contains('0')));
    });

    test('is classified safe', () {
      expect(tool.riskLevel, equals(RiskLevel.safe));
    });
  });
}
