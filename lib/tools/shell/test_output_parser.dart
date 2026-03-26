/// Structured result from a test run.
class TestResult {
  final bool passed;
  final int totalTests;
  final int failedTests;
  final int skippedTests;
  final List<TestFailure> failures;
  final String rawOutput;

  const TestResult({
    required this.passed,
    required this.totalTests,
    required this.failedTests,
    required this.skippedTests,
    required this.failures,
    required this.rawOutput,
  });

  /// Format a concise summary for the LLM.
  String toPromptText() {
    if (passed) {
      return 'All $totalTests tests passed.';
    }
    final buf = StringBuffer();
    buf.writeln('$failedTests of $totalTests tests failed.');
    for (final f in failures) {
      buf.write('  FAIL: ${f.testName}');
      if (f.filePath != null) {
        buf.write(' (${f.filePath}');
        if (f.lineNumber != null) buf.write(':${f.lineNumber}');
        buf.write(')');
      }
      buf.writeln();
      if (f.message.isNotEmpty) {
        // Indent and truncate long failure messages.
        final lines = f.message.split('\n').take(6);
        for (final line in lines) {
          buf.writeln('    $line');
        }
      }
    }
    return buf.toString().trimRight();
  }
}

/// A single test failure.
class TestFailure {
  final String testName;
  final String? filePath;
  final int? lineNumber;
  final String message;

  const TestFailure({
    required this.testName,
    this.filePath,
    this.lineNumber,
    required this.message,
  });
}

/// Parses raw test runner output into a [TestResult].
class TestOutputParser {
  /// Parse [output] produced by [framework].
  /// Falls back to a best-effort result when parsing is incomplete.
  static TestResult parse(String output, TestFramework framework) {
    return switch (framework) {
      TestFramework.dart => _parseDart(output),
      TestFramework.jest => _parseJest(output),
      TestFramework.pytest => _parsePytest(output),
      TestFramework.cargo => _parseCargo(output),
      TestFramework.go => _parseGo(output),
    };
  }

  // ── Dart / pub test ──────────────────────────────────────────────────────

  static TestResult _parseDart(String output) {
    // Summary line: "Some tests failed." or "All tests passed!"
    // Failure lines: "  FAILED test name" or "00:01 +4 -1: test name [E]"
    final failures = <TestFailure>[];

    // dart test failure lines: "  FAILED description"
    final failLineRe = RegExp(r'^\s+FAILED (.+)$', multiLine: true);
    for (final m in failLineRe.allMatches(output)) {
      failures.add(TestFailure(testName: m.group(1)!.trim(), message: ''));
    }

    // dart test progress line: "00:01 +5 -2: ..." — extract counts from summary
    int total = 0;
    int failed = 0;
    int skipped = 0;

    // "All X tests passed!" pattern
    final allPassedRe = RegExp(r'All (\d+) tests passed');
    final allPassedMatch = allPassedRe.firstMatch(output);
    if (allPassedMatch != null) {
      total = int.parse(allPassedMatch.group(1)!);
    }

    // "+N tests" / "-N" pattern from final progress line
    final progressRe = RegExp(r'\+(\d+)(?:\s+-(\d+))?(?:\s+~(\d+))?:');
    final progressMatches = progressRe.allMatches(output).toList();
    if (progressMatches.isNotEmpty) {
      final last = progressMatches.last;
      final passed = int.tryParse(last.group(1) ?? '') ?? 0;
      failed = int.tryParse(last.group(2) ?? '') ?? 0;
      skipped = int.tryParse(last.group(3) ?? '') ?? 0;
      if (total == 0) total = passed + failed + skipped;
    }

    // Augment failures with error messages from the output block
    _augmentDartFailures(output, failures);

    final hasFailed = output.contains('Some tests failed') || failed > 0;
    return TestResult(
      passed: !hasFailed,
      totalTests: total,
      failedTests: failed,
      skippedTests: skipped,
      failures: failures,
      rawOutput: output,
    );
  }

  /// Attach error messages to failures parsed from dart test output.
  static void _augmentDartFailures(String output, List<TestFailure> failures) {
    // Error blocks start with the test name on a line ending with ":"
    // followed by indented lines.  Best-effort: match numbered failure blocks.
    final blockRe = RegExp(
      r'^(\d+)\) (.+?)\n((?:(?!^\d+\) ).+\n)*)',
      multiLine: true,
    );
    final augmented = <TestFailure>[];
    for (final f in failures) {
      bool found = false;
      for (final m in blockRe.allMatches(output)) {
        if (m.group(2)!.contains(f.testName)) {
          augmented.add(
            TestFailure(
              testName: f.testName,
              filePath: f.filePath,
              lineNumber: f.lineNumber,
              message: (m.group(3) ?? '').trim(),
            ),
          );
          found = true;
          break;
        }
      }
      if (!found) augmented.add(f);
    }
    failures
      ..clear()
      ..addAll(augmented);
  }

  // ── Jest ─────────────────────────────────────────────────────────────────

  static TestResult _parseJest(String output) {
    final failures = <TestFailure>[];

    // Failure blocks start with "● test suite › test name"
    final bulletRe = RegExp(r'^● (.+)$', multiLine: true);
    for (final m in bulletRe.allMatches(output)) {
      failures.add(TestFailure(testName: m.group(1)!.trim(), message: ''));
    }

    // Summary: "Tests: 2 failed, 10 passed, 12 total"
    int total = 0, failed = 0, skipped = 0;
    final summaryRe = RegExp(
      r'Tests:\s+(?:(\d+) failed,\s*)?(?:(\d+) skipped,\s*)?(?:(\d+) passed,\s*)?(\d+) total',
    );
    final sm = summaryRe.firstMatch(output);
    if (sm != null) {
      failed = int.tryParse(sm.group(1) ?? '') ?? 0;
      skipped = int.tryParse(sm.group(2) ?? '') ?? 0;
      total = int.tryParse(sm.group(4) ?? '') ?? 0;
    }

    return TestResult(
      passed: failed == 0 && !output.contains('FAIL'),
      totalTests: total,
      failedTests: failed,
      skippedTests: skipped,
      failures: failures,
      rawOutput: output,
    );
  }

  // ── Pytest ───────────────────────────────────────────────────────────────

  static TestResult _parsePytest(String output) {
    final failures = <TestFailure>[];

    // "FAILED path/to/test.py::test_name - AssertionError: ..."
    final failRe = RegExp(
      r'^FAILED (.+?)::(.+?)(?:\s+-\s+(.+))?$',
      multiLine: true,
    );
    for (final m in failRe.allMatches(output)) {
      failures.add(
        TestFailure(
          testName: m.group(2)!.trim(),
          filePath: m.group(1)!.trim(),
          message: m.group(3)?.trim() ?? '',
        ),
      );
    }

    // Summary: "2 failed, 10 passed in 1.23s"
    int total = 0, failed = 0, skipped = 0;
    final summaryRe = RegExp(
      r'=+ (?:(\d+) failed)?(?:,\s*)?(?:(\d+) passed)?(?:,\s*)?(?:(\d+) skipped)?.+ =+',
    );
    final sm = summaryRe.firstMatch(output);
    if (sm != null) {
      failed = int.tryParse(sm.group(1) ?? '') ?? 0;
      final passed = int.tryParse(sm.group(2) ?? '') ?? 0;
      skipped = int.tryParse(sm.group(3) ?? '') ?? 0;
      total = failed + passed + skipped;
    }

    return TestResult(
      passed: failed == 0 && !output.contains('failed'),
      totalTests: total,
      failedTests: failed,
      skippedTests: skipped,
      failures: failures,
      rawOutput: output,
    );
  }

  // ── Cargo (Rust) ─────────────────────────────────────────────────────────

  static TestResult _parseCargo(String output) {
    final failures = <TestFailure>[];

    // "---- module::test_name stdout ----" then error lines
    final failRe = RegExp(r'^---- (.+) stdout ----', multiLine: true);
    for (final m in failRe.allMatches(output)) {
      failures.add(TestFailure(testName: m.group(1)!.trim(), message: ''));
    }

    // "test result: FAILED. 2 passed; 1 failed; 0 ignored"
    int total = 0, failed = 0, skipped = 0;
    final summaryRe = RegExp(
      r'test result: (?:ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored',
    );
    final sm = summaryRe.firstMatch(output);
    if (sm != null) {
      final passed = int.tryParse(sm.group(1) ?? '') ?? 0;
      failed = int.tryParse(sm.group(2) ?? '') ?? 0;
      skipped = int.tryParse(sm.group(3) ?? '') ?? 0;
      total = passed + failed + skipped;
    }

    return TestResult(
      passed: failed == 0 && output.contains('test result: ok'),
      totalTests: total,
      failedTests: failed,
      skippedTests: skipped,
      failures: failures,
      rawOutput: output,
    );
  }

  // ── Go ───────────────────────────────────────────────────────────────────

  static TestResult _parseGo(String output) {
    final failures = <TestFailure>[];

    // "--- FAIL: TestName (0.00s)"
    final failRe = RegExp(r'^--- FAIL: (\S+) \(', multiLine: true);
    for (final m in failRe.allMatches(output)) {
      failures.add(TestFailure(testName: m.group(1)!.trim(), message: ''));
    }

    // "--- PASS" lines for total count
    final passRe = RegExp(r'^--- PASS:', multiLine: true);
    final passed = passRe.allMatches(output).length;
    final failed = failures.length;

    // "FAIL\t..." or "ok  \t..."
    final hasFailed =
        output.contains('\nFAIL\t') || output.contains('\nFAIL\n');

    return TestResult(
      passed: !hasFailed,
      totalTests: passed + failed,
      failedTests: failed,
      skippedTests: 0,
      failures: failures,
      rawOutput: output,
    );
  }
}

/// Test framework identifier embedded in run_tests output via a marker.
enum TestFramework { dart, jest, pytest, cargo, go }

/// Marker embedded by [RunTestsTool] so the agent loop can parse correctly.
const String kFrameworkMarker = '\nFRAMEWORK:';

/// Extract the [TestFramework] from a raw tool result string.
TestFramework? extractFramework(String toolResult) {
  final idx = toolResult.indexOf(kFrameworkMarker);
  if (idx == -1) return null;
  final name = toolResult
      .substring(idx + kFrameworkMarker.length)
      .trim()
      .split('\n')
      .first;
  return switch (name) {
    'dart' => TestFramework.dart,
    'jest' => TestFramework.jest,
    'pytest' => TestFramework.pytest,
    'cargo' => TestFramework.cargo,
    'go' => TestFramework.go,
    _ => null,
  };
}
