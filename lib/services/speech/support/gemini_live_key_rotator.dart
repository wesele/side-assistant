import '../../../core/models/app_settings.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/gemini_live_key_pool.dart';

/// Gemini Live 服务实例级 Key 轮询与对话上下文续接协调器。
///
/// 由 [GeminiLiveDialogService] 与 [GeminiLiveAsrService] 共同复用，负责：
/// - 从共享 [GeminiLiveKeyPool] 选择可用 Key；
/// - 记录 `usageMetadata` 并标记 80% 阈值后的待切换状态；
/// - 处理 429 限流冷却并判断是否具备可立即接管的备用 Key；
/// - 维护最近对话轮次快照，确保切换 Key（无法沿用旧 sessionResumptionHandle）时可无感续接。
class GeminiLiveKeyRotator {
  final GeminiLiveKeyPool keyPool;
  String? currentApiKey;
  String? _rotateExcludeKey;
  bool pendingKeySwitch = false;
  bool switchingKey = false;
  final List<ChatMessage> _recentTurns = <ChatMessage>[];

  static const int _maxSeedTurns = 20;

  GeminiLiveKeyRotator({GeminiLiveKeyPool? keyPool})
      : keyPool = keyPool ?? GeminiLiveKeyPool.instance;

  List<GeminiApiKeyEntry> resolvePool(AppSettings settings) =>
      keyPool.resolvePool(settings);

  /// 为新连接挑选当前 60s TPM 最低且未冷却/未超阈值的 Key。
  GeminiLiveKeySelection selectForConnect(AppSettings settings) {
    final pool = resolvePool(settings);
    final exclude = _rotateExcludeKey;
    _rotateExcludeKey = null;
    final selection = keyPool.selectKey(pool, excludeKey: exclude);
    if (!selection.exhausted && selection.entry != null) {
      currentApiKey = selection.entry!.apiKey;
      pendingKeySwitch = false;
    }
    return selection;
  }

  /// 上报服务端返回的 `usageMetadata`；若跨过 80% 阈值则置位 [pendingKeySwitch]。
  GeminiLiveKeyStatus? recordUsage(
    AppSettings settings,
    Map<String, dynamic> usageMetadata,
  ) {
    final key = currentApiKey;
    if (key == null || key.isEmpty) return null;
    resolvePool(settings);
    final result = keyPool.recordUsage(key, usageMetadata);
    if (result.overThreshold) {
      pendingKeySwitch = true;
    }
    return result;
  }

  /// 检查当前是否存在除现用 Key 之外的其他可用备用 Key。
  bool hasAlternativeKey(AppSettings settings) {
    final pool = resolvePool(settings);
    if (pool.length <= 1) return false;
    final next = keyPool.selectKey(pool, excludeKey: currentApiKey);
    return !next.exhausted &&
        next.entry != null &&
        next.entry!.apiKey != currentApiKey;
  }

  /// 将当前 Key 标记为 429 冷却并返回是否还有可立即接管的备用 Key。
  ({bool hasAlternative, int waitMs, List<GeminiApiKeyEntry> pool})
      markCurrentRateLimited(AppSettings settings) {
    final pool = resolvePool(settings);
    final key = currentApiKey;
    if (key != null && key.isNotEmpty) {
      keyPool.markRateLimited(key);
      _rotateExcludeKey = key;
    }
    final next = keyPool.selectKey(pool, excludeKey: key);
    return (
      hasAlternative:
          !next.exhausted && next.entry != null && next.entry!.apiKey != key,
      waitMs: next.waitMs,
      pool: pool,
    );
  }

  void prepareExcludeCurrentKey() {
    if (currentApiKey != null && currentApiKey!.isNotEmpty) {
      _rotateExcludeKey = currentApiKey;
    }
    pendingKeySwitch = false;
  }

  /// 清理当前 Key 池的冷却标记，并格式化最终暴露给用户的全池耗尽/配额错误信息。
  String buildExhaustedErrorMessage(
    AppSettings settings,
    String reason,
    int waitMs, {
    bool duringSetup = false,
  }) {
    final trimmed = reason.trim();
    if (GeminiLiveKeyPool.isZeroQuotaError(trimmed)) {
      keyPool.clearRateLimitCooldowns(resolvePool(settings));
      final suffix = trimmed.isNotEmpty ? '：$trimmed' : '';
      return 'Gemini Live 配额受限（limit: 0，常见于免费 Key 未开通计费或当前模型/配额受限）$suffix';
    }
    final detail =
        (duringSetup && trimmed.isNotEmpty) ? '$trimmed（握手阶段触发）' : trimmed;
    return GeminiLiveKeyPool.formatQuotaWaitMessage(waitMs, detail: detail);
  }

  void resetSessionHistory(List<ChatMessage> history, {bool clear = false}) {
    _recentTurns.clear();
    if (!clear) {
      for (final msg in history) {
        if (msg.content.trim().isNotEmpty) {
          _recentTurns.add(msg);
        }
      }
      _trimHistory();
    }
  }

  void recordTurnPair(String userText, String modelText) {
    final u = userText.trim();
    final m = modelText.trim();
    final ts = DateTime.now();
    if (u.isNotEmpty) {
      _recentTurns.add(ChatMessage(
        id: 'turn-u-${ts.microsecondsSinceEpoch}',
        role: 'user',
        content: u,
        timestamp: ts,
      ));
    }
    if (m.isNotEmpty) {
      _recentTurns.add(ChatMessage(
        id: 'turn-m-${ts.microsecondsSinceEpoch}',
        role: 'assistant',
        content: m,
        timestamp: ts,
      ));
    }
    _trimHistory();
  }

  List<ChatMessage> snapshotHistory() => List<ChatMessage>.of(_recentTurns);

  void _trimHistory() {
    if (_recentTurns.length > _maxSeedTurns) {
      _recentTurns.removeRange(0, _recentTurns.length - _maxSeedTurns);
    }
  }
}
