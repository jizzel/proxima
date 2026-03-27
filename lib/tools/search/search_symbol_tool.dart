import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class SymbolMatch {
  final String file;
  final int line;
  final String kind;
  final String signature;

  const SymbolMatch({
    required this.file,
    required this.line,
    required this.kind,
    required this.signature,
  });
}

/// AST-heuristic symbol search across Dart, JS/TS, Python, Go, Rust, Java/Kotlin.
class SearchSymbolTool implements ProximaTool {
  @override
  String get name => 'search_symbol';

  @override
  RiskLevel get riskLevel => RiskLevel.safe;

  @override
  String get description =>
      'Find function, class, method, or variable definitions by name. '
      'Supports Dart, JS/TS, Python, Go, Rust, Java, Kotlin.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'symbol': {'type': 'string', 'description': 'Symbol name to find'},
      'kind': {
        'type': 'string',
        'enum': ['function', 'class', 'method', 'variable', 'any'],
        'description': 'Kind to filter by (default: any)',
      },
      'path': {
        'type': 'string',
        'description':
            'Directory or glob to restrict search (default: working dir)',
      },
      'max_results': {
        'type': 'integer',
        'description': 'Max results (default: 50)',
      },
    },
    'required': ['symbol'],
  };

  static const _skipDirs = {
    '.git',
    'node_modules',
    'build',
    '.dart_tool',
    '.pub-cache',
  };
  static const _skipSuffixes = ['.g.dart', '.freezed.dart', '.pb.dart'];

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final symbol = args['symbol'] as String;
    final kind = args['kind'] as String? ?? 'any';
    final relPath = args['path'] as String?;
    final maxResults = args['max_results'] as int? ?? 50;

    final searchRoot = relPath != null
        ? (p.isAbsolute(relPath) ? relPath : p.join(workingDir, relPath))
        : workingDir;

    if (!isSafePath(searchRoot, workingDir)) {
      throw ToolError(
        name,
        'Path "$searchRoot" is outside working directory.',
        errorCode: ToolErrorCode.pathViolation,
      );
    }

    final matches = <SymbolMatch>[];
    await _walk(
      Directory(searchRoot),
      symbol,
      kind,
      workingDir,
      maxResults,
      matches,
    );

    if (matches.isEmpty) return 'No definitions found for: $symbol';

    return matches
        .map((m) => '${m.file}:${m.line}  [${m.kind}]  ${m.signature}')
        .join('\n');
  }

  Future<void> _walk(
    Directory dir,
    String symbol,
    String kind,
    String workingDir,
    int maxResults,
    List<SymbolMatch> matches,
  ) async {
    List<FileSystemEntity> entities;
    try {
      entities = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }

    for (final entity in entities) {
      if (matches.length >= maxResults) return;

      final basename = p.basename(entity.path);

      if (entity is Directory) {
        if (_skipDirs.contains(basename)) continue;
        await _walk(entity, symbol, kind, workingDir, maxResults, matches);
      } else if (entity is File) {
        if (_skipSuffixes.any((s) => entity.path.endsWith(s))) continue;
        final lang = _detectLanguage(entity.path);
        if (lang == null) continue;
        await _searchFile(
          entity,
          lang,
          symbol,
          kind,
          workingDir,
          maxResults,
          matches,
        );
      }
    }
  }

  String? _detectLanguage(String path) {
    final ext = p.extension(path).toLowerCase();
    return switch (ext) {
      '.dart' => 'dart',
      '.js' || '.ts' || '.jsx' || '.tsx' || '.mjs' || '.cjs' => 'js',
      '.py' => 'python',
      '.go' => 'go',
      '.rs' => 'rust',
      '.java' || '.kt' => 'java',
      _ => null,
    };
  }

  Future<void> _searchFile(
    File file,
    String lang,
    String symbol,
    String kind,
    String workingDir,
    int maxResults,
    List<SymbolMatch> matches,
  ) async {
    List<String> lines;
    try {
      lines = await file.readAsLines();
    } on FormatException {
      return; // binary file
    } catch (_) {
      return;
    }

    final relPath = p.relative(file.path, from: workingDir);
    final patterns = _patternsFor(lang, symbol, kind);

    for (var i = 0; i < lines.length; i++) {
      if (matches.length >= maxResults) return;
      final line = lines[i];
      for (final (matchKind, regex) in patterns) {
        if (regex.hasMatch(line)) {
          final sig = line.trim();
          final capped = sig.length > 120 ? '${sig.substring(0, 120)}…' : sig;
          matches.add(
            SymbolMatch(
              file: relPath,
              line: i + 1,
              kind: matchKind,
              signature: capped,
            ),
          );
          break; // only first matching pattern per line
        }
      }
    }
  }

  /// Returns list of (kind, pattern) pairs for the given language and requested kind.
  List<(String, RegExp)> _patternsFor(String lang, String symbol, String kind) {
    final esc = RegExp.escape(symbol);
    final all = _allPatterns(lang, esc);
    if (kind == 'any') return all;
    return all.where((p) => p.$1 == kind).toList();
  }

  List<(String, RegExp)> _allPatterns(String lang, String esc) {
    return switch (lang) {
      'dart' => _dartPatterns(esc),
      'js' => _jsPatterns(esc),
      'python' => _pythonPatterns(esc),
      'go' => _goPatterns(esc),
      'rust' => _rustPatterns(esc),
      'java' => _javaPatterns(esc),
      _ => [],
    };
  }

  List<(String, RegExp)> _dartPatterns(String esc) => [
    ('class', RegExp(r'^(?:abstract\s+)?(?:final\s+)?class\s+' + esc + r'\b')),
    (
      // Top-level function: no leading whitespace
      'function',
      RegExp(r'^(?:[\w<>?,]+\s+)?' + esc + r'\s*\([^)]*\)\s*(?:async\s*)?\{'),
    ),
    (
      // Method: indented (has leading whitespace)
      'method',
      RegExp(
        r'^\s+(?:[\w<>?,\s]+\s+)?' + esc + r'\s*\([^)]*\)\s*(?:async\s*)?\{',
      ),
    ),
    (
      'variable',
      RegExp(
        r'^\s*(?:final|const|var|late)\s+(?:[\w<>?]+\s+)?' + esc + r'\s*[=;]',
      ),
    ),
  ];

  List<(String, RegExp)> _jsPatterns(String esc) => [
    ('class', RegExp(r'^(?:export\s+)?(?:abstract\s+)?class\s+' + esc + r'\b')),
    (
      'function',
      RegExp(
        r'^(?:export\s+)?(?:async\s+)?function\s+' +
            esc +
            r'\s*\(|^(?:export\s+)?(?:const|let|var)\s+' +
            esc +
            r'\s*=\s*(?:async\s+)?\(',
      ),
    ),
    ('method', RegExp(r'^\s+(?:async\s+)?' + esc + r'\s*\([^)]*\)\s*\{')),
    (
      'variable',
      RegExp(r'^(?:export\s+)?(?:const|let|var)\s+' + esc + r'\s*[=;]'),
    ),
  ];

  List<(String, RegExp)> _pythonPatterns(String esc) => [
    ('class', RegExp(r'^class\s+' + esc + r'\b')),
    ('function', RegExp(r'^def\s+' + esc + r'\s*\(')),
    ('method', RegExp(r'^\s+def\s+' + esc + r'\s*\(')),
    ('variable', RegExp(r'^' + esc + r'\s*=(?!=)')),
  ];

  List<(String, RegExp)> _goPatterns(String esc) => [
    ('class', RegExp(r'^type\s+' + esc + r'\s+struct\b')),
    ('function', RegExp(r'^func\s+' + esc + r'\s*\(')),
    ('method', RegExp(r'^func\s+\([^)]+\)\s+' + esc + r'\s*\(')),
    (
      'variable',
      RegExp(r'^(?:var|const)\s+' + esc + r'\b|^\s+' + esc + r'\s*:='),
    ),
  ];

  List<(String, RegExp)> _rustPatterns(String esc) => [
    ('class', RegExp(r'^(?:pub\s+)?(?:struct|enum|trait)\s+' + esc + r'\b')),
    ('function', RegExp(r'^(?:pub\s+)?(?:async\s+)?fn\s+' + esc + r'\s*[<(]')),
    ('method', RegExp(r'^\s+(?:pub\s+)?(?:async\s+)?fn\s+' + esc + r'\s*[<(]')),
    ('variable', RegExp(r'^(?:pub\s+)?(?:const|static)\s+' + esc + r'\b')),
  ];

  List<(String, RegExp)> _javaPatterns(String esc) => [
    (
      'class',
      RegExp(
        r'^(?:(?:public|private|protected|abstract|final|data)\s+)*class\s+' +
            esc +
            r'\b',
      ),
    ),
    (
      'method',
      RegExp(
        r'^\s+(?:(?:public|private|protected|static|final|override|suspend)\s+)*(?:[\w<>?,\[\]]+\s+)+' +
            esc +
            r'\s*\(',
      ),
    ),
    (
      'variable',
      RegExp(
        r'^\s+(?:(?:public|private|protected|static|final)\s+)*(?:[\w<>?,\[\]]+\s+)+' +
            esc +
            r'\s*[=;]|^\s+(?:val|var)\s+' +
            esc +
            r'\b',
      ),
    ),
  ];

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final symbol = args['symbol'] as String;
    final kind = args['kind'] as String? ?? 'any';
    final kindLabel = kind == 'any' ? 'symbol' : kind;
    return DryRunResult(
      preview: 'Would search for $kindLabel: $symbol',
      riskLevel: riskLevel,
    );
  }
}
