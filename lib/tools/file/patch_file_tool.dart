import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:diff_match_patch/diff_match_patch.dart';
import '../../core/types.dart';
import '../tool_interface.dart';
import '../path_guard.dart';

class PatchFileTool implements ProximaTool {
  @override
  String get name => 'patch_file';

  @override
  String get description =>
      'Apply a search-and-replace patch to a file. '
      'Replaces the first occurrence of old_str with new_str by default. '
      'Set replace_all=true to replace every occurrence.';

  @override
  RiskLevel get riskLevel => RiskLevel.confirm;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'Relative path to the file'},
      'old_str': {
        'type': 'string',
        'description': 'Exact string to find and replace',
      },
      'new_str': {'type': 'string', 'description': 'Replacement string'},
      'replace_all': {
        'type': 'boolean',
        'description': 'Replace all occurrences (default: false, replaces first only)',
      },
    },
    'required': ['path', 'old_str', 'new_str'],
  };

  @override
  Future<String> execute(Map<String, dynamic> args, String workingDir) async {
    final filePath = args['path'] as String;
    final oldStr = args['old_str'] as String;
    final newStr = args['new_str'] as String;
    final replaceAll = args['replace_all'] as bool? ?? false;

    if (!isSafePath(filePath, workingDir)) {
      throw ToolError(name, 'Path "$filePath" is outside working directory.');
    }

    final fullPath = p.isAbsolute(filePath)
        ? filePath
        : p.join(workingDir, filePath);
    final file = File(fullPath);

    if (!await file.exists()) {
      throw ToolError(name, 'File not found: $filePath');
    }

    final content = await file.readAsString();

    if (!content.contains(oldStr)) {
      throw ToolError(name, 'old_str not found in $filePath');
    }

    // Backup before patching.
    final backupPath = '$fullPath.proxima_bak';
    await file.copy(backupPath);

    final patched = replaceAll
        ? content.replaceAll(oldStr, newStr)
        : content.replaceFirst(oldStr, newStr);
    await file.writeAsString(patched);

    final count = replaceAll ? 'all occurrences' : 'first occurrence';
    return 'Patched: $filePath ($count replaced)\nBACKUP_PATH:$backupPath';
  }

  @override
  Future<DryRunResult> dryRun(
    Map<String, dynamic> args,
    String workingDir,
  ) async {
    final filePath = args['path'] as String;
    final oldStr = args['old_str'] as String;
    final newStr = args['new_str'] as String;
    final fullPath = p.isAbsolute(filePath)
        ? filePath
        : p.join(workingDir, filePath);
    final file = File(fullPath);

    String? diffText;
    if (await file.exists()) {
      final content = await file.readAsString();
      if (content.contains(oldStr)) {
        final patched = content.replaceFirst(oldStr, newStr);
        final dmp = DiffMatchPatch();
        final diffs = dmp.diff(content, patched);
        dmp.diffCleanupSemantic(diffs);
        diffText = diffs.map((d) {
          final prefix = switch (d.operation) {
            DIFF_EQUAL => ' ',
            DIFF_DELETE => '-',
            DIFF_INSERT => '+',
            _ => ' ',
          };
          return '$prefix${d.text}';
        }).join();
      }
    }

    return DryRunResult(
      preview: 'Would patch: $filePath (replace first occurrence of old_str)',
      riskLevel: riskLevel,
      diffText: diffText,
    );
  }
}
