import 'package:test/test.dart';
import 'package:proxima/core/cost_calculator.dart';
import 'package:proxima/core/types.dart';

void main() {
  group('CostCalculator.compute', () {
    test('known Anthropic sonnet model returns correct USD', () {
      const usage = TokenUsage(
        inputTokens: 1000,
        outputTokens: 500,
        totalTokens: 1500,
      );
      // sonnet: $3.00/1M input, $15.00/1M output
      // (1000 * 3.00 + 500 * 15.00) / 1_000_000 = (3000 + 7500) / 1_000_000 = 0.0105
      final cost = CostCalculator.compute('anthropic/claude-sonnet-4-6', usage);
      expect(cost, closeTo(0.0105, 0.000001));
    });

    test('known Anthropic opus model returns correct USD', () {
      const usage = TokenUsage(
        inputTokens: 100,
        outputTokens: 100,
        totalTokens: 200,
      );
      // opus: $15.00/1M input, $75.00/1M output
      // (100 * 15.00 + 100 * 75.00) / 1_000_000 = 9000 / 1_000_000 = 0.009
      final cost = CostCalculator.compute('anthropic/claude-opus-4-6', usage);
      expect(cost, closeTo(0.009, 0.000001));
    });

    test('known Anthropic haiku model returns correct USD', () {
      const usage = TokenUsage(
        inputTokens: 1000000,
        outputTokens: 1000000,
        totalTokens: 2000000,
      );
      // haiku: $0.80/1M input, $4.00/1M output
      // (1000000 * 0.80 + 1000000 * 4.00) / 1_000_000 = 4.80
      final cost = CostCalculator.compute(
        'anthropic/claude-haiku-4-5-20251001',
        usage,
      );
      expect(cost, closeTo(4.80, 0.000001));
    });

    test('ollama/ model always returns 0.0', () {
      const usage = TokenUsage(
        inputTokens: 100000,
        outputTokens: 50000,
        totalTokens: 150000,
      );
      final cost = CostCalculator.compute('ollama/llama3.2', usage);
      expect(cost, 0.0);
    });

    test('unknown model returns 0.0', () {
      const usage = TokenUsage(
        inputTokens: 1000,
        outputTokens: 500,
        totalTokens: 1500,
      );
      final cost = CostCalculator.compute('unknown/model', usage);
      expect(cost, 0.0);
    });

    test('zero usage returns 0.0', () {
      final cost = CostCalculator.compute(
        'anthropic/claude-sonnet-4-6',
        TokenUsage.zero,
      );
      expect(cost, 0.0);
    });
  });

  group('CostCalculator.format', () {
    test('0.0 formats as \$0.00', () {
      expect(CostCalculator.format(0.0), r'$0.00');
    });

    test('small value formats to 4 decimal places', () {
      expect(CostCalculator.format(0.000412), r'$0.0004');
    });

    test('larger value formats to 4 decimal places', () {
      expect(CostCalculator.format(1.2345), r'$1.2345');
    });

    test('non-zero very small value is not \$0.00', () {
      // 0.00001 should not be displayed as $0.00
      final formatted = CostCalculator.format(0.00001);
      expect(formatted, isNot(r'$0.00'));
    });
  });
}
