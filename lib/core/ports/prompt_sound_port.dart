/// 提示音与声效服务端口 (Prompt Sound Port)
///
/// 定义唤醒/确认提示音与相机快门音的播放契约。
abstract interface class PromptSoundPort {
  Future<void> playAcknowledgeBeep();
  Future<void> playShutterSound();
  void dispose();
}
