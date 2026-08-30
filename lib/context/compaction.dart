import '../core/types.dart';
import 'token_budget.dart';

/// Estimates token count for a string (rough: 1 token ≈ 4 chars).
int estimateTokens(String text) => (text.length / 4).ceil();

/// Three-pass context compaction strategy.
/// Summarises a run of messages that is about to be dropped.
///
/// Returns null when no summary is available, in which case the caller falls
/// back to plain truncation.
typedef HistorySummarizer = Future<String?> Function(List<Message> dropped);

/// Tokens held back from the history budget for an injected summary.
///
/// Matches `SubagentRunner.runSummarizer`'s default `maxTokens`, so a summary
/// of the maximum size still fits inside the space reserved for it.
const int summaryReserveTokens = 512;

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
    int maxHistoryTokens, {
    List<Message>? dropped,
  }) {
    var total = messages.fold(0, (sum, m) => sum + estimateTokens(m.content));

    if (total <= maxHistoryTokens) return messages;

    // Drop oldest user/assistant pairs from the front.
    final result = List<Message>.from(messages);
    while (total > maxHistoryTokens && result.length > 2) {
      final removed = result.removeAt(0);
      dropped?.add(removed);
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

  /// Deduplicate read_file tool results using the session file cache.
  /// Only the most recent read of each canonical path is kept verbatim;
  /// older reads are replaced with a placeholder to save tokens.
  static List<Message> deduplicateFileReads(
    List<Message> messages,
    Map<String, String> fileCache,
  ) {
    if (fileCache.isEmpty) return messages;

    // Track which path we've seen the latest read for (scanning in reverse).
    final seenLatest = <String>{};
    // Map from message index → replacement content.
    final replacements = <int, String>{};

    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.role != MessageRole.tool || m.toolName != 'read_file') continue;
      // Check the preceding assistant message for the path arg.
      if (i == 0) continue;
      final assistantMsg = messages[i - 1];
      if (assistantMsg.role != MessageRole.assistant) continue;
      final path = assistantMsg.toolInput?['path'] as String?;
      if (path == null) continue;

      if (!seenLatest.contains(path)) {
        seenLatest.add(path); // keep this one verbatim
      } else {
        replacements[i] =
            '[File already in context — see most recent read above]';
      }
    }

    if (replacements.isEmpty) return messages;

    return [
      for (var i = 0; i < messages.length; i++)
        replacements.containsKey(i)
            ? messages[i].copyWith(content: replacements[i]!)
            : messages[i],
    ];
  }

  /// Apply all passes in sequence.
  ///
  /// When [summarizer] is supplied and Pass 2 has to discard messages, the
  /// discarded run is summarised and the summary pinned to the front of the
  /// history, so the model keeps the gist of what it can no longer see.
  /// Without a summarizer — tests, offline use, a failed call — behaviour is
  /// exactly the plain truncation it has always been.
  static Future<List<Message>> compact(
    List<Message> messages,
    TokenBudget budget,
    String query, {
    Map<String, String> fileCache = const {},
    HistorySummarizer? summarizer,
  }) async {
    var result = deduplicateFileReads(messages, fileCache);
    result = pruneToolResults(result, budget.toolResults ~/ 4);

    // Decide against the *real* budget first. Reserving unconditionally would
    // discard messages — and pay for a summary — for histories that already
    // fit, and would retain less than plain truncation if the summary failed.
    final fitsAsIs =
        result.fold(0, (sum, m) => sum + estimateTokens(m.content)) <=
        budget.conversationHistory;
    final reserve = (summarizer == null || fitsAsIs) ? 0 : summaryReserveTokens;

    final dropped = <Message>[];
    result = truncateHistory(
      result,
      budget.conversationHistory - reserve,
      dropped: dropped,
    );

    if (summarizer != null && dropped.isNotEmpty) {
      // A summarisation failure must never fail the turn — it costs context,
      // not correctness, so fall back to the plain truncation already applied.
      String? summary;
      try {
        summary = await summarizer(dropped);
      } catch (_) {
        summary = null;
      }
      if (summary != null && summary.trim().isNotEmpty) {
        // Clip a summary that overruns its reserve — the model is asked for
        // 3-5 bullets but is not bound by that. The prefix counts against the
        // reserve too, or the injected message overshoots by its length.
        const prefix =
            '[Earlier context summary — the messages it covers have been '
            'dropped to stay within budget]\n';
        final maxChars = (summaryReserveTokens * 4) - prefix.length;
        final clipped = summary.length > maxChars
            ? '${summary.substring(0, maxChars)}…'
            : summary;
        // Filter *before* prepending: the summary stands in for messages that
        // are already gone, so it must not compete with retained ones for a
        // slot in the top-N.
        result = relevanceFilter(result, query, 100);
        return [
          Message(role: MessageRole.user, content: '$prefix$clipped'),
          ...result,
        ];
      }
    }

    result = relevanceFilter(result, query, 100);
    return result;
  }
}
