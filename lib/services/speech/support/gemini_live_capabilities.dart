/// Gemini Live 能力与模式解析器（纯 Dart，无外部依赖）
class GeminiLiveCapabilities {
  const GeminiLiveCapabilities._();

  /// 解析是否启用 Gemini Live 深度思考（Advanced）模式：
  /// - mode 为 'advanced' → true
  /// - mode 为 'basic' → false
  /// - 其余（如 'auto' 或未知） → 根据 model 是否包含 'extended-thinking' (大小写不敏感) 自动判定
  static bool resolveAdvanced({
    required String mode,
    required String model,
  }) {
    final m = mode.trim().toLowerCase();
    if (m == 'advanced') return true;
    if (m == 'basic') return false;
    return model.toLowerCase().contains('extended-thinking');
  }

  /// 规范化思考深度：仅允许 'low' | 'medium' | 'high'，默认回退至 'medium'
  static String normalizeThinkingLevel(String level) {
    switch (level.trim().toLowerCase()) {
      case 'low':
        return 'low';
      case 'high':
        return 'high';
      case 'medium':
      default:
        return 'medium';
    }
  }
}
