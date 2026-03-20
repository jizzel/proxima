import 'dart:io';
import 'package:dart_console/dart_console.dart';
import '../core/types.dart';
import 'ansi_helpers.dart';
import 'diff_renderer.dart';

/// Interactive permission prompts.
class PermissionPrompt {
  /// Show confirm prompt (y/n/s/o) for confirm-level tools.
  /// Returns true if approved.
  static Future<bool> confirm(
    ToolCall toolCall,
    RiskLevel riskLevel, {
    String? diffText,
  }) async {
    final riskLabel = switch (riskLevel) {
      RiskLevel.confirm => yellow('[CONFIRM]'),
      RiskLevel.highRisk => boldRed('[HIGH RISK]'),
      _ => gray('[${riskLevel.name.toUpperCase()}]'),
    };

    stdout.writeln('');
    stdout.writeln('$riskLabel ${bold(toolCall.tool)}');
    if (toolCall.reasoning.isNotEmpty) {
      stdout.writeln(dim('  Reasoning: ${toolCall.reasoning}'));
    }
    stdout.writeln(dim('  Args: ${toolCall.args}'));

    if (diffText != null && diffText.isNotEmpty) {
      stdout.writeln('');
      stdout.writeln(DiffRenderer.render(diffText));
    }

    if (riskLevel == RiskLevel.highRisk) {
      return await _highRiskPrompt();
    }

    return _confirmPrompt();
  }

  /// Single-keypress confirm: y/o = allow, n/s = deny.
  /// Works correctly in raw mode (dart_console's Console.readKey()).
  static bool _confirmPrompt() {
    final console = Console.scrolling();
    while (true) {
      stdout.write(bold('Allow? [y]es / [n]o / [s]kip / [o]nce: '));
      final key = console.readKey();

      // Echo the pressed key so the user can see what they chose.
      final char = key.isControl ? '' : key.char;
      stdout.writeln(char);

      if (key.isControl) {
        switch (key.controlChar) {
          case ControlCharacter.ctrlC:
            return false;
          default:
            continue;
        }
      }

      switch (key.char.toLowerCase()) {
        case 'y':
        case 'o':
          return true;
        case 'n':
        case 's':
          return false;
        default:
          stdout.writeln(dim('  Press y, n, s, or o'));
      }
    }
  }

  /// High-risk requires typing "CONFIRM" — uses line input since raw-mode
  /// single-keypress is impractical for a multi-character confirmation word.
  /// Temporarily restores line-buffered input for this prompt only.
  static Future<bool> _highRiskPrompt() async {
    stdout.writeln('');
    stdout.writeln(boldRed('⚠️  HIGH RISK OPERATION'));
    stdout.writeln(
      red('Type "CONFIRM" to proceed, or anything else to cancel:'),
    );
    stdout.write('> ');
    // stdin.readLineSync works here because high-risk prompts are rare and
    // the user is expected to type a full word — single-keypress is not enough.
    final input = stdin.readLineSync()?.trim() ?? '';
    return input == 'CONFIRM';
  }
}
