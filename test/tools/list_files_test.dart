import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/tools/file/list_files_tool.dart';

void main() {
  late Directory tempDir;
  late ListFilesTool tool;

  /// Creates [relPath] with [content], including parent directories.
  Future<void> writeFile(String relPath, [String content = 'x']) async {
    final file = File(p.join(tempDir.path, relPath));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_list_');
    tool = ListFilesTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('ListFilesTool', () {
    test('lists files in the working directory', () async {
      await writeFile('a.txt');
      await writeFile('b.txt');

      final result = await tool.execute({}, tempDir.path);
      expect(result, contains('a.txt'));
      expect(result, contains('b.txt'));
    });

    test('marks directories with a trailing slash', () async {
      await Directory(p.join(tempDir.path, 'lib')).create();
      await writeFile('main.dart');

      final result = await tool.execute({}, tempDir.path);
      expect(result, contains('lib/'));
      expect(result, contains('main.dart'));
      expect(result, isNot(contains('main.dart/')));
    });

    test('is non-recursive by default', () async {
      await writeFile('top.txt');
      await writeFile('nested/deep.txt');

      final result = await tool.execute({}, tempDir.path);
      expect(result, contains('top.txt'));
      expect(result, contains('nested'));
      expect(result, isNot(contains('deep.txt')));
    });

    test('lists recursively when asked', () async {
      await writeFile('top.txt');
      await writeFile('nested/deep.txt');

      final result = await tool.execute({'recursive': true}, tempDir.path);
      expect(result, contains('top.txt'));
      expect(result, contains(p.join('nested', 'deep.txt')));
    });

    test('lists a subdirectory by relative path', () async {
      await writeFile('lib/one.dart');
      await writeFile('other.txt');

      final result = await tool.execute({'path': 'lib'}, tempDir.path);
      expect(result, contains('one.dart'));
      expect(result, isNot(contains('other.txt')));
    });

    test('returns (empty) for an empty directory', () async {
      await Directory(p.join(tempDir.path, 'empty')).create();
      final result = await tool.execute({'path': 'empty'}, tempDir.path);
      expect(result, equals('(empty)'));
    });

    test('output is sorted', () async {
      await writeFile('c.txt');
      await writeFile('a.txt');
      await writeFile('b.txt');

      final lines = (await tool.execute({}, tempDir.path)).split('\n');
      final sorted = [...lines]..sort();
      expect(lines, equals(sorted));
    });

    test('rejects a path outside the working directory', () async {
      expect(
        () => tool.execute({'path': '../..'}, tempDir.path),
        throwsA(isA<ToolError>()),
      );
    });

    test('throws when the directory does not exist', () async {
      expect(
        () => tool.execute({'path': 'nope'}, tempDir.path),
        throwsA(isA<ToolError>()),
      );
    });

    test('is classified safe', () {
      expect(tool.riskLevel, equals(RiskLevel.safe));
    });

    test('dryRun previews without touching the filesystem', () async {
      final result = await tool.dryRun({'path': 'lib'}, tempDir.path);
      expect(result.preview, contains('lib'));
      expect(result.riskLevel, equals(RiskLevel.safe));
    });
  });
}
