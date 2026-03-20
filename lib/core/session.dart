import 'dart:convert';
import 'dart:math';
import 'package:collection/collection.dart';
import 'types.dart';
import 'config.dart';

/// A single task execution record.
class TaskRecord {
  final String toolName;
  final Map<String, dynamic> args;
  final String? backupPath;
  final DateTime timestamp;
  final bool success;

  const TaskRecord({
    required this.toolName,
    required this.args,
    this.backupPath,
    required this.timestamp,
    required this.success,
  });

  Map<String, dynamic> toJson() => {
    'tool_name': toolName,
    'args': args,
    if (backupPath != null) 'backup_path': backupPath,
    'timestamp': timestamp.toIso8601String(),
    'success': success,
  };

  factory TaskRecord.fromJson(Map<String, dynamic> json) => TaskRecord(
    toolName: json['tool_name'] as String,
    args: Map<String, dynamic>.from(json['args'] as Map),
    backupPath: json['backup_path'] as String?,
    timestamp: DateTime.parse(json['timestamp'] as String),
    success: json['success'] as bool,
  );
}

/// Permissions granted for this session (e.g., /allow tool).
class SessionPermissions {
  final Set<String> allowedTools;
  final Set<String> allowedCommands;
  final Set<String> deniedTools;
  final List<String> ignoredPatterns;

  const SessionPermissions({
    this.allowedTools = const {},
    this.allowedCommands = const {},
    this.deniedTools = const {},
    this.ignoredPatterns = const [],
  });

  SessionPermissions withAllowedTool(String tool) => SessionPermissions(
    allowedTools: {...allowedTools, tool},
    allowedCommands: allowedCommands,
    deniedTools: deniedTools,
    ignoredPatterns: ignoredPatterns,
  );

  SessionPermissions withAllowedCommand(String command) => SessionPermissions(
    allowedTools: allowedTools,
    allowedCommands: {...allowedCommands, command},
    deniedTools: deniedTools,
    ignoredPatterns: ignoredPatterns,
  );

  SessionPermissions withDeniedTool(String tool) => SessionPermissions(
    allowedTools: allowedTools,
    allowedCommands: allowedCommands,
    deniedTools: {...deniedTools, tool},
    ignoredPatterns: ignoredPatterns,
  );

  SessionPermissions withIgnoredPattern(String pattern) => SessionPermissions(
    allowedTools: allowedTools,
    allowedCommands: allowedCommands,
    deniedTools: deniedTools,
    ignoredPatterns: [...ignoredPatterns, pattern],
  );

  Map<String, dynamic> toJson() => {
    'allowed_tools': allowedTools.toList(),
    'allowed_commands': allowedCommands.toList(),
    'denied_tools': deniedTools.toList(),
    'ignored_patterns': ignoredPatterns,
  };

  factory SessionPermissions.fromJson(
    Map<String, dynamic> json,
  ) => SessionPermissions(
    allowedTools: Set<String>.from(json['allowed_tools'] as List? ?? []),
    allowedCommands: Set<String>.from(json['allowed_commands'] as List? ?? []),
    deniedTools: Set<String>.from(json['denied_tools'] as List? ?? []),
    ignoredPatterns: List<String>.from(json['ignored_patterns'] as List? ?? []),
  );
}

/// The stateful source of truth for a Proxima session.
class ProximaSession {
  final String id;
  final DateTime createdAt;
  DateTime updatedAt;
  final String workingDir;
  final String model;
  SessionMode mode;
  final List<Message> history;
  final List<TaskRecord> taskHistory;
  SessionPermissions permissions;
  TokenUsage cumulativeUsage;
  int iterationCount;
  TaskStatus status;

  ProximaSession({
    required this.id,
    required this.createdAt,
    required this.updatedAt,
    required this.workingDir,
    required this.model,
    required this.mode,
    List<Message>? history,
    List<TaskRecord>? taskHistory,
    SessionPermissions? permissions,
    TokenUsage? cumulativeUsage,
    this.iterationCount = 0,
    this.status = TaskStatus.running,
  }) : history = history ?? [],
       taskHistory = taskHistory ?? [],
       permissions = permissions ?? const SessionPermissions(),
       cumulativeUsage = cumulativeUsage ?? TokenUsage.zero;

  factory ProximaSession.create(ProximaConfig config) {
    final now = DateTime.now();
    return ProximaSession(
      id: _generateId(now),
      createdAt: now,
      updatedAt: now,
      workingDir: config.workingDir,
      model: config.model,
      mode: config.mode,
    );
  }

  static String _generateId(DateTime now) {
    final ts = now.millisecondsSinceEpoch;
    final suffix = Random().nextInt(0xFFFF).toRadixString(16).padLeft(4, '0');
    return 'session_${ts}_$suffix';
  }

  void addMessage(Message message) {
    history.add(message);
    updatedAt = DateTime.now();
  }

  void addTaskRecord(TaskRecord record) {
    taskHistory.add(record);
    updatedAt = DateTime.now();
  }

  void recordUsage(TokenUsage usage) {
    cumulativeUsage = cumulativeUsage + usage;
    updatedAt = DateTime.now();
  }

  /// Find the most recent backup for a given file path (for undo).
  String? findBackup(String filePath) {
    return taskHistory.reversed
        .firstWhereOrNull(
          (r) => r.args['path'] == filePath && r.backupPath != null,
        )
        ?.backupPath;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
    'working_dir': workingDir,
    'model': model,
    'mode': mode.name,
    'history': history.map((m) => m.toJson()).toList(),
    'task_history': taskHistory.map((r) => r.toJson()).toList(),
    'permissions': permissions.toJson(),
    'cumulative_usage': cumulativeUsage.toJson(),
    'iteration_count': iterationCount,
    'status': status.name,
  };

  factory ProximaSession.fromJson(Map<String, dynamic> json) => ProximaSession(
    id: json['id'] as String,
    createdAt: DateTime.parse(json['created_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
    workingDir: json['working_dir'] as String,
    model: json['model'] as String,
    mode: SessionMode.values.byName(json['mode'] as String),
    history:
        (json['history'] as List<dynamic>?)
            ?.map((m) => Message.fromJson(Map<String, dynamic>.from(m as Map)))
            .toList() ??
        [],
    taskHistory:
        (json['task_history'] as List<dynamic>?)
            ?.map(
              (r) => TaskRecord.fromJson(Map<String, dynamic>.from(r as Map)),
            )
            .toList() ??
        [],
    permissions: json['permissions'] != null
        ? SessionPermissions.fromJson(
            Map<String, dynamic>.from(json['permissions'] as Map),
          )
        : const SessionPermissions(),
    cumulativeUsage: json['cumulative_usage'] != null
        ? TokenUsage.fromJson(
            Map<String, dynamic>.from(json['cumulative_usage'] as Map),
          )
        : TokenUsage.zero,
    iterationCount: json['iteration_count'] as int? ?? 0,
    status: TaskStatus.values.byName(json['status'] as String? ?? 'running'),
  );

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());
}
