import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:diff_match_patch/diff_match_patch.dart';
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class WriteFileTool implements ProximaTool {
  @override
  String get name => 'write_file';

  @override
  String get description =>
      'Write content to a file, creating it if it does not exist. '
      'Shows a diff for existing files. Creates parent directories as needed.';

  @override
  RiskLevel get riskLevel => RiskLevel.confirm;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Relative path to the file'},
      'content': {'type': 'string', 'description': 'Full content to write'},
    },
    'required': ['path', 'content'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final filePath = args['path'] as String;
    final content = args['content'] as String;

    if (!isSafePath(filePath, workingDir)) {
      throw ToolError(name, 'Path "$filePath" is outside working directory.');
    }

    final fullPath = p.isAbsolute(filePath)
        ? filePath
        : p.join(workingDir, filePath);
    final file = File(fullPath);

    // Create parent directories.
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }

    // Backup existing file.
    String? backupPath;
    if (await file.exists()) {
      backupPath = '$fullPath.proxima_bak';
      await file.copy(backupPath);
    }

    await file.writeAsString(content);

    if (backupPath != null) {
      // Return backup path so agent_loop can record it in TaskRecord for /undo.
      return 'Written: $filePath\nBACKUP_PATH:$backupPath';
    }
    return 'Created: $filePath';
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final filePath = args['path'] as String;
    final content = args['content'] as String;
    final fullPath = p.isAbsolute(filePath)
        ? filePath
        : p.join(workingDir, filePath);
    final file = File(fullPath);

    String? diffText;
    if (await file.exists()) {
      final existing = await file.readAsString();
      final dmp = DiffMatchPatch();
      final diffs = dmp.diff(existing, content);
      dmp.diffCleanupSemantic(diffs);
      diffText = _renderDiff(diffs, existing, content);
    }

    return DryRunResult(
      preview: 'Would write ${content.length} bytes to: $filePath',
      riskLevel: riskLevel,
      diffText: diffText,
    );
  }

  String _renderDiff(List<Diff> diffs, String oldText, String newText) {
    final buffer = StringBuffer();
    buffer.writeln('--- a');
    buffer.writeln('+++ b');
    // Simple line-based diff for display.
    for (final diff in diffs) {
      final lines = diff.text.split('\n');
      switch (diff.operation) {
        case DIFF_EQUAL:
          for (final line in lines) {
            if (line.isNotEmpty) buffer.writeln(' $line');
          }
        case DIFF_DELETE:
          for (final line in lines) {
            if (line.isNotEmpty) buffer.writeln('-$line');
          }
        case DIFF_INSERT:
          for (final line in lines) {
            if (line.isNotEmpty) buffer.writeln('+$line');
          }
      }
    }
    return buffer.toString();
  }
}
