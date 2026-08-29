import 'dart:io';
import 'package:path/path.dart' as p;

/// Decides which paths the file-walking tools should skip.
///
/// Before this existed there were three inconsistent definitions of "what to
/// skip" — `find_references_tool` and `search_symbol_tool` held byte-identical
/// copies of one set, `project_index` held a different set, and `list_files`,
/// `glob`, and `search` had none at all, so `search` happily walked
/// `node_modules` and `list_files` recursed into `.git`.
///
/// Sources, in order of application:
///   1. built-in defaults (VCS, dependency, and build directories)
///   2. `.gitignore` in the working directory
///   3. session patterns added with `/ignore`
///
/// Gitignore semantics are implemented here rather than pulled from a package:
/// there is no null-safe `.gitignore` matcher on pub (`package:gitignore` is a
/// pre-null-safety *generator*), and the two hand-rolled glob converters
/// already in the repo (`glob_tool`, `search_tool`) are not equivalent to each
/// other, so extending either would add a third dialect.
class IgnoreMatcher {
  /// Directories skipped regardless of `.gitignore` — never useful to an agent
  /// and expensive to walk. Union of the sets previously duplicated across
  /// `find_references_tool`, `search_symbol_tool`, and `project_index`.
  static const defaultSkipDirs = {
    '.git',
    '.hg',
    '.svn',
    'node_modules',
    'build',
    '.build',
    '.dart_tool',
    '.pub-cache',
    '__pycache__',
    '.venv',
    'venv',
    '.idea',
    '.vscode',
    '.next',
    'dist',
    'target',
  };

  /// Generated files that add noise without adding information.
  static const defaultSkipSuffixes = ['.g.dart', '.freezed.dart', '.pb.dart'];

  final List<_Rule> _rules;
  final Set<String> _skipDirs;

  IgnoreMatcher._(this._rules, this._skipDirs);

  /// A matcher with built-in defaults only — no `.gitignore`, no session
  /// patterns. Used where a working directory is not available.
  factory IgnoreMatcher.defaults() =>
      IgnoreMatcher._(const [], defaultSkipDirs);

  /// Builds a matcher for [workingDir], reading `.gitignore` if present and
  /// layering [sessionPatterns] (from `/ignore`) on top.
  ///
  /// Never throws: an unreadable or malformed `.gitignore` degrades to the
  /// built-in defaults rather than breaking every file tool.
  static Future<IgnoreMatcher> forDirectory(
    String workingDir, {
    List<String> sessionPatterns = const [],
  }) async {
    final rules = <_Rule>[];

    try {
      final file = File(p.join(workingDir, '.gitignore'));
      if (await file.exists()) {
        for (final line in await file.readAsLines()) {
          final rule = _Rule.parse(line);
          if (rule != null) rules.add(rule);
        }
      }
    } catch (_) {
      // Unreadable .gitignore — fall through to defaults.
    }

    for (final pattern in sessionPatterns) {
      final rule = _Rule.parse(pattern);
      if (rule != null) rules.add(rule);
    }

    return IgnoreMatcher._(rules, defaultSkipDirs);
  }

  /// Whether a directory should be pruned before descending into it.
  ///
  /// [relPath] is the directory's path relative to the working directory. It
  /// is required for correctness, not convenience: a root-anchored rule such
  /// as `/generated/` must match `generated` but *not* `lib/generated`, and a
  /// basename alone cannot tell those apart.
  ///
  /// Used by the tools that walk recursively by hand, where pruning avoids the
  /// cost of walking the subtree at all.
  bool shouldPruneDir(String relPath) {
    final normalized = p.posix.normalize(relPath.replaceAll(r'\', '/'));
    if (_skipDirs.contains(p.posix.basename(normalized))) return true;
    return isIgnored(normalized, isDirectory: true);
  }

  /// Whether [relPath] (relative to the working directory, POSIX separators)
  /// should be excluded from results.
  ///
  /// Used by the tools that call `Directory.list(recursive: true)` and can only
  /// filter after the fact.
  bool isIgnored(String relPath, {bool isDirectory = false}) {
    final normalized = p.posix.normalize(relPath.replaceAll(r'\', '/'));
    if (normalized == '.' || normalized.isEmpty) return false;

    // Any path segment inside a skipped directory is skipped.
    for (final segment in normalized.split('/')) {
      if (_skipDirs.contains(segment)) return true;
    }

    for (final suffix in defaultSkipSuffixes) {
      if (normalized.endsWith(suffix)) return true;
    }

    return _matches(normalized, isDirectory: isDirectory);
  }

  /// Applies the parsed rules in order; the last match wins, so a later
  /// negation (`!keep.log`) can re-include a path an earlier rule excluded.
  bool _matches(String path, {required bool isDirectory}) {
    var ignored = false;
    for (final rule in _rules) {
      if (!rule.matches(path)) continue;

      // A directory-only rule (`cache/`) matches the directory and everything
      // beneath it, but never a *file* named `cache`. Distinguish a match on
      // the terminal component from a match on an ancestor: if the rule also
      // matches a strict ancestor of this path, the path is a descendant of an
      // ignored directory and is excluded whatever its own type.
      if (rule.directoryOnly && !isDirectory && !rule.matchesAncestorOf(path)) {
        continue;
      }
      ignored = !rule.negated;
    }
    return ignored;
  }
}

/// One `.gitignore` line, compiled to a regex.
class _Rule {
  final RegExp _regex;
  final bool negated;
  final bool directoryOnly;

  _Rule(this._regex, this.negated, this.directoryOnly);

  /// Returns null for blank lines and comments.
  static _Rule? parse(String rawLine) {
    var line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) return null;

    var negated = false;
    if (line.startsWith('!')) {
      negated = true;
      line = line.substring(1);
    }

    final directoryOnly = line.endsWith('/');
    if (directoryOnly) line = line.substring(0, line.length - 1);

    // A leading slash anchors to the working directory; otherwise the pattern
    // may match at any depth.
    final anchored = line.startsWith('/');
    if (anchored) line = line.substring(1);
    if (line.isEmpty) return null;

    return _Rule(_compile(line, anchored: anchored), negated, directoryOnly);
  }

  /// Translates gitignore glob syntax to a regex.
  ///
  /// `**` crosses directory separators, a single `*` and `?` do not, and a
  /// pattern containing no slash may match at any depth.
  static RegExp _compile(String pattern, {required bool anchored}) {
    final buffer = StringBuffer();
    final containsSlash = pattern.contains('/');

    buffer.write('^');
    if (!anchored && !containsSlash) {
      buffer.write('(?:.*/)?'); // match at any depth
    }

    for (var i = 0; i < pattern.length; i++) {
      final char = pattern[i];
      if (char == '*') {
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          buffer.write('.*');
          i++;
          // Consume a following slash so `**/x` also matches a bare `x`.
          if (i + 1 < pattern.length && pattern[i + 1] == '/') i++;
        } else {
          buffer.write('[^/]*');
        }
      } else if (char == '?') {
        buffer.write('[^/]');
      } else if (r'\.+()|[]{}^$'.contains(char)) {
        buffer.write('\\$char');
      } else {
        buffer.write(char);
      }
    }

    // Match the entry itself or anything beneath it.
    buffer.write(r'(?:/.*)?$');
    return RegExp(buffer.toString());
  }

  bool matches(String path) {
    final trimmed = path.endsWith('/')
        ? path.substring(0, path.length - 1)
        : path;
    return _regex.hasMatch(trimmed);
  }

  /// Whether this rule matches a strict ancestor directory of [path].
  ///
  /// Lets a directory-only rule exclude `cache/data.bin` (a descendant of the
  /// matched directory) without excluding a file named `src/cache`.
  bool matchesAncestorOf(String path) {
    final parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
      if (_regex.hasMatch(parts.take(i).join('/'))) return true;
    }
    return false;
  }
}
