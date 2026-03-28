import 'dart:io';
import 'package:test/test.dart';
import 'package:proxima/tools/search/find_references_tool.dart';
import 'package:proxima/tools/tool_interface.dart';

void main() {
  late Directory tempDir;
  late FindReferencesTool tool;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_refs_');
    tool = FindReferencesTool();
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<void> writeFile(String name, String content) async {
    final file = File('${tempDir.path}/$name');
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  test('finds simple usages of a symbol across files', () async {
    await writeFile('a.dart', '''
import 'b.dart';
void main() {
  final x = MyClass();
  x.doThing();
}
''');
    await writeFile('b.dart', '''
class MyClass {
  void doThing() {}
}
''');
    final result = await tool.execute({'symbol': 'MyClass'}, tempDir.path);
    expect(result, contains('MyClass'));
    expect(result, contains('a.dart'));
    expect(result, contains('b.dart'));
    expect(result, contains('Found'));
  });

  test('returns no references message when symbol not found', () async {
    await writeFile('foo.dart', 'void hello() {}');
    final result = await tool.execute({'symbol': 'NonExistent'}, tempDir.path);
    expect(result, 'No references found for "NonExistent".');
  });

  test('word boundary match — does not match partial names', () async {
    await writeFile('foo.dart', '''
class MyClassExtended {}
final x = MyClass();
''');
    final result = await tool.execute({'symbol': 'MyClass'}, tempDir.path);
    // Should match "MyClass()" but not "MyClassExtended" (word boundary)
    final lines = result
        .split('\n')
        .where((l) => l.contains('foo.dart'))
        .toList();
    // MyClassExtended contains MyClass but \b breaks at the capital E boundary? No —
    // \b is between \w and non-\w. "MyClassExtended" has no boundary between "MyClass"
    // and "Extended" since both are \w chars. So only the second line matches.
    expect(lines.length, 1);
    expect(lines.first, contains('MyClass()'));
  });

  test('exclude_definition skips definition lines', () async {
    await writeFile('foo.dart', '''
class TargetClass {
  void method() {}
}
final x = TargetClass();
''');
    final result = await tool.execute({
      'symbol': 'TargetClass',
      'exclude_definition': true,
    }, tempDir.path);
    // The usage line should appear, the class definition should not.
    expect(result, contains('TargetClass()'));
    expect(result, isNot(contains('class TargetClass')));
  });

  test('file_extensions filter limits scanned files', () async {
    await writeFile('foo.dart', 'final x = mySymbol;');
    await writeFile('foo.py', 'x = mySymbol');
    // Only scan .py files
    final result = await tool.execute({
      'symbol': 'mySymbol',
      'file_extensions': ['.py'],
    }, tempDir.path);
    expect(result, contains('foo.py'));
    expect(result, isNot(contains('foo.dart')));
  });

  test('max_results limits output', () async {
    for (var i = 0; i < 10; i++) {
      await writeFile('file$i.dart', 'final x = targetSym;');
    }
    final result = await tool.execute({
      'symbol': 'targetSym',
      'max_results': 3,
    }, tempDir.path);
    final refLines = result
        .split('\n')
        .where((l) => l.contains('.dart:'))
        .toList();
    expect(refLines.length, lessThanOrEqualTo(3));
  });

  test('path arg restricts search to subdirectory', () async {
    await writeFile('sub/inner.dart', 'final x = theSymbol;');
    await writeFile('outer.dart', 'final y = theSymbol;');

    final result = await tool.execute({
      'symbol': 'theSymbol',
      'path': 'sub',
    }, tempDir.path);
    expect(result, contains('inner.dart'));
    expect(result, isNot(contains('outer.dart')));
  });

  test('rejects path outside workingDir', () async {
    expect(
      () => tool.execute({'symbol': 'Foo', 'path': '/etc'}, tempDir.path),
      throwsA(isA<ToolError>()),
    );
  });

  test('skips .git directory', () async {
    final gitDir = Directory('${tempDir.path}/.git');
    await gitDir.create();
    await File(
      '${tempDir.path}/.git/hidden.dart',
    ).writeAsString('final x = secretSym;');
    final result = await tool.execute({'symbol': 'secretSym'}, tempDir.path);
    expect(result, contains('No references found'));
  });

  test('skips generated .g.dart files', () async {
    await writeFile('foo.g.dart', 'final x = generatedSym;');
    final result = await tool.execute({'symbol': 'generatedSym'}, tempDir.path);
    expect(result, contains('No references found'));
  });

  test('binary/malformed file is skipped gracefully', () async {
    final binaryFile = File('${tempDir.path}/binary.dart');
    await binaryFile.writeAsBytes([0xFF, 0xFE, 0x00, 0x01]);
    final result = await tool.execute({'symbol': 'anything'}, tempDir.path);
    expect(result, isA<String>());
  });

  test('output includes file count summary', () async {
    await writeFile('a.dart', 'final a = sym;');
    await writeFile('b.dart', 'final b = sym;');
    final result = await tool.execute({'symbol': 'sym'}, tempDir.path);
    expect(result, contains('Found'));
    expect(result, contains('2 files'));
  });

  test('dryRun returns preview without executing', () async {
    final result = await tool.dryRun({'symbol': 'MyThing'}, tempDir.path);
    expect(result.preview, contains('MyThing'));
    expect(result.preview, contains('Will scan'));
  });
}
