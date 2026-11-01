/// 音频采集流与声学缓冲区控制契约端口 (Audio Stream Control Port)
///
/// 遵循接口隔离原则 (ISP)，将声学采集状态监听、环形缓冲区清空、
/// 唤醒流复位及后台卫生清理职责从具体语音管线中抽象为轻量级契约。
/// 对话决策编排层及状态机组件仅依赖此契约，无需耦合具体语音管线实现。
/// 纯 Dart 契约，零 `dart:ui` 或 `package:flutter` 依赖。
abstract interface class AudioStreamControlPort {
  /// 麦克风当前是否处于持续监听中
  bool get isMicListening;

  /// 语音识别引擎是否处于流式识别模式（本地 sherpa 在线流式或云端流式 ASR）
  ///
  /// 消解原先直接穿透访问 `asrService.isStreaming || asrService.isCloudStreaming` 的
  /// 迪米特法则违规。
  bool get isAsrStreaming;

  /// 待机状态下的例行音频资源清理与内存卫生检查
  void performIdleHygiene();

  /// 重置声学采集流状态（唤醒词命中或会话重置后清空旧上下文）
  void resetStream();

  /// 清空麦克风音频采集环形缓冲区，并设定抑制声学回声的静音冷却窗口
  ///
  /// [cooldownMs] 静音冷却时长（毫秒），默认 600ms，用于彻底吸收播报后回声与杂音。
  void flushBuffers({int cooldownMs = 600});
}
