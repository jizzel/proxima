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
