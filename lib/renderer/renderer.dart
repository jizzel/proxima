import 'dart:io';
import '../core/types.dart';
import '../agent/agent_loop.dart';
import 'ansi_helpers.dart';
import 'spinner.dart';
import 'permission_prompt.dart';
import 'repl_header.dart';
import 'task_summary_renderer.dart';

/// Top-level renderer facade implementing AgentCallbacks.
class Renderer implements AgentCallbacks {
  Spinner? _spinner;
  final bool _debug;

  Renderer({bool debug = false}) : _debug = debug;

  void printHeader({
    required String model,
    required String workingDir,
    required String version,
  }) {
    stdout.write(
      ReplHeader.render(model: model, workingDir: workingDir, version: version),
    );
  }

  void showSpinner(String message) {
    _spinner?.stop();
    _spinner = Spinner(message);
    _spinner!.start();
  }

  void hideSpinner({String? message}) {
    _spinner?.stop(finalMessage: message);
    _spinner = null;
  }

  @override
  void onThinking(String reasoning) {
    if (!_debug) return; // hide reasoning unless debug mode
    hideSpinner();
    stdout.writeln(dim('  ╌ $reasoning'));
  }

  @override
  void onToolCall(ToolCall toolCall) {
    hideSpinner();
    // Single line: "  ⚙ tool_name  args…" — will be updated in onToolResult.
    final argsPreview = _debug ? dim('  ${_fmtArgs(toolCall.args)}') : '';
    stdout.write('  ${dim("⚙")} ${dim(toolCall.tool)}$argsPreview');
  }

  @override
  void onToolResult(String toolName, String result, bool isError) {
    hideSpinner();
    if (isError) {
      // Overwrite the pending "  ⚙ name" line with a red error.
      stdout.write('\r\x1b[K');
      stdout.writeln(
        '  ${red("✗")} ${dim(toolName)}  ${red(_firstLine(result))}',
      );
    } else {
      // Overwrite with a quiet success tick — no second line.
      stdout.write('\r\x1b[K');
      if (_debug) {
        final preview = result.length > 120
            ? '${result.substring(0, 120)}…'
            : result;
        stdout.writeln('  ${dim("✓")} ${dim(toolName)}  ${dim(preview)}');
      } else {
        stdout.writeln('  ${dim("✓ $toolName")}');
      }
    }
  }

  @override
  void onFinalResponse(String text) {
    hideSpinner();
    stdout.writeln('');
    stdout.writeln(_renderMarkdown(text));
    // Dim rule to visually close the turn.
    try {
      final w = stdout.terminalColumns.clamp(20, 80);
      stdout.writeln(dim('─' * w));
    } catch (_) {}
  }

  @override
  void onClarify(String question) {
    hideSpinner();
    stdout.writeln('');
    stdout.writeln(bold(question));
  }

  @override
  void onError(String message) {
    hideSpinner();
    stdout.writeln(red('  ⚠ $message'));
  }

  @override
  Future<bool> onStuck(List<ToolCall> recentCalls) async {
    hideSpinner();
    return TaskSummaryRenderer.renderStuck(recentCalls);
  }

  @override
  void onChunk(String text) {
    stdout.write(text);
  }

  /// Show permission prompt and return decision.
  Future<bool> promptPermission(
    ToolCall toolCall,
    RiskLevel riskLevel, {
    String? diffText,
  }) async {
    hideSpinner();
    return PermissionPrompt.confirm(toolCall, riskLevel, diffText: diffText);
  }

  void print(String text) => stdout.writeln(text);
  void printDim(String text) => stdout.writeln(dim(text));
  void printSuccess(String text) => TaskSummaryRenderer.renderSuccess(text);
  void printError(String text) => stdout.writeln(red(text));

  // ── Markdown renderer ───────────────────────────────────────────────────────

  /// Minimal terminal markdown: headers, bold, italic, inline code,
  /// code fences, bullet lists. Good enough for LLM output.
  String _renderMarkdown(String text) {
    final lines = text.split('\n');
    final buf = StringBuffer();
    bool inFence = false;
    String fenceIndent = '';

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];

      // Code fence open/close.
      if (line.trimLeft().startsWith('```')) {
        if (!inFence) {
          inFence = true;
          fenceIndent = '  ';
          // Show language hint dimmed if present.
          final lang = line.trim().substring(3).trim();
          if (lang.isNotEmpty) buf.writeln(dim('  [$lang]'));
        } else {
          inFence = false;
          fenceIndent = '';
        }
        continue;
      }

      if (inFence) {
        buf.writeln(cyan('$fenceIndent$line'));
        continue;
      }

      // ATX headers.
      final headerMatch = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(line);
      if (headerMatch != null) {
        final level = headerMatch.group(1)!.length;
        final title = headerMatch.group(2)!;
        buf.writeln(level == 1 ? boldCyan(title) : bold(title));
        continue;
      }

      // Horizontal rules.
      if (RegExp(r'^[-*_]{3,}\s*$').hasMatch(line)) {
        final termWidth = stdout.terminalColumns.clamp(20, 80);
        buf.writeln(dim('─' * termWidth));
        continue;
      }

      // Bullet / task lists.
      final bulletMatch = RegExp(
        r'^(\s*)([-*+]|\d+\.)\s+(.+)$',
      ).firstMatch(line);
      if (bulletMatch != null) {
        final indent = bulletMatch.group(1)!;
        final content = _inlineMarkdown(bulletMatch.group(3)!);
        buf.writeln('$indent${dim("•")} $content');
        continue;
      }

      // Normal line — apply inline formatting.
      buf.writeln(_inlineMarkdown(line));
    }

    return buf.toString().trimRight();
  }

  String _inlineMarkdown(String text) {
    // Bold+italic ***…***
    text = text.replaceAllMapped(
      RegExp(r'\*\*\*(.+?)\*\*\*'),
      (m) => bold(m.group(1)!),
    );
    // Bold **…**
    text = text.replaceAllMapped(
      RegExp(r'\*\*(.+?)\*\*'),
      (m) => bold(m.group(1)!),
    );
    // Italic *…* or _…_
    text = text.replaceAllMapped(
      RegExp(r'(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)'),
      (m) => '\x1b[3m${m.group(1)!}\x1b[0m',
    );
    // Inline code `…`
    text = text.replaceAllMapped(
      RegExp(r'`([^`]+)`'),
      (m) => cyan(m.group(1)!),
    );
    return text;
  }

  String _firstLine(String s) {
    final nl = s.indexOf('\n');
    return nl == -1 ? s : s.substring(0, nl);
  }

  String _fmtArgs(Map<String, dynamic> args) {
    if (args.isEmpty) return '';
    final pairs = args.entries
        .map((e) {
          final v = e.value.toString();
          final short = v.length > 40 ? '${v.substring(0, 40)}…' : v;
          return '${e.key}=$short';
        })
        .join(' ');
    return pairs;
  }
}
