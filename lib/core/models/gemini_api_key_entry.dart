import 'dart:convert';

import '../constants/app_constants.dart';

/// 单个 Gemini Live API Key 池条目（支持多 GCP 项目独立配额与自定义 TPM 上限）
class GeminiApiKeyEntry {
  final String id;
  final String label;
  final String apiKey;
  final int tpmLimit;

  const GeminiApiKeyEntry({
    this.id = '',
    this.label = '',
    required this.apiKey,
    this.tpmLimit = AppConstants.defaultGeminiLiveTpmLimit,
  });

  GeminiApiKeyEntry copyWith({
    String? id,
    String? label,
    String? apiKey,
    int? tpmLimit,
  }) =>
      GeminiApiKeyEntry(
        id: id ?? this.id,
        label: label ?? this.label,
        apiKey: apiKey ?? this.apiKey,
        tpmLimit: tpmLimit ?? this.tpmLimit,
      );

  factory GeminiApiKeyEntry.fromMap(Map<String, dynamic> map, {int index = 0}) {
    final rawKey = (map['apiKey'] ?? map['api_key'] ?? '').toString().trim();
    final rawId = (map['id'] ?? '').toString().trim();
    final rawLabel = (map['label'] ?? '').toString().trim();
    final rawLimit = map['tpmLimit'] ?? map['tpm_limit'];
    final parsedLimit = rawLimit is num
        ? rawLimit.round()
        : int.tryParse(rawLimit?.toString() ?? '') ?? 0;
    return GeminiApiKeyEntry(
      id: rawId.isNotEmpty ? rawId : 'key-${index + 1}',
      label: rawLabel,
      apiKey: rawKey,
      tpmLimit: parsedLimit > 0
          ? parsedLimit
          : AppConstants.defaultGeminiLiveTpmLimit,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
        'apiKey': apiKey,
        'tpmLimit': tpmLimit,
      };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GeminiApiKeyEntry &&
          id == other.id &&
          label == other.label &&
          apiKey == other.apiKey &&
          tpmLimit == other.tpmLimit);

  @override
  int get hashCode => Object.hash(id, label, apiKey, tpmLimit);

  /// 规范化 Key 池列表（支持对象列表 / Map 列表 / JSON 字符串）并可选兜底回退到单 Key
  static List<GeminiApiKeyEntry> normalizeList(
    dynamic rawEntries, {
    String fallbackApiKey = '',
  }) {
    dynamic list = rawEntries;
    if (list is String) {
      final trimmed = list.trim();
      if (trimmed.isEmpty) {
        list = const [];
      } else {
        try {
          list = jsonDecode(trimmed);
        } catch (_) {
          list = const [];
        }
      }
    }

    final normalized = <GeminiApiKeyEntry>[];
    final seen = <String>{};

    if (list is Iterable) {
      for (final raw in list) {
        if (raw == null) continue;
        GeminiApiKeyEntry? entry;
        if (raw is GeminiApiKeyEntry) {
          final k = raw.apiKey.trim();
          if (k.isEmpty) continue;
          entry = GeminiApiKeyEntry(
            id: raw.id.trim().isNotEmpty
                ? raw.id.trim()
                : 'key-${normalized.length + 1}',
            label: raw.label.trim(),
            apiKey: k,
            tpmLimit: raw.tpmLimit > 0
                ? raw.tpmLimit
                : AppConstants.defaultGeminiLiveTpmLimit,
          );
        } else if (raw is String) {
          final k = raw.trim();
          if (k.isEmpty) continue;
          entry = GeminiApiKeyEntry(
            id: 'key-${normalized.length + 1}',
            apiKey: k,
          );
        } else if (raw is Map) {
          final mapped = Map<String, dynamic>.from(raw);
          final parsed = GeminiApiKeyEntry.fromMap(
            mapped,
            index: normalized.length,
          );
          if (parsed.apiKey.isEmpty) continue;
          entry = parsed;
        }
        if (entry == null || !seen.add(entry.apiKey)) continue;
        normalized.add(entry);
      }
    }

    final fallback = fallbackApiKey.trim();
    if (normalized.isEmpty && fallback.isNotEmpty) {
      normalized.add(
        GeminiApiKeyEntry(
          id: 'default',
          label: '',
          apiKey: fallback,
          tpmLimit: AppConstants.defaultGeminiLiveTpmLimit,
        ),
      );
    }

    return List<GeminiApiKeyEntry>.unmodifiable(normalized);
  }

  static bool listEquals(List<GeminiApiKeyEntry> a, List<GeminiApiKeyEntry> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
