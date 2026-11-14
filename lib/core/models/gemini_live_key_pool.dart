import 'dart:math' as math;

import '../constants/app_constants.dart';
import 'app_settings.dart';

class _TpmUsageEvent {
  final int tsMs;
  final int tokens;

  const _TpmUsageEvent({required this.tsMs, required this.tokens});
}

/// 单个 Gemini Live Key 在 60s 滑动窗口内的实时 TPM 与限流冷却状态
class GeminiLiveKeyStatus {
  final String apiKey;
  final GeminiApiKeyEntry entry;
  final int tpm;
  final int limit;
  final double thresholdTokens;
  final double ratio;
  final bool overThreshold;
  final bool coolingDown;
  final int cooldownRemainingMs;
  final int waitMs;

  const GeminiLiveKeyStatus({
    required this.apiKey,
    required this.entry,
    required this.tpm,
    required this.limit,
    required this.thresholdTokens,
    required this.ratio,
    required this.overThreshold,
    required this.coolingDown,
    required this.cooldownRemainingMs,
    required this.waitMs,
  });

  bool get isEligible => !overThreshold && !coolingDown;

  Map<String, dynamic> toMap() => {
        'id': entry.id,
        'label': entry.label,
        'apiKey': apiKey,
        'tpm': tpm,
        'limit': limit,
        'thresholdTokens': thresholdTokens,
        'ratio': ratio,
        'overThreshold': overThreshold,
        'coolingDown': coolingDown,
        'cooldownRemainingMs': cooldownRemainingMs,
        'waitMs': waitMs,
      };
}

/// Key 池调度选择结果
class GeminiLiveKeySelection {
  final String? key;
  final GeminiApiKeyEntry? entry;
  final GeminiLiveKeyStatus? status;
  final bool exhausted;
  final int waitMs;

  const GeminiLiveKeySelection({
    required this.key,
    required this.entry,
    required this.status,
    required this.exhausted,
    required this.waitMs,
  });
}

/// Gemini Live 多 Key 轮询与 60s 滑动窗口 TPM 流控池
///
/// 参考 idiom 项目的 `geminiLiveKeyPool` 实现：
/// - 支持多个不同 GCP 项目的 API Key 及其独立的 TPM 限额（默认 65,000 TPM）；
/// - 按 60s 滑动窗口累计 `usageMetadata` token 用量，达到 80% 阈值后在当前轮次结束时平滑切换；
/// - 遇到 429 / RESOURCE_EXHAUSTED / quota 限流错误时对该 Key 施加 60s 冷却并立即切换备用 Key；
/// - 优先选择当前 60s TPM 最低的可用 Key，若均达到上限则计算精确等待秒数并提示用户。
class GeminiLiveKeyPool {
  static final GeminiLiveKeyPool instance = GeminiLiveKeyPool();

  final DateTime Function()? _clock;
  final Map<String, List<_TpmUsageEvent>> _usageByKey = {};
  final Map<String, int> _rateLimitedUntilMs = {};
  final Map<String, int> _limitsByKey = {};
  final Set<void Function()> _listeners = <void Function()>{};

  GeminiLiveKeyPool({DateTime Function()? clock}) : _clock = clock;

  DateTime _now() => _clock?.call() ?? DateTime.now();

  void addListener(void Function() listener) {
    _listeners.add(listener);
  }

  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }

  void _notifyListeners() {
    for (final fn in List<void Function()>.of(_listeners)) {
      try {
        fn();
      } catch (_) {}
    }
  }

  /// 清空所有 TPM 计数与限流冷却记录（主要用于测试隔离）
  void reset() {
    _usageByKey.clear();
    _rateLimitedUntilMs.clear();
    _limitsByKey.clear();
    _notifyListeners();
  }

  /// 规范化 Key 池并同步注册每个 Key 的 TPM 上限
  List<GeminiApiKeyEntry> normalizeKeys(
    dynamic entries, {
    String fallbackApiKey = '',
  }) {
    final normalized = GeminiApiKeyEntry.normalizeList(
      entries,
      fallbackApiKey: fallbackApiKey,
    );
    final result = <GeminiApiKeyEntry>[];
    for (final entry in normalized) {
      final hasExplicitEntries = entries is Iterable && entries.isNotEmpty ||
          (entries is String && entries.trim().isNotEmpty);
      if (entry.id == 'default' && !hasExplicitEntries) {
        final knownLimit = _limitsByKey[entry.apiKey];
        if (knownLimit != null && knownLimit > 0) {
          result.add(entry.copyWith(tpmLimit: knownLimit));
          continue;
        }
      }
      _limitsByKey[entry.apiKey] = entry.tpmLimit;
      result.add(entry);
    }
    return result;
  }

  /// 从 [AppSettings] 解析可用的 Key 池
  List<GeminiApiKeyEntry> resolvePool(AppSettings settings) => normalizeKeys(
        settings.geminiApiKeys,
        fallbackApiKey: settings.geminiApiKey,
      );

  /// 从服务端 JSON 消息或 `usageMetadata` 字典中提取 token 数量
  static int extractUsageTokens(dynamic messageOrUsage) {
    if (messageOrUsage is num) {
      final v = messageOrUsage.round();
      return v > 0 ? v : 0;
    }
    if (messageOrUsage is! Map) return 0;

    final dynamic rawUsage = messageOrUsage['usageMetadata'] ??
        messageOrUsage['usage_metadata'] ??
        messageOrUsage;
    if (rawUsage is! Map) return 0;

    final total = _asInt(
      rawUsage['totalTokenCount'] ?? rawUsage['total_token_count'],
    );
    if (total > 0) return total;

    final prompt = _asInt(
      rawUsage['promptTokenCount'] ?? rawUsage['prompt_token_count'],
    );
    final response = _asInt(
      rawUsage['responseTokenCount'] ??
          rawUsage['response_token_count'] ??
          rawUsage['candidatesTokenCount'] ??
          rawUsage['candidates_token_count'],
    );
    final thoughts = _asInt(
      rawUsage['thoughtsTokenCount'] ?? rawUsage['thoughts_token_count'],
    );
    final toolPrompt = _asInt(
      rawUsage['toolUsePromptTokenCount'] ??
          rawUsage['tool_use_prompt_token_count'],
    );
    final sum = prompt + response + thoughts + toolPrompt;
    return sum > 0 ? sum : 0;
  }

  static int _asInt(dynamic value) {
    if (value is num && value.isFinite) return value.round();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  static final RegExp _http429Pattern = RegExp(r'(?:^|\D)429(?:\D|$)');
  static final RegExp _zeroLimitPattern = RegExp(r'limit\s*:\s*0(?:\D|$)');

  static String _extractErrorText(Object? errOrMessage) {
    if (errOrMessage == null) return '';
    if (errOrMessage is String) return errOrMessage.toLowerCase();
    if (errOrMessage is StateError) return errOrMessage.message.toLowerCase();
    if (errOrMessage is Map) {
      return (errOrMessage['message'] ?? errOrMessage['status'] ?? errOrMessage)
          .toString()
          .toLowerCase();
    }
    return errOrMessage.toString().toLowerCase();
  }

  /// 判断错误描述或关闭原因是否属于 HTTP 429 / 配额限流错误
  static bool isRateLimitError(Object? errOrMessage) {
    final text = _extractErrorText(errOrMessage);
    if (text.isEmpty) return false;
    return _http429Pattern.hasMatch(text) ||
        text.contains('resource_exhausted') ||
        text.contains('resource has been exhausted') ||
        text.contains('resource exhausted') ||
        text.contains('quota') ||
        text.contains('rate limit') ||
        text.contains('too many requests');
  }

  /// 判断是否属于 `limit: 0` 类的永久配额归零错误（常见于免费 Key 未开通计费或受限工具）
  static bool isZeroQuotaError(Object? errOrMessage) {
    final text = _extractErrorText(errOrMessage);
    return text.isNotEmpty && _zeroLimitPattern.hasMatch(text);
  }

  List<_TpmUsageEvent> _pruneEvents(List<_TpmUsageEvent>? events, int nowMs) {
    if (events == null || events.isEmpty) return <_TpmUsageEvent>[];
    final cutoff = nowMs - AppConstants.geminiLiveTpmWindowMs;
    return events
        .where((ev) => ev.tsMs > cutoff && ev.tokens > 0)
        .toList(growable: true);
  }

  /// 获取单个 Key（传入 [GeminiApiKeyEntry] 或原始 apiKey 字符串）的实时 TPM 与冷却状态
  GeminiLiveKeyStatus getKeyStatus(dynamic entryOrKey, {DateTime? now}) {
    final nowMs = (now ?? _now()).millisecondsSinceEpoch;
    final GeminiApiKeyEntry? obj =
        entryOrKey is GeminiApiKeyEntry ? entryOrKey : null;
    final apiKey =
        (obj != null ? obj.apiKey : entryOrKey?.toString() ?? '').trim();

    final int limit;
    if (obj != null && obj.tpmLimit > 0) {
      limit = obj.tpmLimit;
      if (apiKey.isNotEmpty) {
        _limitsByKey[apiKey] = limit;
      }
    } else {
      limit = (apiKey.isNotEmpty ? _limitsByKey[apiKey] : null) ??
          AppConstants.defaultGeminiLiveTpmLimit;
    }

    final events = apiKey.isNotEmpty
        ? _pruneEvents(_usageByKey[apiKey], nowMs)
        : <_TpmUsageEvent>[];
    if (apiKey.isNotEmpty) {
      if (events.isNotEmpty) {
        _usageByKey[apiKey] = events;
      } else {
        _usageByKey.remove(apiKey);
      }
    }

    var tpm = 0;
    for (final ev in events) {
      tpm += ev.tokens;
    }

    final thresholdTokens = limit * AppConstants.geminiLiveTpmThresholdRatio;
    final ratio = limit > 0 ? tpm / limit : 0.0;

    final cooldownUntil =
        apiKey.isNotEmpty ? (_rateLimitedUntilMs[apiKey] ?? 0) : 0;
    if (apiKey.isNotEmpty && cooldownUntil > 0 && cooldownUntil <= nowMs) {
      _rateLimitedUntilMs.remove(apiKey);
    }
    final cooldownRemainingMs =
        cooldownUntil > nowMs ? cooldownUntil - nowMs : 0;
    final coolingDown = cooldownRemainingMs > 0;
    final overThreshold = tpm >= thresholdTokens;

    var waitMs = cooldownRemainingMs;
    if (overThreshold && events.isNotEmpty) {
      final sorted = List<_TpmUsageEvent>.of(events)
        ..sort((a, b) => a.tsMs.compareTo(b.tsMs));
      var remaining = tpm;
      for (final ev in sorted) {
        remaining -= ev.tokens;
        if (remaining < thresholdTokens) {
          waitMs = math.max(
            waitMs,
            ev.tsMs + AppConstants.geminiLiveTpmWindowMs - nowMs,
          );
          break;
        }
      }
      if (remaining >= thresholdTokens) {
        waitMs = math.max(
          waitMs,
          sorted.last.tsMs + AppConstants.geminiLiveTpmWindowMs - nowMs,
        );
      }
    }

    return GeminiLiveKeyStatus(
      apiKey: apiKey,
      entry: obj ?? GeminiApiKeyEntry(apiKey: apiKey, tpmLimit: limit),
      tpm: tpm,
      limit: limit,
      thresholdTokens: thresholdTokens,
      ratio: ratio,
      overThreshold: overThreshold,
      coolingDown: coolingDown,
      cooldownRemainingMs: cooldownRemainingMs,
      waitMs: math.max(0, waitMs),
    );
  }

  /// 获取整个配置 Key 池的状态列表
  List<GeminiLiveKeyStatus> getPoolStatuses(
    AppSettings settings, {
    DateTime? now,
  }) {
    final pool = resolvePool(settings);
    return pool.map((e) => getKeyStatus(e, now: now)).toList(growable: false);
  }

  List<Map<String, dynamic>> getPoolStatusMaps(
    AppSettings settings, {
    DateTime? now,
  }) {
    return getPoolStatuses(settings, now: now)
        .map((s) => s.toMap())
        .toList(growable: false);
  }

  bool isKeyCoolingDown(String apiKey, {DateTime? now}) =>
      getKeyStatus(apiKey, now: now).coolingDown;

  /// 记录某 Key 的一次 token 消耗（支持完整服务端消息、usageMetadata 或整数）
  GeminiLiveKeyStatus recordUsage(
    String apiKey,
    dynamic messageOrTokens, {
    DateTime? now,
  }) {
    final nowDate = now ?? _now();
    final nowMs = nowDate.millisecondsSinceEpoch;
    final key = apiKey.trim();
    final tokens = extractUsageTokens(messageOrTokens);
    if (key.isEmpty || tokens <= 0) {
      return getKeyStatus(key, now: nowDate);
    }
    final existing = _pruneEvents(_usageByKey[key], nowMs);
    existing.add(_TpmUsageEvent(tsMs: nowMs, tokens: tokens));
    _usageByKey[key] = existing;
    _notifyListeners();
    return getKeyStatus(key, now: nowDate);
  }

  /// 标记某 Key 触发了 429/限流，使其进入冷却期（默认 60s）
  void markRateLimited(
    String apiKey, {
    Duration cooldown = const Duration(
      milliseconds: AppConstants.geminiLiveRateLimitCooldownMs,
    ),
    DateTime? now,
  }) {
    final nowMs = (now ?? _now()).millisecondsSinceEpoch;
    final key = apiKey.trim();
    if (key.isEmpty) return;
    final ms = math.max(1000, cooldown.inMilliseconds);
    _rateLimitedUntilMs[key] = nowMs + ms;
    _notifyListeners();
  }

  /// 清除指定 Key 集合的 429 冷却标记（用于区分配置/工具零配额与临时并发限流）
  void clearRateLimitCooldowns(Iterable<GeminiApiKeyEntry> entries) {
    var changed = false;
    for (final e in entries) {
      if (_rateLimitedUntilMs.remove(e.apiKey) != null) {
        changed = true;
      }
    }
    if (changed) _notifyListeners();
  }

  /// 从 Key 池中选择最适合的可用 Key：
  /// - 过滤掉 60s TPM >= 80% 上限或正处于冷却中的 Key；
  /// - 在可用 Key 中挑选当前 60s TPM 最低者（同等用量优先避开 [excludeKey]）；
  /// - 若全部不可用，返回 `exhausted: true` 及最短可恢复等待时间 `waitMs`。
  GeminiLiveKeySelection selectKey(
    List<GeminiApiKeyEntry> entries, {
    String? excludeKey,
    DateTime? now,
  }) {
    final pool = normalizeKeys(entries);
    if (pool.isEmpty) {
      return const GeminiLiveKeySelection(
        key: null,
        entry: null,
        status: null,
        exhausted: false,
        waitMs: 0,
      );
    }

    final statuses = pool.map((e) => getKeyStatus(e, now: now)).toList();
    final eligible = statuses.where((s) => s.isEligible).toList();

    if (eligible.isEmpty) {
      final positiveWaits =
          statuses.map((s) => s.waitMs).where((w) => w > 0).toList();
      final minWaitMs =
          positiveWaits.isNotEmpty ? positiveWaits.reduce(math.min) : 5000;
      return GeminiLiveKeySelection(
        key: null,
        entry: null,
        status: null,
        exhausted: true,
        waitMs: minWaitMs,
      );
    }

    final exclude = (excludeKey ?? '').trim();
    eligible.sort((a, b) {
      if (a.tpm != b.tpm) return a.tpm.compareTo(b.tpm);
      if (exclude.isNotEmpty) {
        final aSame = a.apiKey == exclude ? 1 : 0;
        final bSame = b.apiKey == exclude ? 1 : 0;
        if (aSame != bSame) return aSame.compareTo(bSame);
      }
      return 0;
    });

    final best = eligible.first;
    return GeminiLiveKeySelection(
      key: best.apiKey,
      entry: best.entry,
      status: best,
      exhausted: false,
      waitMs: 0,
    );
  }

  /// 生成全池达到 TPM 阈值/冷却上限时的友好等待提示；若传入原始错误则保留详情避免误导排查
  static String formatQuotaWaitMessage(int waitMs, {String? detail}) {
    final seconds = math.max(1, (waitMs / 1000).ceil());
    final base =
        '所有 Gemini Live API Key 均已达到 80% TPM 上限或触发限流，请约 $seconds 秒后再试（可添加更多不同 GCP 项目的 Key）';
    final trimmed = detail?.trim() ?? '';
    return trimmed.isEmpty ? base : '$base：$trimmed';
  }
}
