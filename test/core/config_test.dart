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
}
