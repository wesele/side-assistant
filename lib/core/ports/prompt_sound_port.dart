/// 提示音与声效服务端口 (Prompt Sound Port)
///
/// 定义唤醒/确认提示音与相机快门音的播放契约。
abstract interface class PromptSoundPort {
  Future<void> playAcknowledgeBeep();
  Future<void> playShutterSound();
  void dispose();
}

/// 提示音工厂注册表 (Composition Root SPI 扩展点)
class PromptSoundFactoryRegistry {
  static PromptSoundPort Function({String? outputDeviceId})? defaultFactory;
}

/// 空操作提示音兜底实现
class NoopPromptSoundPort implements PromptSoundPort {
  const NoopPromptSoundPort();

  @override
  Future<void> playAcknowledgeBeep() async {}

  @override
  Future<void> playShutterSound() async {}

  @override
  void dispose() {}
}
