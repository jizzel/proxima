import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../../core/types.dart';
import 'shell_plugin_tool.dart';

/// Discovers and loads plugins from drop-in directories.
class PluginLoader {
  /// Discovers and loads plugins from [dirs] relative to [workingDir].
  /// Silently skips invalid/missing directories.
  /// Logs warnings for malformed plugin.json but never throws.
  static Future<List<ShellPluginTool>> load(
    List<String> dirs,
    String workingDir,
  ) async {
    final tools = <ShellPluginTool>[];

    for (final dir in dirs) {
      final absDir = p.isAbsolute(dir) ? dir : p.join(workingDir, dir);
      final pluginsRoot = Directory(absDir);
      if (!await pluginsRoot.exists()) continue;

      try {
        await for (final entry in pluginsRoot.list(followLinks: false)) {
          if (entry is! Directory) continue;
          final tool = await _loadOne(entry);
          if (tool != null) tools.add(tool);
        }
      } catch (_) {
        continue;
      }
    }

    return tools;
  }

  static Future<ShellPluginTool?> _loadOne(Directory pluginDir) async {
    final descriptorFile = File(p.join(pluginDir.path, 'plugin.json'));
    if (!await descriptorFile.exists()) return null;

    Map<String, dynamic> descriptor;
    try {
      final raw = await descriptorFile.readAsString();
      descriptor = (jsonDecode(raw) as Map).cast<String, dynamic>();
    } catch (e) {
      stderr.writeln(
        '[proxima] Warning: malformed plugin.json in ${pluginDir.path}: $e',
      );
      return null;
    }

    // Validate required fields.
    final missingFields = <String>[];
    for (final field in ['name', 'description', 'executable', 'input_schema']) {
      if (!descriptor.containsKey(field) || descriptor[field] == null) {
        missingFields.add(field);
      }
    }
    if (missingFields.isNotEmpty) {
      stderr.writeln(
        '[proxima] Warning: plugin in ${pluginDir.path} missing fields: ${missingFields.join(', ')}',
      );
      return null;
    }

    final execRelative = descriptor['executable'] as String;
    final execPath = p.join(pluginDir.path, execRelative);

    final execFile = File(execPath);
    if (!await execFile.exists()) {
      stderr.writeln(
        '[proxima] Warning: plugin executable not found: $execPath',
      );
      return null;
    }

    // Check executable bit on POSIX. Windows NTFS has no Unix mode bits
    // (stat.mode is always 0), so skip this check there.
    if (!Platform.isWindows) {
      try {
        final stat = await execFile.stat();
        // mode bits: owner execute = 0x40, group = 0x8, other = 0x1
        const execBits = 0x40 | 0x8 | 0x1;
        if ((stat.mode & execBits) == 0) {
          stderr.writeln(
            '[proxima] Warning: plugin executable is not executable: $execPath',
          );
          return null;
        }
      } catch (_) {
        // stat failed — skip
        return null;
      }
    }

    final riskLevel = _parseRiskLevel(descriptor['risk_level'] as String?);
    final timeoutSeconds = descriptor['timeout_seconds'] as int? ?? 30;
    final inputSchema = (descriptor['input_schema'] as Map)
        .cast<String, dynamic>();

    return ShellPluginTool(
      name: descriptor['name'] as String,
      description: descriptor['description'] as String,
      riskLevel: riskLevel,
      inputSchema: inputSchema,
      executable: execPath,
      timeoutSeconds: timeoutSeconds,
    );
  }

  static RiskLevel _parseRiskLevel(String? value) => switch (value) {
    'safe' => RiskLevel.safe,
    'high_risk' => RiskLevel.highRisk,
    'blocked' => RiskLevel.blocked,
    _ => RiskLevel.confirm, // default to confirm for unknown/null
  };
}
