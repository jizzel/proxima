import 'dart:io';
import 'package:path/path.dart' as p;

/// A project snapshot: directory structure, framework, recent mods.
class ProjectIndex {
  final String workingDir;
  final List<String> files;
  final String? framework;
  final List<String> recentlyModified;
  final DateTime builtAt;

  const ProjectIndex({
    required this.workingDir,
    required this.files,
    this.framework,
    required this.recentlyModified,
    required this.builtAt,
  });

  /// Walk [workingDir] to build a project index.
  static Future<ProjectIndex> build(String workingDir) async {
    final dir = Directory(workingDir);
    if (!await dir.exists()) {
      return ProjectIndex(
        workingDir: workingDir,
        files: [],
        recentlyModified: [],
        builtAt: DateTime.now(),
      );
    }

    final files = <String>[];
    final recentlySeen = <MapEntry<String, DateTime>>[];

    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        // Skip hidden files and common noisy dirs.
        final rel = p.relative(entity.path, from: workingDir);
        if (_shouldSkip(rel)) continue;

        files.add(rel);

        try {
          final stat = await entity.stat();
          recentlySeen.add(MapEntry(rel, stat.modified));
        } catch (_) {}
      }
    }

    files.sort();

    recentlySeen.sort((a, b) => b.value.compareTo(a.value));
    final recentlyModified = recentlySeen.take(10).map((e) => e.key).toList();

    final framework = await _detectFramework(workingDir);

    return ProjectIndex(
      workingDir: workingDir,
      files: files,
      framework: framework,
      recentlyModified: recentlyModified,
      builtAt: DateTime.now(),
    );
  }

  static bool _shouldSkip(String rel) {
    final parts = rel.split(p.separator);
    const skipDirs = {
      '.git',
      'node_modules',
      '.dart_tool',
      'build',
      '.build',
      '__pycache__',
      '.venv',
      'venv',
      '.idea',
      '.vscode',
    };
    return parts.any(
      (part) =>
          (part.startsWith('.') && part != '.') || skipDirs.contains(part),
    );
  }

  static Future<String?> _detectFramework(String workingDir) async {
    Future<bool> exists(String name) => File(p.join(workingDir, name)).exists();

    if (await exists('pubspec.yaml')) {
      final content = await File(
        p.join(workingDir, 'pubspec.yaml'),
      ).readAsString();
      return content.contains('flutter') ? 'flutter' : 'dart';
    }
    if (await exists('package.json')) return 'node';
    if (await exists('Cargo.toml')) return 'rust';
    if (await exists('go.mod')) return 'go';
    if (await exists('pyproject.toml') || await exists('setup.py')) {
      return 'python';
    }
    if (await exists('pom.xml')) return 'java-maven';
    if (await exists('build.gradle')) return 'java-gradle';
    return null;
  }

  /// Render as compact text for inclusion in system prompt.
  String toPromptText({int maxFiles = 100}) {
    final buf = StringBuffer();
    buf.writeln('Working directory: $workingDir');
    if (framework != null) buf.writeln('Framework: $framework');
    buf.writeln('\nProject files (${files.length} total):');

    final shown = files.take(maxFiles).toList();
    for (final f in shown) {
      buf.writeln('  $f');
    }
    if (files.length > maxFiles) {
      buf.writeln('  ... and ${files.length - maxFiles} more');
    }

    if (recentlyModified.isNotEmpty) {
      buf.writeln('\nRecently modified:');
      for (final f in recentlyModified.take(5)) {
        buf.writeln('  $f');
      }
    }

    return buf.toString();
  }
}
