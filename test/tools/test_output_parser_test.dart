import 'package:test/test.dart';
import 'package:proxima/tools/shell/test_output_parser.dart';

void main() {
  group('TestOutputParser.parse — dart', () {
    test('all tests passed', () {
      const output = '''
00:01 +10: All tests passed!
All 10 tests passed!
''';
      final result = TestOutputParser.parse(output, TestFramework.dart);
      expect(result.passed, isTrue);
      expect(result.totalTests, 10);
      expect(result.failedTests, 0);
      expect(result.failures, isEmpty);
    });

    test('some tests failed', () {
      const output = '''
00:01 +4 -2: some test name [E]
00:01 +4 -2: Some tests failed.

  FAILED my test one
  FAILED my test two
''';
      final result = TestOutputParser.parse(output, TestFramework.dart);
      expect(result.passed, isFalse);
      expect(result.failedTests, 2);
      expect(result.failures, hasLength(2));
      expect(result.failures.first.testName, 'my test one');
      expect(result.failures.last.testName, 'my test two');
    });

    test('toPromptText for passing', () {
      const output = 'All 5 tests passed!';
      final result = TestOutputParser.parse(output, TestFramework.dart);
      expect(result.toPromptText(), contains('5'));
      expect(result.toPromptText(), contains('passed'));
    });

    test('toPromptText for failing lists test names', () {
      const output = '''
00:00 +0 -1: Some tests failed.
  FAILED broken test
''';
      final result = TestOutputParser.parse(output, TestFramework.dart);
      final text = result.toPromptText();
      expect(text, contains('FAIL'));
      expect(text, contains('broken test'));
    });
  });

  group('TestOutputParser.parse — jest', () {
    test('all passed', () {
      const output = '''
Tests: 5 passed, 5 total
Test Suites: 1 passed, 1 total
''';
      final result = TestOutputParser.parse(output, TestFramework.jest);
      expect(result.passed, isTrue);
      expect(result.totalTests, 5);
      expect(result.failedTests, 0);
    });

    test('some failed', () {
      const output = '''
● should do something

Tests: 2 failed, 3 passed, 5 total
''';
      final result = TestOutputParser.parse(output, TestFramework.jest);
      expect(result.passed, isFalse);
      expect(result.failedTests, 2);
      expect(result.totalTests, 5);
      expect(result.failures, hasLength(1));
      expect(result.failures.first.testName, 'should do something');
    });
  });

  group('TestOutputParser.parse — pytest', () {
    test('all passed', () {
      const output = '====== 5 passed in 0.12s ======';
      final result = TestOutputParser.parse(output, TestFramework.pytest);
      expect(result.passed, isTrue);
    });

    test('some failed', () {
      const output = '''
FAILED tests/test_foo.py::test_add - AssertionError: 1 != 2
====== 1 failed, 4 passed in 0.21s ======
''';
      final result = TestOutputParser.parse(output, TestFramework.pytest);
      expect(result.passed, isFalse);
      expect(result.failedTests, 1);
      expect(result.totalTests, 5);
      expect(result.failures.first.testName, 'test_add');
      expect(result.failures.first.filePath, 'tests/test_foo.py');
      expect(result.failures.first.message, contains('AssertionError'));
    });
  });

  group('TestOutputParser.parse — cargo', () {
    test('all passed', () {
      const output = 'test result: ok. 3 passed; 0 failed; 0 ignored';
      final result = TestOutputParser.parse(output, TestFramework.cargo);
      expect(result.passed, isTrue);
      expect(result.totalTests, 3);
      expect(result.failedTests, 0);
    });

    test('some failed', () {
      const output = '''
---- module::test_one stdout ----
thread panicked at ...
test result: FAILED. 2 passed; 1 failed; 0 ignored
''';
      final result = TestOutputParser.parse(output, TestFramework.cargo);
      expect(result.passed, isFalse);
      expect(result.failedTests, 1);
      expect(result.failures.first.testName, 'module::test_one');
    });
  });

  group('TestOutputParser.parse — go', () {
    test('all passed', () {
      const output = '''
--- PASS: TestAdd (0.00s)
--- PASS: TestSub (0.00s)
ok  \tgithub.com/foo/bar\t0.002s
''';
      final result = TestOutputParser.parse(output, TestFramework.go);
      expect(result.passed, isTrue);
      expect(result.totalTests, 2);
    });

    test('some failed', () {
      const output = '''
--- PASS: TestAdd (0.00s)
--- FAIL: TestSub (0.00s)
FAIL\tgithub.com/foo/bar\t0.002s
''';
      final result = TestOutputParser.parse(output, TestFramework.go);
      expect(result.passed, isFalse);
      expect(result.failedTests, 1);
      expect(result.failures.first.testName, 'TestSub');
    });
  });

  group('extractFramework', () {
    test('extracts dart framework marker', () {
      const toolResult = 'All 5 tests passed.\nExit code: 0\nFRAMEWORK:dart';
      expect(extractFramework(toolResult), TestFramework.dart);
    });

    test('returns null when no marker present', () {
      expect(extractFramework('some output'), isNull);
    });

    test('returns null for unknown framework name', () {
      expect(extractFramework('output\nFRAMEWORK:unknown'), isNull);
    });
  });
}
