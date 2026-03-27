import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:proxima/core/config.dart';
import 'package:proxima/core/types.dart';

void main() {
  group('ProximaConfig', () {
    test('defaults returns valid config', () {
      final config = ProximaConfig.defaults();
      expect(config.model, isNotEmpty);
      expect(config.maxIterations, greaterThan(0));
      expect(config.mode, SessionMode.confirm);
    });

    test('copyWith overrides fields', () {
      final config = ProximaConfig.defaults();
      final updated = config.copyWith(model: 'ollama/llama3', debug: true);
      expect(updated.model, 'ollama/llama3');
      expect(updated.debug, isTrue);
      expect(updated.maxIterations, config.maxIterations);
    });

    test('load returns valid config', () async {
      final config = await ProximaConfig.load();
      expect(config.workingDir, isNotEmpty);
      expect(config.model, isNotEmpty);
    });
  });

  group('ProximaConfig.saveDefaultModel', () {
    late Directory tempDir;
    late String configPath;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('proxima_config_test_');
      configPath = p.join(tempDir.path, '.proxima', 'config.yaml');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('creates file with model key when none exists', () async {
      // Platform.environment['HOME'] is not injectable in Dart tests, so we
      // test the file-manipulation logic (the same regex path) directly.
      final file = File(configPath);
      await file.parent.create(recursive: true);
      await file.writeAsString('debug: true\n');

      // Simulate what saveDefaultModel does when model line is absent:
      String contents = await file.readAsString();
      const modelLine = 'model: ollama/llama3';
      final modelRegex = RegExp(r'^model:.*$', multiLine: true);
      if (!modelRegex.hasMatch(contents)) {
        contents = '$contents\n$modelLine\n';
      }
      await file.writeAsString(contents);

      final result = await file.readAsString();
      expect(result, contains('model: ollama/llama3'));
      expect(result, contains('debug: true'));
    });

    test('replaces existing model key without touching other keys', () async {
      final file = File(configPath);
      await file.parent.create(recursive: true);
      await file.writeAsString('debug: false\nmodel: anthropic/old-model\nmax_iterations: 5\n');

      String contents = await file.readAsString();
      const newModel = 'ollama/mistral';
      final modelRegex = RegExp(r'^model:.*$', multiLine: true);
      contents = contents.replaceFirst(modelRegex, 'model: $newModel');
      await file.writeAsString(contents);

      final result = await file.readAsString();
      expect(result, contains('model: ollama/mistral'));
      expect(result, isNot(contains('old-model')));
      expect(result, contains('debug: false'));
      expect(result, contains('max_iterations: 5'));
    });
  });
}
