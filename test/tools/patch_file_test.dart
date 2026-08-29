import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/tools/tool_interface.dart';
import 'package:proxima/tools/file/patch_file_tool.dart';

void main() {
  late Directory tempDir;
  late PatchFileTool tool;

  Future<File> writeFile(String name, String content) async {
    final file = File(p.join(tempDir.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    return file;
  }

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_patch_');
    tool = PatchFileTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('PatchFileTool', () {
    test('replaces the first occurrence by default', () async {
      final file = await writeFile('a.txt', 'foo bar foo');

      await tool.execute({
        'path': 'a.txt',
        'old_str': 'foo',
        'new_str': 'baz',
      }, tempDir.path);

      expect(await file.readAsString(), equals('baz bar foo'));
    });

    test('replaces every occurrence when replace_all is set', () async {
      final file = await writeFile('a.txt', 'foo bar foo');

      await tool.execute({
        'path': 'a.txt',
        'old_str': 'foo',
        'new_str': 'baz',
        'replace_all': true,
      }, tempDir.path);

      expect(await file.readAsString(), equals('baz bar baz'));
    });

    test('patches multi-line content exactly', () async {
      final file = await writeFile('a.dart', 'void main() {\n  old();\n}\n');

      await tool.execute({
        'path': 'a.dart',
        'old_str': '  old();',
        'new_str': '  fresh();',
      }, tempDir.path);

      expect(
        await file.readAsString(),
        equals('void main() {\n  fresh();\n}\n'),
      );
    });

    test('creates a backup before patching', () async {
      await writeFile('a.txt', 'original');

      await tool.execute({
        'path': 'a.txt',
        'old_str': 'original',
        'new_str': 'changed',
      }, tempDir.path);

      final backup = File(p.join(tempDir.path, 'a.txt.proxima_bak'));
      expect(await backup.exists(), isTrue);
      expect(await backup.readAsString(), equals('original'));
    });

    test('emits the BACKUP_PATH marker /undo depends on', () async {
      await writeFile('a.txt', 'original');

      final result = await tool.execute({
        'path': 'a.txt',
        'old_str': 'original',
        'new_str': 'changed',
      }, tempDir.path);

      expect(result, contains('BACKUP_PATH:'));
      final marker = result.split('BACKUP_PATH:').last.trim();
      expect(await File(marker).exists(), isTrue);
    });

    test('throws when old_str is absent', () async {
      await writeFile('a.txt', 'hello');

      await expectLater(
        tool.execute({
          'path': 'a.txt',
          'old_str': 'missing',
          'new_str': 'x',
        }, tempDir.path),
        throwsA(isA<ToolError>()),
      );
    });

    test('leaves the file untouched when old_str is absent', () async {
      final file = await writeFile('a.txt', 'hello');

      try {
        await tool.execute({
          'path': 'a.txt',
          'old_str': 'missing',
          'new_str': 'x',
        }, tempDir.path);
      } on ToolError {
        // expected
      }

      expect(await file.readAsString(), equals('hello'));
      expect(
        await File(p.join(tempDir.path, 'a.txt.proxima_bak')).exists(),
        isFalse,
        reason: 'no backup should be written for a failed patch',
      );
    });

    test('throws when the file does not exist', () async {
      await expectLater(
        tool.execute({
          'path': 'nope.txt',
          'old_str': 'a',
          'new_str': 'b',
        }, tempDir.path),
        throwsA(isA<ToolError>()),
      );
    });

    test('rejects a path outside the working directory', () async {
      await expectLater(
        tool.execute({
          'path': '../escape.txt',
          'old_str': 'a',
          'new_str': 'b',
        }, tempDir.path),
        throwsA(isA<ToolError>()),
      );
    });

    test('supports deletion via an empty new_str', () async {
      final file = await writeFile('a.txt', 'keep REMOVE keep');

      await tool.execute({
        'path': 'a.txt',
        'old_str': ' REMOVE',
        'new_str': '',
      }, tempDir.path);

      expect(await file.readAsString(), equals('keep keep'));
    });

    test('is classified confirm — writes require approval', () {
      expect(tool.riskLevel, equals(RiskLevel.confirm));
    });

    test('dryRun produces a diff without touching the file', () async {
      final file = await writeFile('a.txt', 'original');

      final result = await tool.dryRun({
        'path': 'a.txt',
        'old_str': 'original',
        'new_str': 'changed',
      }, tempDir.path);

      expect(result.diffText, isNotNull);
      expect(result.riskLevel, equals(RiskLevel.confirm));
      expect(await file.readAsString(), equals('original'));
      expect(
        await File(p.join(tempDir.path, 'a.txt.proxima_bak')).exists(),
        isFalse,
      );
    });
  });
}
