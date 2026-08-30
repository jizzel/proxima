import 'dart:io';
import 'package:ansi_styles/ansi_styles.dart';

// Color helpers for consistent styling.
String bold(String text) => AnsiStyles.bold(text);
String dim(String text) => AnsiStyles.dim(text);
String green(String text) => AnsiStyles.green(text);
String red(String text) => AnsiStyles.red(text);
String yellow(String text) => AnsiStyles.yellow(text);
String blue(String text) => AnsiStyles.blue(text);
String cyan(String text) => AnsiStyles.cyan(text);
String magenta(String text) => AnsiStyles.magenta(text);
String white(String text) => AnsiStyles.white(text);
String gray(String text) => AnsiStyles.gray(text);
String boldGreen(String text) => AnsiStyles.bold(AnsiStyles.green(text));
String boldRed(String text) => AnsiStyles.bold(AnsiStyles.red(text));
String boldYellow(String text) => AnsiStyles.bold(AnsiStyles.yellow(text));
String boldCyan(String text) => AnsiStyles.bold(AnsiStyles.cyan(text));
String boldBlue(String text) => AnsiStyles.bold(AnsiStyles.blue(text));

/// The terminal width, or [fallback] when it cannot be determined.
///
/// `stdout.terminalColumns` **throws** a `StdoutException` rather than
/// returning a default whenever the size is unavailable — output piped to a
/// file, a CI runner, a PTY opened without a window size. Unguarded, that
/// killed the REPL during header rendering before the first prompt, which is
/// a hard crash for what is only a cosmetic detail.
int terminalWidth({int fallback = 80}) {
  try {
    return stdout.terminalColumns;
  } on StdoutException {
    return fallback;
  }
}

/// The terminal height, or [fallback] when it cannot be determined.
///
/// Throws for the same reasons as [terminalWidth]; see the note there.
int terminalHeight({int fallback = 24}) {
  try {
    return stdout.terminalLines;
  } on StdoutException {
    return fallback;
  }
}
