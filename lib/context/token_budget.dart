/// Token budget allocation across different usage categories.
class TokenBudget {
  final int total;
  final int systemPrompt;
  final int projectIndex;
  final int activeFiles;
  final int conversationHistory;
  final int toolResults;
  final int outputHeadroom;
  final int safetyMargin;

  const TokenBudget({
    required this.total,
    required this.systemPrompt,
    required this.projectIndex,
    required this.activeFiles,
    required this.conversationHistory,
    required this.toolResults,
    required this.outputHeadroom,
    required this.safetyMargin,
  });

  /// Calculate budget from a context window size.
  /// Percentages: system(3%), index(2%), files(18%), history(35%),
  ///              tools(18%), output(10%), safety(14%)
  factory TokenBudget.calculate(int contextWindow) {
    return TokenBudget(
      total: contextWindow,
      systemPrompt: (contextWindow * 0.03).round(),
      projectIndex: (contextWindow * 0.02).round(),
      activeFiles: (contextWindow * 0.18).round(),
      conversationHistory: (contextWindow * 0.35).round(),
      toolResults: (contextWindow * 0.18).round(),
      outputHeadroom: (contextWindow * 0.10).round(),
      safetyMargin: (contextWindow * 0.14).round(),
    );
  }

  /// Tokens available for actual content (excluding output headroom and safety).
  int get available => total - outputHeadroom - safetyMargin;

  @override
  String toString() =>
      'TokenBudget(total=$total, history=$conversationHistory, '
      'files=$activeFiles, tools=$toolResults)';
}
