import 'dart:io';
import 'package:dart_console/dart_console.dart';
import 'ansi_helpers.dart';

/// Arrow-key single-choice picker. Synchronous (readKey blocks).
/// Returns the index of the selected option.
/// Returns [defaultIndex] on Escape or Ctrl-C.
/// Falls back to printing a plain list when stdout is not a TTY.
class PickerWidget {
  static int pick({
    required List<String> options,
    List<String>? hints,
    int defaultIndex = 0,
    String header = '  ↑/↓ select · Enter confirm',
  }) {
    if (!stdout.hasTerminal) {
      // Non-interactive fallback: print the list and return the default.
      for (var i = 0; i < options.length; i++) {
        final hint = (hints != null && i < hints.length) ? '  ${hints[i]}' : '';
        final marker = i == defaultIndex ? ' ◀' : '';
        stdout.writeln('  ${options[i]}$hint$marker');
      }
      return defaultIndex;
    }

    var selected = defaultIndex;
    final console = Console.scrolling();
    stdout.writeln(dim(header));
    _render(options, hints, selected, firstRender: true);

    while (true) {
      final key = console.readKey();
      if (!key.isControl) continue;
      switch (key.controlChar) {
        case ControlCharacter.arrowUp:
          if (selected > 0) {
            selected--;
            _render(options, hints, selected);
          }
        case ControlCharacter.arrowDown:
          if (selected < options.length - 1) {
            selected++;
            _render(options, hints, selected);
          }
        case ControlCharacter.enter:
          _clear(console, options.length + 1);
          return selected;
        case ControlCharacter.escape:
        case ControlCharacter.ctrlC:
          _clear(console, options.length + 1);
          return defaultIndex;
        default:
          break;
      }
    }
  }

  static void _render(
    List<String> options,
    List<String>? hints,
    int selected, {
    bool firstRender = false,
  }) {
    if (!firstRender) stdout.write('\x1b[${options.length}A');
    for (var i = 0; i < options.length; i++) {
      final hint = (hints != null && i < hints.length)
          ? dim('  ${hints[i]}')
          : '';
      if (i == selected) {
        stdout.write('\r\x1b[K\x1b[7m  ▶ ${options[i]}\x1b[0m$hint\n');
      } else {
        stdout.write('\r\x1b[K     ${dim(options[i])}$hint\n');
      }
    }
  }

  static void _clear(Console console, int lineCount) {
    for (var i = 0; i < lineCount; i++) {
      console.cursorUp();
      console.eraseLine();
    }
  }
}
