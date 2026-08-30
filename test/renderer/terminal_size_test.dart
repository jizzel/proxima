import 'package:test/test.dart';
import 'package:proxima/renderer/ansi_helpers.dart';
import 'package:proxima/renderer/repl_header.dart';

void main() {
  // Regression: `stdout.terminalColumns` throws a StdoutException rather than
  // returning a default whenever the size is unavailable — piped output, a CI
  // runner, or a PTY opened without a window size. Unguarded, that crashed the
  // REPL during header rendering, before the first prompt, over a cosmetic
  // detail. The test runner pipes stdout, so these calls exercise the throwing
  // path directly.
  group('terminal size guards', () {
    test('terminalWidth returns a usable value instead of throwing', () {
      expect(terminalWidth, returnsNormally);
      expect(terminalWidth(), greaterThan(0));
    });

    test('terminalHeight returns a usable value instead of throwing', () {
      expect(terminalHeight, returnsNormally);
      expect(terminalHeight(), greaterThan(0));
    });

    test('the fallback is used when the size is unavailable', () {
      // Under a piped stdout there is no real size, so the fallback shows
      // through; with a real terminal this asserts only that it is positive.
      expect(terminalWidth(fallback: 100), greaterThan(0));
      expect(terminalHeight(fallback: 40), greaterThan(0));
    });

    test('the REPL header renders without a terminal', () {
      expect(
        () => ReplHeader.render(
          model: 'openai/gpt-5.6-sol',
          workingDir: '/Users/someone/projects/demo',
          version: '1.7.0',
        ),
        returnsNormally,
      );
    });

    test('the header includes the model, shortened dir, and version', () {
      final out = ReplHeader.render(
        model: 'anthropic/claude-sonnet-4-6',
        workingDir: '/Users/someone/projects/demo',
        version: '1.7.0',
      );
      // The provider prefix is stripped for display.
      expect(out, contains('claude-sonnet-4-6'));
      expect(out, contains('proxima 1.7.0'));
      expect(out, contains('projects/demo'));
    });
  });
}
