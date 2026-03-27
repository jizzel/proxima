import 'dart:async';
import 'dart:io';
import '../agent/agent_loop.dart';
import '../agent/subagent_runner.dart' show CriticResult;
import '../core/cost_calculator.dart';
import '../core/types.dart';
import 'ansi_helpers.dart';
import 'spinner.dart';
import 'permission_prompt.dart';
import 'repl_header.dart';
import 'task_summary_renderer.dart';

/// Top-level renderer facade implementing AgentCallbacks.
class Renderer implements AgentCallbacks {
  Spinner? _spinner;
  final bool _debug;
  bool _streamingStarted = false;

  // ── Per-tool state ───────────────────────────────────────────────────────
  String? _pendingLabel;
  DateTime? _toolStartTime;

  // ── Blink animation ──────────────────────────────────────────────────────
  Timer? _blinkTimer;
  int _blinkPhase = 0;
  static const _blinkDots = ['', '.', '..', '...'];

  // ── Turn timing ──────────────────────────────────────────────────────────
  DateTime? _turnStartTime;

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
    hideSpinner();
    if (_debug) {
      stdout.writeln(dim('  ╌ $reasoning'));
    } else {
      final firstLine = _firstLine(reasoning.trim());
      if (firstLine.isNotEmpty) stdout.writeln(dim('  ╌ $firstLine'));
    }
    showSpinner('Working…');
  }

  @override
  void onToolCall(ToolCall toolCall) {
    hideSpinner();
    // In debug mode show detection notice. In normal mode, wait for
    // onToolExecuting (after permission gate) to show the activity line.
    if (_debug) {
      stdout.writeln(dim('  ⚙ ${toolCall.tool} ${_fmtArgs(toolCall.args)}'));
    }
  }

  @override
  void onToolExecuting(ToolCall toolCall) {
    hideSpinner();
    _pendingLabel = _activityLabel(toolCall);
    _toolStartTime = DateTime.now();
    stdout.write('  ${cyan("◆")} ${dim(_pendingLabel!)}');
    _startBlinkTimer();
  }

  @override
  void onToolResult(String toolName, String result, bool isError) {
    _stopBlinkTimer();
    hideSpinner();
    stdout.write('\r\x1b[K'); // erase the executing line

    final elapsed = _toolStartTime != null
        ? '  ${_fmtElapsed(DateTime.now().difference(_toolStartTime!))}'
        : '';
    _toolStartTime = null;

    final label = _pendingLabel ?? toolName;
    _pendingLabel = null;

    if (isError) {
      stdout.writeln(
        '  ${red("✗")} ${dim(label)}  ${red(_firstLine(result))}${dim(elapsed)}',
      );
    } else {
      final summary = _resultSummary(toolName, result);
      final summaryPart = summary.isNotEmpty ? '  ${dim(summary)}' : '';
      stdout.writeln('  ${dim("✓")} ${dim(label)}$summaryPart${dim(elapsed)}');
    }
  }

  @override
  void onFinalResponse(String text) {
    _streamingStarted = false;
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
    stdout.writeln('  ${cyan("?")} $question');
    stdout.writeln('');
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
    if (_spinner != null) hideSpinner();
    if (!_streamingStarted) {
      _streamingStarted = true;
      stdout.write('\n');
    }
    stdout.write(text);
  }

  @override
  void onUsageReport(
    TokenUsage turn,
    TokenUsage cumulative,
    double turnCost,
    double sessionCost,
  ) {
    final costPart = sessionCost > 0
        ? '  cost: ${CostCalculator.format(sessionCost)}'
        : '';
    final timePart = _turnStartTime != null
        ? '  ${_fmtElapsed(DateTime.now().difference(_turnStartTime!))}'
        : '';
    _turnStartTime = null;
    stdout.writeln(
      dim(
        '  ↑${turn.inputTokens} ↓${turn.outputTokens}  total: ${cumulative.totalTokens}$timePart$costPart',
      ),
    );
  }

  @override
  void onIterationStart(int iteration, int maxIterations) {
    if (iteration == 1) _turnStartTime = DateTime.now();
    showSpinner('Thinking… [$iteration/$maxIterations]');
  }

  /// Show permission prompt and return decision.
  Future<bool> promptPermission(
    ToolCall toolCall,
    RiskLevel riskLevel, {
    String? diffText,
    CriticResult? criticResult,
  }) async {
    hideSpinner();
    return PermissionPrompt.confirm(
      toolCall,
      riskLevel,
      diffText: diffText,
      criticResult: criticResult,
    );
  }

  void print(String text) => stdout.writeln(text);
  void printDim(String text) => stdout.writeln(dim(text));
  void printSuccess(String text) => TaskSummaryRenderer.renderSuccess(text);
  void printError(String text) => stdout.writeln(red(text));

  // ── Blink timer ─────────────────────────────────────────────────────────────

  void _startBlinkTimer() {
    _blinkTimer?.cancel();
    _blinkPhase = 0;
    _blinkTimer = Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _blinkTick(),
    );
  }

  void _blinkTick() {
    if (_pendingLabel == null) return;
    _blinkPhase = (_blinkPhase + 1) % _blinkDots.length;
    stdout.write(
      '\r\x1b[K  ${cyan("◆")} ${dim(_pendingLabel!)}${dim(_blinkDots[_blinkPhase])}',
    );
  }

  void _stopBlinkTimer() {
    _blinkTimer?.cancel();
    _blinkTimer = null;
  }

  String _fmtElapsed(Duration d) {
    if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
    return '${(d.inMilliseconds / 1000.0).toStringAsFixed(1)}s';
  }

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

  String _activityLabel(ToolCall toolCall) {
    final args = toolCall.args;
    final path = args['path'] as String?;
    final rel = path != null ? _shortPath(path) : null;
    return switch (toolCall.tool) {
      'read_file' => rel != null ? 'Reading $rel…' : 'Reading file…',
      'write_file' => rel != null ? 'Writing $rel…' : 'Writing file…',
      'patch_file' => rel != null ? 'Patching $rel…' : 'Patching file…',
      'delete_file' => rel != null ? 'Deleting $rel…' : 'Deleting file…',
      'list_files' => rel != null ? 'Listing $rel…' : 'Listing files…',
      'glob' => () {
        final pat = args['pattern'] as String? ?? '**/*';
        final base = args['base'] as String?;
        return base != null ? 'Globbing $pat in $base…' : 'Globbing $pat…';
      }(),
      'search' => () {
        final pat = args['pattern'] as String? ?? '';
        final sp = args['path'] as String?;
        final short = pat.length > 30 ? '${pat.substring(0, 30)}…' : pat;
        return sp != null
            ? "Searching for '$short' in $sp…"
            : "Searching for '$short'…";
      }(),
      'search_symbol' => () {
        final sym = args['symbol'] as String? ?? '';
        final kind = args['kind'] as String?;
        return (kind != null && kind != 'any')
            ? "Finding $kind '$sym'…"
            : "Finding symbol '$sym'…";
      }(),
      'run_command' => () {
        final cmd = args['command'] as String? ?? '';
        final short = cmd.length > 40 ? '${cmd.substring(0, 40)}…' : cmd;
        return 'Running: $short…';
      }(),
      'run_tests' => 'Running tests…',
      'git_status' => 'Checking git status…',
      'git_diff' => 'Diffing git changes…',
      'git_log' => 'Viewing git log…',
      'git_add' => rel != null ? 'Staging $rel…' : 'Staging files…',
      'git_commit' => () {
        final msg = args['message'] as String? ?? '';
        final short = msg.length > 30 ? '${msg.substring(0, 30)}…' : msg;
        return "Committing: '$short'…";
      }(),
      'git_reset' => 'Resetting git…',
      'delegate_to_subagent' => () {
        final agent = args['agent'] as String? ?? 'subagent';
        return 'Delegating to $agent…';
      }(),
      _ => '${toolCall.tool} ${_fmtArgs(toolCall.args)}',
    };
  }

  String _shortPath(String path) {
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    if (parts.length <= 2) return path;
    return '${parts[parts.length - 2]}/${parts.last}';
  }

  String _resultSummary(String toolName, String result) {
    switch (toolName) {
      case 'read_file':
        final lineCount = '\n'.allMatches(result).length + 1;
        return '($lineCount lines)';
      case 'write_file':
        return result.startsWith('Created') ? 'created' : 'written';
      case 'patch_file':
        return 'patched';
      case 'delete_file':
        return 'deleted';
      case 'search':
        if (result.startsWith('No matches') ||
            result.startsWith('No results')) {
          return 'no matches';
        }
        final matchCount = RegExp(
          r'^\s+\d+> ',
          multiLine: true,
        ).allMatches(result).length;
        final fileBlocks = result.split('\n---\n').length;
        return '$matchCount match${matchCount == 1 ? "" : "es"} in $fileBlocks file${fileBlocks == 1 ? "" : "s"}';
      case 'search_symbol':
        if (result.startsWith('No definitions')) return 'not found';
        final count = '\n'.allMatches(result).length + 1;
        return '$count definition${count == 1 ? "" : "s"}';
      case 'run_command':
        final m = RegExp(r'Exit code: (\d+)').firstMatch(result);
        if (m != null) {
          final code = m.group(1)!;
          return code == '0' ? 'exited 0' : 'exited $code (error)';
        }
        return '';
      case 'run_tests':
        final first = _firstLine(result);
        if (first.contains('passed') || first.contains('failed')) return first;
        return '';
      default:
        return '';
    }
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
