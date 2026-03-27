import 'dart:io';
import 'package:dart_console/dart_console.dart';
import 'package:path/path.dart' as p;

/// A readline implementation with a fixed-bottom suggestion panel.
///
/// Layout:
///   [conversation scroll area — untouched by suggestions]
///   ─────────────────────────
///    ❯ <input buffer>
///   ─────────────────────────
///   suggestion 1
///   suggestion 2   (highlighted)
///   ...
///
/// The suggestion panel lives *below* the input line and is redrawn in-place
/// using cursor-up sequences — it never touches the scroll buffer above.
///
/// Keyboard behaviour:
///   ↓              Enter suggestion list / next item
///   ↑              Previous item / back to input / history scroll
///   Enter          Accept highlighted item (stay on input) or submit
///   Escape         Dismiss list, return focus to input
///   Tab            Accept top suggestion immediately
///   Ctrl-C         Cancel input, return null
class ReadLine {
  final Console _console;
  final List<String> _history = [];
  int _historyIndex = -1;
  final String? _historyFile;

  static const _maxSuggestions = 6;
  static const _maxPersistedHistory = 500;

  /// Sentinel returned by [readLine] when Shift+Tab is pressed, indicating a
  /// plan-mode toggle rather than actual submitted input.
  static const _kShiftTabSentinel = '\x00__shift_tab__';

  /// Public alias used by callers to check for the plan-mode toggle sentinel.
  static const shiftTabSentinel = _kShiftTabSentinel;
  // How many lines below the input line are currently occupied by the panel.
  // 0 = no panel painted. Includes the separator line.
  int _panelHeight = 0;

  ReadLine({String? historyFile})
    : _console = Console.scrolling(),
      _historyFile = historyFile {
    _loadHistory();
  }

  void _loadHistory() {
    final path = _historyFile;
    if (path == null) return;
    try {
      final file = File(path);
      if (!file.existsSync()) return;
      final lines = file.readAsLinesSync();
      _history.addAll(lines.where((l) => l.isNotEmpty));
    } catch (_) {
      // History file unreadable — start fresh.
    }
  }

  void _saveHistory() {
    final path = _historyFile;
    if (path == null) return;
    try {
      final file = File(path);
      file.parent.createSync(recursive: true);
      final toSave = _history.length > _maxPersistedHistory
          ? _history.sublist(_history.length - _maxPersistedHistory)
          : _history;
      file.writeAsStringSync('${toSave.join('\n')}\n');
    } catch (_) {
      // Best-effort — failure to save history is not fatal.
    }
  }

  /// Named constructor for default user history location.
  factory ReadLine.withUserHistory() {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return ReadLine();
    return ReadLine(historyFile: p.join(home, '.proxima', 'input_history'));
  }

  String? readLine({
    String prompt = '',
    List<String> Function(String buffer)? completer,
    bool cancelOnBreak = true,
    void Function()? onShiftTab,
  }) {
    var buffer = '';
    var cursorPos = 0;
    _historyIndex = -1;
    String? savedBuffer;
    // Print the prompt once (including any leading newline for spacing).
    // _renderPanel uses the inline portion only (no leading newlines).
    stdout.write(prompt);
    final inlinePrompt = prompt.replaceFirst(RegExp(r'^\n+'), '');

    // -1 = focus on input; 0..n = highlighted suggestion index
    var focusIndex = -1;
    var lastCandidates = <String>[];

    while (true) {
      // Recompute suggestions whenever focus is on input.
      if (focusIndex == -1 && completer != null) {
        lastCandidates = completer(buffer);
      }
      final candidates = lastCandidates;

      _renderPanel(inlinePrompt, buffer, cursorPos, candidates, focusIndex);

      final key = _console.readKey();

      // ── Arrow-Down ──────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.arrowDown) {
        if (focusIndex == -1) {
          if (_historyIndex != -1) {
            // Already in history — move forward regardless of candidates.
            _historyIndex++;
            if (_historyIndex >= _history.length) {
              _historyIndex = -1;
              buffer = savedBuffer ?? '';
            } else {
              buffer = _history[_historyIndex];
            }
            cursorPos = buffer.length;
            lastCandidates = []; // recompute on next loop
          } else if (candidates.isNotEmpty) {
            focusIndex = 0; // enter suggestion list
          }
        } else if (focusIndex < candidates.length - 1) {
          focusIndex++;
        }
        continue;
      }

      // ── Arrow-Up ────────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.arrowUp) {
        if (focusIndex == 0) {
          focusIndex = -1; // back to input
        } else if (focusIndex > 0) {
          focusIndex--;
        } else {
          // History scroll
          if (_history.isNotEmpty) {
            if (_historyIndex == -1) {
              savedBuffer = buffer;
              _historyIndex = _history.length - 1;
            } else if (_historyIndex > 0) {
              _historyIndex--;
            }
            buffer = _history[_historyIndex];
            cursorPos = buffer.length;
          }
        }
        continue;
      }

      // ── Enter ───────────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.enter) {
        if (focusIndex >= 0 && focusIndex < candidates.length) {
          // Accept highlighted suggestion and submit immediately.
          buffer = candidates[focusIndex];
          cursorPos = buffer.length;
          focusIndex = -1;
          lastCandidates = [];
          // Redraw so the accepted value is visible, then submit.
          _renderPanel(inlinePrompt, buffer, cursorPos, [], -1);
          _erasePanel();
          _console.writeLine();
          if (buffer.isNotEmpty) {
            if (_history.isEmpty || _history.last != buffer) {
              _history.add(buffer);
            }
            _saveHistory();
          }
          return buffer;
        }
        // Submit.
        _erasePanel();
        _console.writeLine();
        if (buffer.isNotEmpty) {
          // Avoid duplicate consecutive entries.
          if (_history.isEmpty || _history.last != buffer) {
            _history.add(buffer);
          }
          _saveHistory();
        }
        return buffer;
      }

      // ── Escape ──────────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.escape) {
        if (focusIndex >= 0) {
          focusIndex = -1;
          lastCandidates = [];
          continue;
        }
        continue;
      }

      // ── Ctrl-C ──────────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.ctrlC) {
        if (cancelOnBreak) {
          _erasePanel();
          _console.writeLine();
          return null;
        }
        continue;
      }

      // Any other key while list is focused returns focus to input first.
      if (focusIndex >= 0) {
        focusIndex = -1;
      }

      // ── Tab ─────────────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.tab) {
        if (candidates.isNotEmpty) {
          buffer = candidates[0];
          cursorPos = buffer.length;
          lastCandidates = [];
          // Tab counts as typing — leave history mode.
          _historyIndex = -1;
          savedBuffer = null;
        }
        continue;
      }

      // ── Shift+Tab — toggle plan mode ─────────────────────────────────────────
      // Terminal sends ESC [ Z for Shift+Tab (standard VT100/xterm).
      if (!key.isControl && key.char == '\x1b[Z') {
        _erasePanel();
        onShiftTab?.call();
        // Return a sentinel that the REPL interprets as a mode toggle (no
        // actual input submitted — the REPL will re-prompt immediately).
        return _kShiftTabSentinel;
      }

      // ── Edit control keys ───────────────────────────────────────────────────
      if (key.isControl) {
        switch (key.controlChar) {
          case ControlCharacter.backspace:
          case ControlCharacter.ctrlH:
            if (cursorPos > 0) {
              buffer =
                  buffer.substring(0, cursorPos - 1) +
                  buffer.substring(cursorPos);
              cursorPos--;
              // Any edit exits history-scroll mode so ↑/↓ works from here.
              _historyIndex = -1;
              savedBuffer = null;
            }
          case ControlCharacter.delete:
          case ControlCharacter.ctrlD:
            if (cursorPos < buffer.length) {
              buffer =
                  buffer.substring(0, cursorPos) +
                  buffer.substring(cursorPos + 1);
              _historyIndex = -1;
              savedBuffer = null;
            }
          case ControlCharacter.ctrlU:
            buffer = buffer.substring(cursorPos);
            cursorPos = 0;
            _historyIndex = -1;
            savedBuffer = null;
          case ControlCharacter.ctrlK:
            buffer = buffer.substring(0, cursorPos);
            _historyIndex = -1;
            savedBuffer = null;
          case ControlCharacter.ctrlA:
          case ControlCharacter.home:
            cursorPos = 0;
          case ControlCharacter.ctrlE:
          case ControlCharacter.end:
            cursorPos = buffer.length;
          case ControlCharacter.arrowLeft:
          case ControlCharacter.ctrlB:
            if (cursorPos > 0) cursorPos--;
          case ControlCharacter.arrowRight:
          case ControlCharacter.ctrlF:
            if (cursorPos < buffer.length) cursorPos++;
          case ControlCharacter.wordLeft:
            if (cursorPos > 0) {
              // Skip spaces before current word, then skip the word.
              var i = cursorPos - 1;
              while (i > 0 && buffer[i] == ' ') {
                i--;
              }
              while (i > 0 && buffer[i - 1] != ' ') {
                i--;
              }
              cursorPos = i;
            }
          case ControlCharacter.wordRight:
            if (cursorPos < buffer.length) {
              // Skip current word, then skip spaces.
              var i = cursorPos;
              while (i < buffer.length && buffer[i] != ' ') {
                i++;
              }
              while (i < buffer.length && buffer[i] == ' ') {
                i++;
              }
              cursorPos = i;
            }
          default:
            break;
        }
        continue;
      }

      // ── Printable character ─────────────────────────────────────────────────
      // Any typed character exits history-scroll mode.
      _historyIndex = -1;
      savedBuffer = null;
      buffer =
          buffer.substring(0, cursorPos) +
          key.char +
          buffer.substring(cursorPos);
      cursorPos++;
    }
  }

  // ── Panel rendering ─────────────────────────────────────────────────────────

  void _renderPanel(
    String prompt,
    String buffer,
    int cursorPos,
    List<String> candidates,
    int focusIndex,
  ) {
    final toShow = candidates.take(_maxSuggestions).toList();
    // New panel height: separator + suggestion rows (0 if no suggestions).
    final newHeight = toShow.isEmpty ? 0 : 1 + toShow.length;

    // Step 1: move down to cover old panel area and erase each old row.
    if (_panelHeight > 0) {
      stdout.write('\x1b[${_panelHeight}B'); // down to bottom of old panel
      for (var i = 0; i < _panelHeight; i++) {
        stdout.write('\r\x1b[K'); // erase line
        stdout.write('\x1b[1A'); // up one
      }
      // We are now back on the input line.
    }

    // Step 2: redraw the input line itself (prompt + buffer).
    stdout.write('\r\x1b[K$prompt$buffer');
    final back = buffer.length - cursorPos;
    if (back > 0) stdout.write('\x1b[${back}D');

    // Step 3: if there are suggestions, draw the panel below without scrolling.
    if (toShow.isEmpty) {
      _panelHeight = 0;
      return;
    }

    _panelHeight = newHeight;

    // Save cursor, draw panel, restore cursor.
    stdout.write('\x1b[s');

    // Separator line.
    stdout.write('\n\r\x1b[K');
    final w = _termWidth();
    stdout.write('\x1b[2m${'─' * w}\x1b[0m');

    // Suggestion rows.
    for (var i = 0; i < toShow.length; i++) {
      stdout.write('\n\r\x1b[K');
      stdout.write(_fmtSuggestion(toShow[i], buffer, i == focusIndex));
    }

    stdout.write('\x1b[u'); // back to input line
  }

  void _erasePanel() {
    if (_panelHeight == 0) return;
    stdout.write('\x1b[${_panelHeight}B');
    for (var i = 0; i < _panelHeight; i++) {
      stdout.write('\r\x1b[K');
      stdout.write('\x1b[1A');
    }
    _panelHeight = 0;
  }

  String _fmtSuggestion(String suggestion, String typed, bool selected) {
    if (selected) {
      return '\x1b[7m \x1b[1m$suggestion\x1b[0m\x1b[7m \x1b[0m';
    }
    final matchLen = _prefixLen(suggestion, typed);
    final matched = suggestion.substring(0, matchLen);
    final rest = suggestion.substring(matchLen);
    // Typed prefix is bright/normal; untyped completion suffix is dim.
    return ' $matched\x1b[2m$rest\x1b[0m';
  }

  int _prefixLen(String a, String b) {
    final len = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      if (a[i] != b[i]) return i;
    }
    return len;
  }

  int _termWidth() {
    try {
      return stdout.terminalColumns.clamp(20, 120);
    } catch (_) {
      return 80;
    }
  }
}
