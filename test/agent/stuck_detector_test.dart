import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/agent/stuck_detector.dart';

void main() {
  ToolCall call(String tool, [Map<String, dynamic> args = const {}]) =>
      ToolCall(tool: tool, args: args, reasoning: '');

  group('StuckDetector.isStuck', () {
    test('not stuck with fewer than window calls', () {
      final log = [
        call('read_file', {'path': 'a.dart'}),
      ];
      expect(StuckDetector.isStuck(log), isFalse);
    });

    test('not stuck with different calls', () {
      final log = [
        call('read_file', {'path': 'a.dart'}),
        call('read_file', {'path': 'b.dart'}),
        call('list_files', {}),
      ];
      expect(StuckDetector.isStuck(log), isFalse);
    });

    test('detects 3 identical calls', () {
      final log = [
        call('read_file', {'path': 'a.dart'}),
        call('read_file', {'path': 'a.dart'}),
        call('read_file', {'path': 'a.dart'}),
      ];
      expect(StuckDetector.isStuck(log), isTrue);
    });

    test('not stuck when last 3 differ even if earlier repeated', () {
      final log = [
        call('read_file', {'path': 'a.dart'}),
        call('read_file', {'path': 'a.dart'}),
        call('read_file', {'path': 'a.dart'}),
        call('list_files', {}),
        call('read_file', {'path': 'b.dart'}),
        call('glob', {'pattern': '*.dart'}),
      ];
      expect(StuckDetector.isStuck(log), isFalse);
    });

    test('detects stuck with custom window', () {
      final log = [call('list_files'), call('list_files')];
      expect(StuckDetector.isStuck(log, window: 2), isTrue);
    });

    test('empty log is not stuck', () {
      expect(StuckDetector.isStuck([]), isFalse);
    });
  });

  group('StuckDetector.isSpinning', () {
    test('not spinning with fewer than window calls', () {
      final log = List.generate(
        5,
        (_) => call('read_file', {'path': 'a.dart'}),
      );
      expect(StuckDetector.isSpinning(log), isFalse);
    });

    test('detects 6 repetitive read-only calls', () {
      // Six *different* read-only tools is diversified exploration, not
      // spinning — the window must revisit the same targets to count.
      final log = [
        call('read_file', {'path': 'a.dart'}),
        call('list_files', {}),
        call('read_file', {'path': 'a.dart'}),
        call('list_files', {}),
        call('read_file', {'path': 'a.dart'}),
        call('list_files', {}),
      ];
      expect(StuckDetector.isSpinning(log), isTrue);
    });

    test('six different read-only tools is exploration', () {
      final log = [
        call('read_file', {'path': 'a.dart'}),
        call('list_files', {}),
        call('glob', {'pattern': '*.dart'}),
        call('search', {'query': 'foo'}),
        call('find_references', {'symbol': 'bar'}),
        call('get_imports', {'path': 'a.dart'}),
      ];
      expect(StuckDetector.isSpinning(log), isFalse);
    });

    test('not spinning when a mutating call is present', () {
      final log = [
        call('read_file', {'path': 'a.dart'}),
        call('list_files', {}),
        call('glob', {'pattern': '*.dart'}),
        call('search', {'query': 'foo'}),
        call('find_references', {'symbol': 'bar'}),
        call('write_file', {'path': 'a.dart', 'content': 'x'}),
      ];
      expect(StuckDetector.isSpinning(log), isFalse);
    });

    test('only looks at last window calls', () {
      // The leading write falls outside the 6-call window, so the repetitive
      // read-only tail still registers.
      final log = [
        call('write_file', {'path': 'a.dart', 'content': 'x'}),
        call('read_file', {'path': 'a.dart'}),
        call('list_files', {}),
        call('read_file', {'path': 'a.dart'}),
        call('list_files', {}),
        call('read_file', {'path': 'a.dart'}),
        call('list_files', {}),
      ];
      expect(StuckDetector.isSpinning(log), isTrue);
    });

    test('empty log is not spinning', () {
      expect(StuckDetector.isSpinning([]), isFalse);
    });
  });
  group('StuckDetector.isSpinning — exploration vs repetition', () {
    ToolCall read(String path) =>
        ToolCall(tool: 'read_file', args: {'path': path}, reasoning: '');

    test('reading distinct files is exploration, not spinning', () {
      // Regression: this fired twice on a real six-file project while the
      // agent was exploring before writing, blocking the task both times.
      final log = [
        read('README.md'),
        read('package.json'),
        read('DESCRIPTION.md'),
        read('src/index.ts'),
        read('src/Root.tsx'),
        read('src/Composition.tsx'),
      ];
      expect(StuckDetector.isSpinning(log), isFalse);
    });

    test('re-reading the same two files is spinning', () {
      final log = [
        read('a.dart'),
        read('b.dart'),
        read('a.dart'),
        read('b.dart'),
        read('a.dart'),
        read('b.dart'),
      ];
      expect(StuckDetector.isSpinning(log), isTrue);
    });

    test('an identical call repeated is spinning', () {
      expect(StuckDetector.isSpinning(List.filled(6, read('a.dart'))), isTrue);
    });

    test('three distinct targets in six calls is still spinning', () {
      final log = [
        read('a'),
        read('b'),
        read('c'),
        read('a'),
        read('b'),
        read('c'),
      ];
      expect(StuckDetector.isSpinning(log), isTrue);
    });

    test('distinctness counts arguments, not just the tool name', () {
      // Six read_file calls, all different paths — one tool, six fingerprints.
      final log = [for (var i = 0; i < 6; i++) read('file$i.dart')];
      expect(StuckDetector.isSpinning(log), isFalse);
    });

    test('a mutating call in the window is never spinning', () {
      final log = [
        read('a'),
        read('a'),
        ToolCall(tool: 'write_file', args: {'path': 'x'}, reasoning: ''),
        read('a'),
        read('a'),
        read('a'),
      ];
      expect(StuckDetector.isSpinning(log), isFalse);
    });
  });
}
