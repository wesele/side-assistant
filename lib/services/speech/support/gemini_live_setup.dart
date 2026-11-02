import '../../../core/constants/app_constants.dart';
import '../../../core/models/app_settings.dart';

/// Gemini Live 会话的静态配置：API Key、模型名、VAD 尾静音、setup 消息与热词表。
///
/// 全部是无状态的纯函数（只读 [AppSettings]），便于直接单测协议字段。
class GeminiLiveSetup {
  const GeminiLiveSetup._();

  static String apiKey(AppSettings settings) => settings.geminiApiKey.trim();

  static String model(AppSettings settings) {
    final raw = settings.geminiAsrModel.trim();
    final name = raw.isEmpty ? AppConstants.defaultGeminiAsrModel : raw;
    return name.startsWith('models/') ? name : 'models/$name';
  }

  /// Gemini 的云端实时 VAD 比本地 Silero 更“贪心”，但本地仍用 Silero 切段。
  /// 用户保持默认 0.50s 时，给云端识别降到 0.40s，减少说完“回答”后的固定等待；
  /// 用户手工改过尾静音则完全尊重用户值。
  static double adjustVadMinSilence(double requested) {
    const tolerance = 0.001;
    if ((requested - AppConstants.defaultVadMinSilenceSeconds).abs() <
        tolerance) {
      return AppConstants.geminiVadMinSilenceSeconds;
    }
    return requested;
  }

  /// 组装 Live 会话的 setup 消息。
  ///
  /// - 语言提示必须放在 `inputAudioTranscription.languageCodes`（BCP-47）里；
  ///   放到 setup 顶层或 `generationConfig.speechConfig` 都会被静默忽略。
  /// - 热词偏置放在 `inputAudioTranscription.customVocabulary` 里，把唤醒词、
  ///   结束词、重置词与领域词传给服务端解码器，提升触发词识别率且零时延损耗。
  static Map<String, dynamic> buildMessage({
    required String model,
    String? languageCode,
    List<String>? customVocabulary,
  }) {
    final code = (languageCode ?? AppConstants.geminiAsrLanguageCode).trim();
    final vocab = <String>[
      if (customVocabulary != null)
        for (final word in customVocabulary)
          if (word.trim().isNotEmpty) word.trim(),
    ];
    return {
      'setup': {
        'model': model,
        'generationConfig': {
          'responseModalities': ['TEXT'],
        },
        'inputAudioTranscription': <String, dynamic>{
          if (code.isNotEmpty) 'languageCodes': <String>[code],
          if (vocab.isNotEmpty) 'customVocabulary': vocab,
        },
      },
    };
  }

  /// 从当前设置提取热词表（去重、去空），供 `customVocabulary` 偏置使用。
  static List<String> customVocabulary(AppSettings settings) {
    final words = <String>{
      ...settings.startWords,
      '晓漫',
      '小曼',
      ...settings.endWords,
      ...settings.resetWords,
      ...settings.exitContinuousWords,
      '侧边助手',
    };
    words.removeWhere((w) => w.trim().isEmpty);
    return words.toList(growable: false);
  }
}
