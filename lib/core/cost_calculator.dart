import 'types.dart';

class ModelPricing {
  final double inputPer1M;
  final double outputPer1M;
  const ModelPricing(this.inputPer1M, this.outputPer1M);
}

/// Computes USD cost from token usage for known Anthropic models.
/// Returns 0.0 for Ollama models and unknown models (no charge).
class CostCalculator {
  static const Map<String, ModelPricing> _pricing = {
    'anthropic/claude-opus-4-6': ModelPricing(15.00, 75.00),
    'anthropic/claude-sonnet-4-6': ModelPricing(3.00, 15.00),
    'anthropic/claude-haiku-4-5-20251001': ModelPricing(0.80, 4.00),
  };

  static double compute(String model, TokenUsage usage) {
    if (model.startsWith('ollama/')) return 0.0;
    final p = _pricing[model];
    if (p == null) return 0.0;
    return (usage.inputTokens * p.inputPer1M +
            usage.outputTokens * p.outputPer1M) /
        1000000;
  }

  static String format(double cost) {
    if (cost == 0.0) return r'$0.00';
    return '\$${cost.toStringAsFixed(4)}';
  }
}
