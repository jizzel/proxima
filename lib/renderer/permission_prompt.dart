import 'dart:io';
import '../agent/subagent_runner.dart' show CriticResult, CriticVerdict;
import '../core/types.dart';
import 'ansi_helpers.dart';
import 'diff_renderer.dart';
import 'picker_widget.dart';

/// Interactive permission prompts.
class PermissionPrompt {
  /// Show confirm prompt (y/n/s/o) for confirm-level tools.
  /// Returns true if approved.
  static Future<bool> confirm(
    ToolCall toolCall,
    RiskLevel riskLevel, {
    String? diffText,
    CriticResult? criticResult,
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

    // Critic note — only shown for warn/block_suggestion verdicts.
    if (criticResult != null && !criticResult.isSilent) {
      stdout.writeln('');
      final label = criticResult.verdict == CriticVerdict.blockSuggestion
          ? boldRed('  Critic: BLOCK SUGGESTION')
          : yellow('  Critic: WARN');
      stdout.writeln('$label — ${criticResult.summary}');
      for (final issue in criticResult.issues) {
        final sev = issue.severity == 'high' ? red : yellow;
        final hint = issue.lineHint != null ? dim(' (${issue.lineHint})') : '';
        stdout.writeln('    ${sev("•")} ${issue.description}$hint');
      }
    }

    if (riskLevel == RiskLevel.highRisk) {
      return await _highRiskPrompt();
    }

    return _confirmPrompt();
  }

  static bool _confirmPrompt() {
    final idx = PickerWidget.pick(
      options: ['Approve', 'Deny'],
      hints: ['allow this tool call', 'block this tool call'],
      defaultIndex: 0,
    );
    return idx == 0;
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
