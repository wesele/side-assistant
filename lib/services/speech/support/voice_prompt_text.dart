import '../../../core/constants/app_constants.dart';
import '../../../core/models/app_settings.dart';

/// 语音交互文案与热词表生成（纯函数，无副作用、无 IO）。
///
/// 职责边界：
/// - 把 [AppSettings] 里的唤醒模式/唤醒词翻译成待机提示文案；
/// - 把唤醒词、结束词、退出词、复位词等配置拼成送 ASR 的热词表字符串。
///
/// 不涉及采集、VAD、识别时序，也不持有任何状态。
class VoicePromptText {
  const VoicePromptText._();

  /// 待机状态提示文案。
  static String standbyHint(AppSettings settings) {
    switch (settings.startWordMode) {
      case AppConstants.startWordModeDisabled:
        return '话筒监听中（随时直接说话即可）';
      case AppConstants.startWordModeAuto:
        return '话筒监听中（说“${settings.startWord}”唤醒后连续对话）';
      case AppConstants.startWordModeEnabled:
      default:
        return '话筒监听中（可随时说“${settings.startWord}”唤醒）';
    }
  }

  /// 前台常驻通知的正文（后台运行/低功耗待机时的说明）。
  static String foregroundContent(AppSettings settings) {
    switch (settings.startWordMode) {
      case AppConstants.startWordModeDisabled:
        return '低功耗待机中，可随时直接说话交互';
      case AppConstants.startWordModeAuto:
        return '待机中，说“${settings.startWord}”唤醒后连续对话';
      case AppConstants.startWordModeEnabled:
      default:
        return '低功耗待机中，可随时说“${settings.startWord}”唤醒';
    }
  }

  /// 送 ASR 的热词表（空格分隔，已去重）。
  static String hotwords(AppSettings settings) {
    final parts = <String>{};
    // 多词配置：每个词都进热词表，提升这些词的识别率。
    for (final word in settings.startWords) {
      final w = word.trim();
      if (w.isNotEmpty) parts.add(w);
    }
    parts.add('小曼');
    parts.add('晓漫');
    parts.add('停止');
    parts.add('暂停');
    for (final word in settings.exitContinuousWords) {
      final w = word.trim();
      if (w.isNotEmpty) parts.add(w);
    }
    for (final word in settings.endWords) {
      final w = word.trim();
      if (w.isNotEmpty) parts.add(w);
    }
    for (final word in settings.resetWords) {
      final w = word.trim();
      if (w.isNotEmpty) parts.add(w);
    }
    parts.add('侧边助手');
    return parts.join(' ');
  }
}
