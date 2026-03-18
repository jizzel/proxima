import '../core/types.dart';
import 'token_budget.dart';

/// Estimates token count for a string (rough: 1 token ≈ 4 chars).
int estimateTokens(String text) => (text.length / 4).ceil();

/// Three-pass context compaction strategy.
class Compaction {
  /// Pass 1: Prune large tool results that exceed the per-result budget.
  static List<Message> pruneToolResults(
    List<Message> messages,
    int maxResultTokens,
  ) {
    return messages.map((m) {
      if (m.role != MessageRole.tool) return m;
      final tokens = estimateTokens(m.content);
      if (tokens <= maxResultTokens) return m;

      final truncated = m.content.substring(
        0,
        (maxResultTokens * 4).clamp(0, m.content.length),
      );
      return m.copyWith(content: '$truncated\n[... truncated]');
    }).toList();
  }

  /// Pass 2: If history still exceeds budget, drop oldest exchanges.
  /// Falls back to truncation immediately if anything goes wrong.
  static List<Message> truncateHistory(
    List<Message> messages,
    int maxHistoryTokens,
  ) {
    var total = messages.fold(0, (sum, m) => sum + estimateTokens(m.content));

    if (total <= maxHistoryTokens) return messages;

    // Drop oldest user/assistant pairs from the front.
    final result = List<Message>.from(messages);
    while (total > maxHistoryTokens && result.length > 2) {
      final removed = result.removeAt(0);
      total -= estimateTokens(removed.content);
    }

    return result;
  }

  /// Pass 3: Score messages by relevance to [query], keep top N.
  static List<Message> relevanceFilter(
    List<Message> messages,
    String query,
    int maxMessages,
  ) {
    if (messages.length <= maxMessages) return messages;

    // Always keep the most recent [maxMessages/2] messages.
    final keepRecent = maxMessages ~/ 2;
    final recent = messages.sublist(messages.length - keepRecent);
    final older = messages.sublist(0, messages.length - keepRecent);

    // Score older messages by keyword overlap with query.
    final queryWords = query.toLowerCase().split(RegExp(r'\W+')).toSet();
    final scored = older.map((m) {
      final words = m.content.toLowerCase().split(RegExp(r'\W+')).toSet();
      final overlap = words.intersection(queryWords).length;
      return (message: m, score: overlap);
    }).toList()..sort((a, b) => b.score.compareTo(a.score));

    final topOlder = scored
        .take(maxMessages - keepRecent)
        .map((s) => s.message)
        .toList();

    // Re-sort to maintain chronological order.
    final allKept = [...topOlder, ...recent];
    final originalOrder = {
      for (var i = 0; i < messages.length; i++) messages[i]: i,
    };
    allKept.sort(
      (a, b) => (originalOrder[a] ?? 0).compareTo(originalOrder[b] ?? 0),
    );

    return allKept;
  }

  /// Apply all three passes in sequence.
  static List<Message> compact(
    List<Message> messages,
    TokenBudget budget,
    String query,
  ) {
    var result = pruneToolResults(messages, budget.toolResults ~/ 4);
    result = truncateHistory(result, budget.conversationHistory);
    result = relevanceFilter(result, query, 100);
    return result;
  }
}
