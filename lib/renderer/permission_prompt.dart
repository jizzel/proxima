import 'dart:io';
import '../core/types.dart';
import 'ansi_helpers.dart';
import 'diff_renderer.dart';

/// Interactive permission prompts.
class PermissionPrompt {
  /// Show confirm prompt (y/n/e/s/a) for confirm-level tools.
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

    return await _confirmPrompt();
  }

  static Future<bool> _confirmPrompt() async {
    while (true) {
      stdout.write(bold('Allow? [y/n/s(kip)/o(nce)] '));
      final input = stdin.readLineSync()?.trim().toLowerCase() ?? 'n';
      switch (input) {
        case 'y':
        case 'yes':
          return true;
        case 'n':
        case 'no':
          return false;
        case 's':
        case 'skip':
          return false; // skip = deny for now
        case 'o':
        case 'once':
          return true;
        default:
          stdout.writeln(dim('  Enter y, n, s, or o'));
      }
    }
  }

  static Future<bool> _highRiskPrompt() async {
    stdout.writeln('');
    stdout.writeln(boldRed('⚠️  HIGH RISK OPERATION'));
    stdout.writeln(
      red('Type "CONFIRM" to proceed, or anything else to cancel:'),
    );
    stdout.write('> ');
    final input = stdin.readLineSync()?.trim() ?? '';
    return input == 'CONFIRM';
  }
}
