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
    buf.writeln('You are Proxima, a terminal-native coding agent.');
    buf.writeln('You help users understand, navigate, and modify codebases.');
    buf.writeln('');
    buf.writeln('Rules:');
    buf.writeln('- Always reason before using a tool.');
    buf.writeln('- Use tools to gather information before making changes.');
    buf.writeln(
      '- Prefer targeted edits (patch_file) over full rewrites (write_file).',
    );
    buf.writeln('- When done, give a clear final answer.');
    buf.writeln('');
    buf.writeln(projectIndex.toPromptText());
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
