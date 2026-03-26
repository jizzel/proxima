import 'package:test/test.dart';
import 'package:proxima/core/types.dart';
import 'package:proxima/context/compaction.dart';
import 'package:proxima/context/token_budget.dart';

Message userMsg(String content) =>
    Message(role: MessageRole.user, content: content);

Message assistantToolMsg(String tool, Map<String, dynamic> args) => Message(
  role: MessageRole.assistant,
  content: 'reasoning',
  toolName: tool,
  toolCallId: 'call_1',
  toolInput: args,
);

Message toolResultMsg(String tool, String content) =>
    Message(role: MessageRole.tool, content: content, toolName: tool);

void main() {
  group('Compaction.deduplicateFileReads', () {
    test('single read_file — kept verbatim', () {
      final messages = [
        assistantToolMsg('read_file', {'path': 'lib/foo.dart'}),
        toolResultMsg('read_file', 'content of foo'),
      ];
      final result = Compaction.deduplicateFileReads(messages, {
        'lib/foo.dart': 'content of foo',
      });
      expect(result[1].content, 'content of foo');
    });

    test('two reads of same file — older replaced, newer kept', () {
      final messages = [
        assistantToolMsg('read_file', {'path': 'lib/foo.dart'}),
        toolResultMsg('read_file', 'old content'),
        assistantToolMsg('read_file', {'path': 'lib/foo.dart'}),
        toolResultMsg('read_file', 'new content'),
      ];
      final result = Compaction.deduplicateFileReads(messages, {
        'lib/foo.dart': 'new content',
      });
      // First read (index 1) should be replaced.
      expect(result[1].content, contains('[File already in context'));
      // Second read (index 3) is the latest — kept verbatim.
      expect(result[3].content, 'new content');
    });

    test('reads of different files — both kept', () {
      final messages = [
        assistantToolMsg('read_file', {'path': 'lib/a.dart'}),
        toolResultMsg('read_file', 'content a'),
        assistantToolMsg('read_file', {'path': 'lib/b.dart'}),
        toolResultMsg('read_file', 'content b'),
      ];
      final result = Compaction.deduplicateFileReads(messages, {
        'lib/a.dart': 'content a',
        'lib/b.dart': 'content b',
      });
      expect(result[1].content, 'content a');
      expect(result[3].content, 'content b');
    });

    test('non-read_file tool results are untouched', () {
      final messages = [
        assistantToolMsg('run_tests', {}),
        toolResultMsg('run_tests', 'All tests passed.'),
      ];
      final result = Compaction.deduplicateFileReads(messages, {});
      expect(result[1].content, 'All tests passed.');
    });

    test('empty fileCache returns messages unchanged', () {
      final messages = [
        assistantToolMsg('read_file', {'path': 'lib/foo.dart'}),
        toolResultMsg('read_file', 'content'),
      ];
      final result = Compaction.deduplicateFileReads(messages, {});
      expect(result, messages);
    });

    test('tool message not preceded by assistant message is skipped safely', () {
      // Edge case: malformed history where a tool message has no assistant before it.
      final messages = [userMsg('hi'), toolResultMsg('read_file', 'orphaned')];
      // Should not throw; returns messages unchanged.
      final result = Compaction.deduplicateFileReads(messages, {
        'foo.dart': 'x',
      });
      expect(result[1].content, 'orphaned');
    });
  });

  group('Compaction.compact with fileCache', () {
    final budget = TokenBudget.calculate(10000);

    test('passes fileCache through to deduplication', () {
      final messages = [
        userMsg('read foo'),
        assistantToolMsg('read_file', {'path': 'foo.dart'}),
        toolResultMsg('read_file', 'first read'),
        assistantToolMsg('read_file', {'path': 'foo.dart'}),
        toolResultMsg('read_file', 'second read'),
        userMsg('done'),
      ];
      final result = Compaction.compact(
        messages,
        budget,
        'foo',
        fileCache: {'foo.dart': 'second read'},
      );
      // The first read_file result (index 2 in original) should be replaced.
      final toolResults = result
          .where((m) => m.role == MessageRole.tool)
          .toList();
      expect(
        toolResults.any((m) => m.content.contains('[File already')),
        isTrue,
      );
      expect(toolResults.any((m) => m.content == 'second read'), isTrue);
    });

    test('no fileCache — behaves identically to old compact', () {
      final messages = [
        userMsg('hi'),
        Message(role: MessageRole.assistant, content: 'hello'),
      ];
      final result = Compaction.compact(messages, budget, 'hi');
      expect(result.length, 2);
    });
  });

  group('Compaction.pruneToolResults', () {
    test('truncates oversized tool result', () {
      final long = 'x' * 10000;
      final messages = [
        Message(role: MessageRole.tool, content: long, toolName: 't'),
      ];
      final result = Compaction.pruneToolResults(messages, 100);
      expect(result.first.content.length, lessThan(long.length));
      expect(result.first.content, contains('[... truncated]'));
    });

    test('keeps small tool result verbatim', () {
      final messages = [
        Message(role: MessageRole.tool, content: 'short', toolName: 't'),
      ];
      final result = Compaction.pruneToolResults(messages, 1000);
      expect(result.first.content, 'short');
    });
  });

  group('Compaction.truncateHistory', () {
    test('drops oldest messages when over budget', () {
      final messages = [
        for (var i = 0; i < 20; i++)
          Message(role: MessageRole.user, content: 'message $i ' * 50),
      ];
      final result = Compaction.truncateHistory(messages, 200);
      expect(result.length, lessThan(messages.length));
    });

    test('keeps all messages when within budget', () {
      final messages = [
        Message(role: MessageRole.user, content: 'hi'),
        Message(role: MessageRole.assistant, content: 'hello'),
      ];
      final result = Compaction.truncateHistory(messages, 10000);
      expect(result.length, 2);
    });
  });
}
