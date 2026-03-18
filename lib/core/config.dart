import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';
import 'types.dart';

/// Proxima runtime configuration.
class ProximaConfig {
  final String model;
  final String workingDir;
  final SessionMode mode;
  final bool debug;
  final bool dryRun;
  final int maxIterations;
  final int maxRetriesTool;
  final int maxRetriesLlm;
  final int maxRetriesSchema;
  final String? anthropicApiKey;
  final String? ollamaBaseUrl;
  final Map<String, dynamic> raw;

  const ProximaConfig({
    required this.model,
    required this.workingDir,
    required this.mode,
    required this.debug,
    required this.dryRun,
    required this.maxIterations,
    required this.maxRetriesTool,
    required this.maxRetriesLlm,
    required this.maxRetriesSchema,
    this.anthropicApiKey,
    this.ollamaBaseUrl,
    this.raw = const {},
  });

  static ProximaConfig defaults() => ProximaConfig(
    model: 'anthropic/claude-sonnet-4-6',
    workingDir: Directory.current.path,
    mode: SessionMode.confirm,
    debug: false,
    dryRun: false,
    maxIterations: 10,
    maxRetriesTool: 3,
    maxRetriesLlm: 2,
    maxRetriesSchema: 2,
    anthropicApiKey: Platform.environment['ANTHROPIC_API_KEY'],
    ollamaBaseUrl:
        Platform.environment['OLLAMA_BASE_URL'] ?? 'http://localhost:11434',
  );

  /// Load config: start with defaults, merge user config, then project config.
  static Future<ProximaConfig> load({String? workingDir}) async {
    var config = ProximaConfig.defaults();
    final wd = workingDir ?? config.workingDir;

    // User config: ~/.proxima/config.yaml
    final userConfigPath = p.join(
      Platform.environment['HOME'] ?? '',
      '.proxima',
      'config.yaml',
    );
    config = await _mergeFromFile(config, userConfigPath, wd);

    // Project config: <workingDir>/.proxima/config.yaml (takes precedence)
    final projectConfigPath = p.join(wd, '.proxima', 'config.yaml');
    config = await _mergeFromFile(config, projectConfigPath, wd);

    return config.copyWith(workingDir: wd);
  }

  static Future<ProximaConfig> _mergeFromFile(
    ProximaConfig base,
    String filePath,
    String workingDir,
  ) async {
    final file = File(filePath);
    if (!await file.exists()) return base;

    try {
      final content = await file.readAsString();
      final yaml = loadYaml(content);
      if (yaml is! YamlMap) return base;
      return base._mergeYaml(yaml, workingDir);
    } catch (e) {
      stderr.writeln('[proxima] Warning: could not load config $filePath: $e');
      return base;
    }
  }

  ProximaConfig _mergeYaml(YamlMap yaml, String workingDir) {
    SessionMode parseMode(String? s) => switch (s) {
      'safe' => SessionMode.safe,
      'auto' => SessionMode.auto,
      _ => SessionMode.confirm,
    };

    return ProximaConfig(
      model: yaml['model'] as String? ?? model,
      workingDir: workingDir,
      mode: parseMode(yaml['mode'] as String?),
      debug: yaml['debug'] as bool? ?? debug,
      dryRun: yaml['dry_run'] as bool? ?? dryRun,
      maxIterations: yaml['max_iterations'] as int? ?? maxIterations,
      maxRetriesTool: yaml['max_retries_tool'] as int? ?? maxRetriesTool,
      maxRetriesLlm: yaml['max_retries_llm'] as int? ?? maxRetriesLlm,
      maxRetriesSchema: yaml['max_retries_schema'] as int? ?? maxRetriesSchema,
      anthropicApiKey: yaml['anthropic_api_key'] as String? ?? anthropicApiKey,
      ollamaBaseUrl: yaml['ollama_base_url'] as String? ?? ollamaBaseUrl,
      raw: Map<String, dynamic>.from(yaml.value),
    );
  }

  ProximaConfig copyWith({
    String? model,
    String? workingDir,
    SessionMode? mode,
    bool? debug,
    bool? dryRun,
    int? maxIterations,
    String? anthropicApiKey,
    String? ollamaBaseUrl,
  }) => ProximaConfig(
    model: model ?? this.model,
    workingDir: workingDir ?? this.workingDir,
    mode: mode ?? this.mode,
    debug: debug ?? this.debug,
    dryRun: dryRun ?? this.dryRun,
    maxIterations: maxIterations ?? this.maxIterations,
    maxRetriesTool: maxRetriesTool,
    maxRetriesLlm: maxRetriesLlm,
    maxRetriesSchema: maxRetriesSchema,
    anthropicApiKey: anthropicApiKey ?? this.anthropicApiKey,
    ollamaBaseUrl: ollamaBaseUrl ?? this.ollamaBaseUrl,
    raw: raw,
  );
}
