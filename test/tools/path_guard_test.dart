import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/path_guard.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_test_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('isSafePath', () {
    test('allows file within working dir', () {
      expect(isSafePath('lib/main.dart', tempDir.path), isTrue);
    });

    test('allows nested file', () {
      expect(isSafePath('lib/src/util.dart', tempDir.path), isTrue);
    });

    test('allows dot (working dir itself)', () {
      expect(isSafePath('.', tempDir.path), isTrue);
    });

    test('blocks path traversal with ../', () {
      expect(isSafePath('../etc/passwd', tempDir.path), isFalse);
    });

    test('blocks double traversal', () {
      expect(isSafePath('lib/../../etc/passwd', tempDir.path), isFalse);
    });

    test('blocks absolute path outside working dir', () {
      expect(isSafePath('/etc/passwd', tempDir.path), isFalse);
    });

    test('allows absolute path inside working dir', () {
      final insidePath = p.join(tempDir.path, 'file.txt');
      expect(isSafePath(insidePath, tempDir.path), isTrue);
    });

    test('blocks symlink escape', () async {
      // Create target outside working dir.
      final outsideDir = await Directory.systemTemp.createTemp(
        'proxima_outside_',
      );
      final outsideFile = File(p.join(outsideDir.path, 'secret.txt'));
      await outsideFile.writeAsString('secret');

      // Create symlink inside working dir pointing outside.
      final symlinkPath = p.join(tempDir.path, 'escape_link');
      final link = Link(symlinkPath);
      await link.create(outsideFile.path);

      expect(isSafePath('escape_link', tempDir.path), isFalse);

      await outsideDir.delete(recursive: true);
    });
  });
}
