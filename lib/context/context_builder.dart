import '../core/session.dart';
import '../core/types.dart';
import '../providers/provider_interface.dart';
import '../tools/tool_registry.dart';
import 'token_budget.dart';
import 'project_index.dart';
import 'compaction.dart';

/// Builds a CompletionRequest from session state with budget-aware compaction.
class ContextBuilder {
  final ToolRegistry _toolRegistry;
  final int _contextWindow;

  ContextBuilder(this._toolRegistry, {int contextWindow = 200000})
    : _contextWindow = contextWindow;

  Future<CompletionRequest> build(
    ProximaSession session,
    ProjectIndex projectIndex,
  ) async {
    final budget = TokenBudget.calculate(_contextWindow);

    // Build system prompt.
    final systemPrompt = _buildSystemPrompt(session, projectIndex, budget);

    // Get tool definitions.
    final tools = _toolRegistry
        .all()
        .map(
          (t) => ToolDefinition(
            name: t.name,
            description: t.description,
            inputSchema: t.inputSchema,
          ),
        )
        .toList();

    // Compact history.
    final latestUserMessage =
        session.history
            .where((m) => m.role == MessageRole.user)
            .lastOrNull
            ?.content ??
        '';

    final compactedHistory = Compaction.compact(
      session.history,
      budget,
      latestUserMessage,
      fileCache: session.fileCache,
    );

    return CompletionRequest(
      model: session.model,
      systemPrompt: systemPrompt,
      messages: compactedHistory,
      tools: tools,
      maxTokens: budget.outputHeadroom,
      temperature: 0.0,
    );
  }

  String _buildSystemPrompt(
    ProximaSession session,
    ProjectIndex projectIndex,
    TokenBudget budget,
  ) {
    final buf = StringBuffer();

    // A — Identity
    buf.writeln(
      'You are Proxima, a terminal-native coding agent operating with explicit human oversight.',
    );
    buf.writeln(
      'You help users understand, navigate, and modify codebases through structured tool execution.',
    );
    buf.writeln(
      'Always reason before acting. Use tools to gather information before making changes.',
    );
    buf.writeln('');

    // B — Operating rules
    buf.writeln('Rules (follow in order):');
    buf.writeln(
      '1. Always read before writing. Never patch a file you have not read this session.',
    );
    buf.writeln(
      '2. Use patch_file for targeted edits. Use write_file only for new files or full rewrites.',
    );
    buf.writeln('3. After any write, verify with read_file.');
    buf.writeln(
      '4. When a tool returns an error, diagnose before retrying — re-read the target file.',
    );
    buf.writeln(
      '5. Do not call the same tool with identical args more than twice. If stuck, emit clarify.',
    );
    buf.writeln(
      '6. In safe mode, only use: read_file, list_files, glob, search, git_status, git_diff, git_log.',
    );
    buf.writeln(
      '7. After run_tests failures: read the failing test → read the implementation → patch → re-test. Maximum 3 fix/verify cycles.',
    );
    buf.writeln('');

    // C — Project context + session state
    buf.writeln('Session mode: ${session.mode.name}');
    buf.writeln(
      'Tokens used this session: ${session.cumulativeUsage.totalTokens} / ${budget.total}',
    );
    buf.writeln('');
    buf.writeln(projectIndex.toPromptText());

    if (session.isPlanMode) {
      buf.writeln('');
      buf.writeln(
        'You are in PLAN MODE. Your task is to research the codebase and produce a structured',
      );
      buf.writeln(
        'implementation plan — do NOT write, patch, or execute any code yet.',
      );
      buf.writeln('');
      buf.writeln(
        'Use read_file, search, search_symbol, glob, and list_files to understand the codebase.',
      );
      buf.writeln(
        'When you have a complete picture, call write_plan with the full plan in markdown format.',
      );
      buf.writeln('');
      buf.writeln('Your plan must include:');
      buf.writeln('1. Context: what exists, what needs to change, and why');
      buf.writeln(
        '2. Step-by-step changes: exact files, methods, and logic (implementation-ready)',
      );
      buf.writeln(
        '3. Tests: what new tests to write and what existing tests to update',
      );
      buf.writeln(
        '4. Risks: edge cases, breaking changes, backwards-compatibility concerns',
      );
      buf.writeln('');
      buf.writeln(
        'Be specific enough that the plan can be executed without any additional research.',
      );
    }

    return buf.toString();
  }
}

extension _IterableExtension<T> on Iterable<T> {
  T? get lastOrNull {
    T? last;
    for (final element in this) {
      last = element;
    }
    return last;
  }
}
