import 'dart:async';
import 'dart:io';
import 'ansi_helpers.dart';

/// Async terminal spinner.
class Spinner {
  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  static const _interval = Duration(milliseconds: 80);

  final String message;
  Timer? _timer;
  int _frame = 0;
  bool _active = false;

  Spinner(this.message);

  void start() {
    if (_active) return;
    _active = true;
    _frame = 0;
    _timer = Timer.periodic(_interval, (_) => _tick());
  }

  void _tick() {
    if (!_active) return;
    final frame = cyan(_frames[_frame % _frames.length]);
    stdout.write('\r$frame ${dim(message)}');
    _frame++;
  }

  void stop({String? finalMessage}) {
    if (!_active) return;
    _active = false;
    _timer?.cancel();
    _timer = null;
    stdout.write('\r\x1b[K'); // Clear line.
    if (finalMessage != null) {
      stdout.writeln(finalMessage);
    }
  }
}
