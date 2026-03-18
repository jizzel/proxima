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
}
