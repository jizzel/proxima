import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/tools/ignore_matcher.dart';
import 'package:proxima/tools/search/find_references_tool.dart';
import 'package:proxima/tools/search/search_symbol_tool.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('proxima_ignore_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  Future<IgnoreMatcher> matcherWith(
    String gitignore, {
    List<String> session = const [],
  }) async {
    await File(p.join(tempDir.path, '.gitignore')).writeAsString(gitignore);
    return IgnoreMatcher.forDirectory(tempDir.path, sessionPatterns: session);
  }

  group('built-in defaults', () {
    test('skips VCS, dependency, and build directories', () async {
      final m = IgnoreMatcher.defaults();
      for (final dir in ['.git', 'node_modules', 'build', '.dart_tool']) {
        expect(m.shouldPruneDir(dir), isTrue, reason: dir);
      }
    });

    test('skips paths nested inside a skipped directory', () async {
      final m = IgnoreMatcher.defaults();
      expect(m.isIgnored('node_modules/react/index.js'), isTrue);
      expect(m.isIgnored('.git/config'), isTrue);
    });

    test('keeps ordinary source paths', () async {
      final m = IgnoreMatcher.defaults();
      expect(m.isIgnored('lib/main.dart'), isFalse);
      expect(m.isIgnored('README.md'), isFalse);
    });

    test('skips generated dart files', () async {
      final m = IgnoreMatcher.defaults();
      expect(m.isIgnored('lib/model.g.dart'), isTrue);
      expect(m.isIgnored('lib/model.freezed.dart'), isTrue);
      expect(m.isIgnored('lib/model.dart'), isFalse);
    });
  });

  group('.gitignore parsing', () {
    test('ignores blank lines and comments', () async {
      final m = await matcherWith('# a comment\n\n   \n*.log\n');
      expect(m.isIgnored('debug.log'), isTrue);
      expect(m.isIgnored('main.dart'), isFalse);
    });

    test('matches a bare pattern at any depth', () async {
      final m = await matcherWith('*.log\n');
      expect(m.isIgnored('debug.log'), isTrue);
      expect(m.isIgnored('logs/nested/debug.log'), isTrue);
    });

    test('a leading slash anchors to the root', () async {
      final m = await matcherWith('/build.sh\n');
      expect(m.isIgnored('build.sh'), isTrue);
      expect(m.isIgnored('scripts/build.sh'), isFalse);
    });

    test('a trailing slash matches directories only', () async {
      final m = await matcherWith('cache/\n');
      expect(m.isIgnored('cache', isDirectory: true), isTrue);
      expect(m.isIgnored('cache/data.bin'), isTrue);
    });

    test('negation re-includes a previously excluded path', () async {
      final m = await matcherWith('*.log\n!keep.log\n');
      expect(m.isIgnored('debug.log'), isTrue);
      expect(m.isIgnored('keep.log'), isFalse);
    });

    test('order matters — a later rule wins', () async {
      final m = await matcherWith('!keep.log\n*.log\n');
      expect(m.isIgnored('keep.log'), isTrue);
    });

    test('** crosses directory separators', () async {
      final m = await matcherWith('docs/**/*.tmp\n');
      expect(m.isIgnored('docs/a/b/file.tmp'), isTrue);
      expect(m.isIgnored('docs/file.tmp'), isTrue);
    });

    test('a single * does not cross separators', () async {
      final m = await matcherWith('docs/*.tmp\n');
      expect(m.isIgnored('docs/file.tmp'), isTrue);
      expect(m.isIgnored('docs/nested/file.tmp'), isFalse);
    });

    test('? matches exactly one character', () async {
      final m = await matcherWith('file?.txt\n');
      expect(m.isIgnored('file1.txt'), isTrue);
      expect(m.isIgnored('file.txt'), isFalse);
    });

    test('a path pattern matches everything beneath it', () async {
      final m = await matcherWith('coverage\n');
      expect(m.isIgnored('coverage'), isTrue);
      expect(m.isIgnored('coverage/lcov.info'), isTrue);
    });

    test('dots are literal, not wildcards', () async {
      final m = await matcherWith('a.txt\n');
      expect(m.isIgnored('a.txt'), isTrue);
      expect(m.isIgnored('axtxt'), isFalse);
    });
  });

  group('session patterns from /ignore', () {
    test('are applied alongside .gitignore', () async {
      final m = await matcherWith('*.log\n', session: ['*.tmp']);
      expect(m.isIgnored('a.log'), isTrue);
      expect(m.isIgnored('a.tmp'), isTrue);
      expect(m.isIgnored('a.dart'), isFalse);
    });

    test('are applied last so they can override .gitignore', () async {
      final m = await matcherWith('*.log\n', session: ['!important.log']);
      expect(m.isIgnored('important.log'), isFalse);
    });
  });

  group('robustness', () {
    test('a missing .gitignore falls back to defaults', () async {
      final m = await IgnoreMatcher.forDirectory(tempDir.path);
      expect(m.isIgnored('node_modules/x'), isTrue);
      expect(m.isIgnored('lib/main.dart'), isFalse);
    });

    test('handles windows-style separators', () async {
      final m = await matcherWith('*.log\n');
      expect(m.isIgnored(r'logs\debug.log'), isTrue);
    });

    test('never ignores the working directory itself', () async {
      final m = await matcherWith('*\n');
      expect(m.isIgnored('.'), isFalse);
    });
  });
  group('symbol walkers honour ignore rules', () {
    // Regression: both walkers passed only a *basename* to shouldPruneDir, so a
    // path-qualified rule (`vendor/lib/`) could never match, and the file
    // branch consulted only the built-in generated-file suffixes, so a
    // `.gitignore` file rule was ignored entirely.
    Future<void> write(String rel, String content) async {
      final file = File(p.join(tempDir.path, rel));
      await file.parent.create(recursive: true);
      await file.writeAsString(content);
    }

    test('path-qualified directory rules match', () async {
      final m = await matcherWith('vendor/lib/\n');
      expect(m.isIgnored('vendor/lib', isDirectory: true), isTrue);
      expect(m.isIgnored('vendor/lib/dep.dart'), isTrue);
      expect(m.isIgnored('lib/main.dart'), isFalse);
    });

    test('find_references skips ignored files and directories', () async {
      await write('lib/main.dart', 'void widget() {}\n');
      await write('vendor/lib/dep.dart', 'void widget() {}\n');
      await write('lib/excluded.dart', 'void widget() {}\n');
      final m = await matcherWith('vendor/lib/\nlib/excluded.dart\n');

      final result = await FindReferencesTool(
        matcher: () => m,
      ).execute({'symbol': 'widget'}, tempDir.path);

      expect(result, contains('main.dart'));
      expect(result, isNot(contains('vendor')));
      expect(result, isNot(contains('excluded.dart')));
    });

    test('search_symbol skips ignored files and directories', () async {
      await write('lib/main.dart', 'void widget() {}\n');
      await write('vendor/lib/dep.dart', 'void widget() {}\n');
      await write('lib/excluded.dart', 'void widget() {}\n');
      final m = await matcherWith('vendor/lib/\nlib/excluded.dart\n');

      final result = await SearchSymbolTool(
        matcher: () => m,
      ).execute({'symbol': 'widget'}, tempDir.path);

      expect(result, contains('main.dart'));
      expect(result, isNot(contains('vendor')));
      expect(result, isNot(contains('excluded.dart')));
    });
  });
  group('anchoring and directory-only precision', () {
    test(
      'a root-anchored rule does not prune nested same-named dirs',
      () async {
        // Regression: shouldPruneDir took a basename, so `/generated/` pruned
        // `lib/generated` too — which git does not do.
        final m = await matcherWith('/generated/\n');
        expect(m.shouldPruneDir('generated'), isTrue);
        expect(m.shouldPruneDir('lib/generated'), isFalse);
      },
    );

    test('an unanchored rule still matches at any depth', () async {
      final m = await matcherWith('generated/\n');
      expect(m.shouldPruneDir('generated'), isTrue);
      expect(m.shouldPruneDir('lib/generated'), isTrue);
    });

    test('a directory-only rule never matches a file of that name', () async {
      // Regression: the guard treated any path containing '/' as a descendant,
      // so `cache/` wrongly ignored a *file* at src/cache.
      final m = await matcherWith('cache/\n');
      expect(m.isIgnored('cache', isDirectory: true), isTrue);
      expect(m.isIgnored('cache/data.bin'), isTrue);
      expect(m.isIgnored('src/cache'), isFalse, reason: 'a file, not a dir');
      expect(m.isIgnored('src/cache/x.bin'), isTrue, reason: 'descendant');
    });

    test('built-in skips still apply at any depth', () async {
      final m = IgnoreMatcher.defaults();
      expect(m.shouldPruneDir('node_modules'), isTrue);
      expect(m.shouldPruneDir('packages/app/node_modules'), isTrue);
      expect(m.isIgnored('lib/main.dart'), isFalse);
    });
  });
}
