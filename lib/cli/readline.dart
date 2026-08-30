import 'dart:io';
import 'package:dart_console/dart_console.dart';
import 'package:path/path.dart' as p;

/// A readline implementation with inline completion.
///
/// Layout — everything lives on the prompt's own line:
///
///   ❯ /mod|el  (2/6 · tab)
///     ^typed ^ghost
///
/// The completion is drawn as dim text after the cursor and is never written
/// below the prompt. An earlier design drew a separator and suggestion rows
/// underneath using real newlines, then restored the cursor with `\x1b[s` /
/// `\x1b[u`; near the bottom of the terminal those newlines scroll the screen,
/// and a restore cannot undo a scroll, so each repaint left another copy in the
/// scrollback. Staying on one line removes that failure mode by construction.
///
/// Keyboard behaviour:
///   Tab            Accept the shown completion; press again to cycle
///   ↑ / ↓          History
///   Enter          Submit what is typed
///   Escape         Dismiss the hint (returns on the next edit)
///   Ctrl-C         Cancel input, return null
class ReadLine {
  final Console _console;
  final List<String> _history = [];
  int _historyIndex = -1;
  final String? _historyFile;

  /// How many candidates Tab will cycle through.
  static const _maxSuggestions = 6;
  static const _maxPersistedHistory = 500;

  /// Sentinel returned by [readLine] when Shift+Tab is pressed, indicating a
  /// plan-mode toggle rather than actual submitted input.
  static const _kShiftTabSentinel = '\x00__shift_tab__';

  /// Public alias used by callers to check for the plan-mode toggle sentinel.
  static const shiftTabSentinel = _kShiftTabSentinel;

  // How many lines below the input line are currently occupied by the panel.
  // 0 = no panel painted. Includes the separator line.

  /// Tip shown below the prompt when no suggestions are visible.
  String? _statusTip;

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
    String? statusTip,
    List<String> Function(String buffer)? completer,
    bool cancelOnBreak = true,
    void Function()? onShiftTab,
  }) {
    _statusTip = statusTip;
    var buffer = '';
    var cursorPos = 0;
    _historyIndex = -1;
    String? savedBuffer;
    // Print the prompt once (including any leading newline for spacing).
    // _renderInline uses the inline portion only (no leading newlines).
    stdout.write(prompt);
    final inlinePrompt = prompt.replaceFirst(RegExp(r'^\n+'), '');

    // Which candidate the inline ghost is showing; Tab cycles through them.
    // There is no separate list to focus, so the arrow keys are free to mean
    // history again.
    var candidateIndex = 0;
    var lastCandidates = <String>[];

    while (true) {
      if (completer != null) {
        // Cap the cycle: tabbing through hundreds of ids is worse than none.
        final fresh = completer(buffer).take(_maxSuggestions).toList();
        // Keep the cycle position only while the candidate set is unchanged.
        if (fresh.length != lastCandidates.length ||
            (fresh.isNotEmpty &&
                lastCandidates.isNotEmpty &&
                fresh.first != lastCandidates.first)) {
          candidateIndex = 0;
        }
        lastCandidates = fresh;
      }
      final candidates = lastCandidates;

      _renderInline(
        inlinePrompt,
        buffer,
        cursorPos,
        candidates,
        candidateIndex,
      );

      final key = _console.readKey();

      // ── Arrow-Down ──────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.arrowDown) {
        if (_historyIndex != -1) {
          _historyIndex++;
          if (_historyIndex >= _history.length) {
            _historyIndex = -1;
            buffer = savedBuffer ?? '';
          } else {
            buffer = _history[_historyIndex];
          }
          cursorPos = buffer.length;
        }
        continue;
      }

      // ── Arrow-Up ────────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.arrowUp) {
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
        continue;
      }

      // ── Enter ───────────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.enter) {
        // Submit exactly what is typed; Tab accepts a suggestion.
        _clearInline(inlinePrompt, buffer, cursorPos);
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
        // Dismiss the hint; it returns on the next edit.
        lastCandidates = [];
        candidateIndex = 0;
        continue;
      }

      // ── Ctrl-C ──────────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.ctrlC) {
        if (cancelOnBreak) {
          _clearInline(inlinePrompt, buffer, cursorPos);
          _console.writeLine();
          return null;
        }
        continue;
      }

      // ── Tab ─────────────────────────────────────────────────────────────────
      if (key.isControl && key.controlChar == ControlCharacter.tab) {
        if (candidates.isNotEmpty) {
          final shown =
              candidates[candidateIndex.clamp(0, candidates.length - 1)];
          if (buffer == shown && candidates.length > 1) {
            // Already accepted this one — offer the next.
            candidateIndex = (candidateIndex + 1) % candidates.length;
            buffer = candidates[candidateIndex];
          } else {
            buffer = shown;
          }
          cursorPos = buffer.length;
          // Tab counts as typing — leave history mode.
          _historyIndex = -1;
          savedBuffer = null;
        }
        continue;
      }

      // ── Shift+Tab — toggle plan mode ─────────────────────────────────────────
      // Terminals send ESC [ Z (backtab) for Shift+Tab. dart_console delivers
      // unrecognised escape sequences through the printable-char path with the
      // raw bytes in key.char. Match both the full sequence and the suffix
      // variant to cover xterm/VTE differences.
      if (!key.isControl && (key.char == '\x1b[Z' || key.char.endsWith('[Z'))) {
        _clearInline(inlinePrompt, buffer, cursorPos);
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

  // ── Inline rendering ────────────────────────────────────────────────────────

  /// Draws the input line and, when a completion is available, the remainder of
  /// the top candidate as dim inline text after the cursor.
  ///
  /// Everything is written on the prompt's own line. The previous design drew a
  /// separator and suggestion rows *below* the prompt using real newlines and
  /// then restored the cursor with `\x1b[s` / `\x1b[u`. Near the bottom of the
  /// terminal those newlines scroll the screen, and a restore cannot undo a
  /// scroll — so the saved position was stale and every repaint left another
  /// separator and row in the scrollback. Staying on one line removes that
  /// failure mode by construction rather than trying to manage it.
  void _renderInline(
    String prompt,
    String buffer,
    int cursorPos,
    List<String> candidates,
    int candidateIndex,
  ) {
    // Erase the line and redraw the prompt and what the user has typed.
    stdout.write('\r\x1b[K$prompt$buffer');

    var trailing = 0;
    if (candidates.isNotEmpty) {
      final top = candidates[candidateIndex.clamp(0, candidates.length - 1)];
      // Show only the part not yet typed, so the ghost reads as a continuation.
      final ghost = top.startsWith(buffer) ? top.substring(buffer.length) : '';
      final counter = candidates.length > 1
          ? '  (${candidateIndex + 1}/${candidates.length} · tab)'
          : (ghost.isNotEmpty ? '  (tab)' : '');
      final suffix = '$ghost$counter';
      if (suffix.isNotEmpty) {
        stdout.write('\x1b[2m$suffix\x1b[0m');
        trailing = suffix.length;
      }
    } else if (buffer.isEmpty && _statusTip != null) {
      // With nothing typed and nothing to complete, the mode tip goes here —
      // it used to occupy its own row below the prompt.
      final tip = '  ${_statusTip!}';
      stdout.write('\x1b[2m$tip\x1b[0m');
      trailing = tip.length;
    }

    // Park the cursor where the user is actually typing.
    final back = (buffer.length - cursorPos) + trailing;
    if (back > 0) stdout.write('\x1b[${back}D');
  }

  /// Clears the inline hint, leaving the typed line intact.
  ///
  /// Nothing is ever drawn below the prompt, so there is no panel to tear down
  /// and no cursor bookkeeping to keep in sync.
  void _clearInline(String prompt, String buffer, int cursorPos) {
    stdout.write('\r\x1b[K$prompt$buffer');
    final back = buffer.length - cursorPos;
    if (back > 0) stdout.write('\x1b[${back}D');
  }
}
