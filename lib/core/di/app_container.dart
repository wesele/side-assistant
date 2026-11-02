import 'dart:async';

import '../engine/assistant_engine.dart';
import '../models/app_settings.dart';
import '../../services/llm/llm_service.dart';
import '../../services/nlp/trigger_matcher.dart';
import '../../services/speech/prompt_sound_service.dart';
import '../../services/speech/speaker_verification_service.dart';
import '../../services/speech/target_speaker_extraction_service.dart';
import '../../services/speech/tts_service.dart';
import '../../services/storage/chat_history_service.dart';
import '../../services/storage/session_manager.dart';
import '../../services/vision/camera_service.dart';
import '../../services/service_registrations.dart';

/// 注册条目类型枚举
enum _RegistrationType { singleton, lazySingleton, factory }

/// 内部服务注册条目
class _ServiceEntry<T> {
  final _RegistrationType type;
  T? instance;
  T Function()? factory;
  final void Function(T instance)? onDispose;

  _ServiceEntry.singleton(this.instance, {this.onDispose})
      : type = _RegistrationType.singleton;

  _ServiceEntry.lazySingleton(this.factory, {this.onDispose})
      : type = _RegistrationType.lazySingleton;

  _ServiceEntry.factory(this.factory)
      : type = _RegistrationType.factory,
        onDispose = null;

  T resolve() {
    switch (type) {
      case _RegistrationType.singleton:
        return instance!;
      case _RegistrationType.lazySingleton:
        instance ??= factory!();
        return instance!;
      case _RegistrationType.factory:
        return factory!();
    }
  }

  void dispose() {
    if (instance != null && onDispose != null) {
      try {
        onDispose!(instance as T);
      } catch (_) {}
    }
    instance = null;
  }
}

/// 服务未注册异常
class ServiceNotFoundException implements Exception {
  final Type serviceType;
  final String? name;
  final String message;

  ServiceNotFoundException(this.serviceType, [this.name])
      : message =
            'AppContainer: 服务未注册 [${serviceType.toString()}${name != null ? " ($name)" : ""}]';

  @override
  String toString() => message;
}

/// 纯 Dart 轻量级依赖注入与服务装配容器 (Pure-Dart Dependency Container)
///
/// 遵循六边形架构与依赖倒置原则，负责全系统组件的依赖解析与单例生命周期托管。
/// 零 Flutter UI / `dart:ui` 依赖，可在移动端、桌面端与 Linux 无头服务器通用。
class AppContainer {
  static AppContainer? _instance;
  static AppContainer get instance => _instance ??= AppContainer._();

  final Map<String, _ServiceEntry<dynamic>> _registrations = {};

  AppContainer._();

  static String _buildKey<T>([String? name]) =>
      '${T.toString()}${name != null ? ":$name" : ""}';

  /// 注册现有单例对象
  void registerSingleton<T>(
    T instance, {
    String? name,
    void Function(T instance)? onDispose,
    bool allowOverride = false,
  }) {
    final key = _buildKey<T>(name);
    if (_registrations.containsKey(key) && !allowOverride) {
      throw StateError('服务 $key 已注册。如需覆盖请设置 allowOverride: true');
    }
    _registrations[key] = _ServiceEntry<T>.singleton(
      instance,
      onDispose: onDispose,
    );
  }

  /// 注册延迟初始化的单例（首次 get 时触发 factory 构建，后续全局缓存复用）
  void registerLazySingleton<T>(
    T Function() factory, {
    String? name,
    void Function(T instance)? onDispose,
    bool allowOverride = false,
  }) {
    final key = _buildKey<T>(name);
    if (_registrations.containsKey(key) && !allowOverride) {
      throw StateError('服务 $key 已注册。如需覆盖请设置 allowOverride: true');
    }
    _registrations[key] = _ServiceEntry<T>.lazySingleton(
      factory,
      onDispose: onDispose,
    );
  }

  /// 注册瞬态工厂（每次 get 均产生新实例）
  void registerFactory<T>(
    T Function() factory, {
    String? name,
    bool allowOverride = false,
  }) {
    final key = _buildKey<T>(name);
    if (_registrations.containsKey(key) && !allowOverride) {
      throw StateError('服务 $key 已注册。如需覆盖请设置 allowOverride: true');
    }
    _registrations[key] = _ServiceEntry<T>.factory(factory);
  }

  /// 解析并获取服务实例；若未注册则抛出 [ServiceNotFoundException]
  T get<T>([String? name]) {
    final key = _buildKey<T>(name);
    final entry = _registrations[key];
    if (entry == null) {
      throw ServiceNotFoundException(T, name);
    }
    return entry.resolve() as T;
  }

  /// 尝试获取服务实例；若未注册则返回 null
  T? tryGet<T>([String? name]) {
    final key = _buildKey<T>(name);
    final entry = _registrations[key];
    if (entry == null) return null;
    return entry.resolve() as T;
  }

  /// 检查某服务是否已注册
  bool has<T>([String? name]) =>
      _registrations.containsKey(_buildKey<T>(name));

  /// 兼容检查某服务是否已注册
  bool isRegistered<T>([String? name]) => has<T>(name);

  /// 注销指定服务
  void unregister<T>([String? name]) {
    final key = _buildKey<T>(name);
    final entry = _registrations.remove(key);
    entry?.dispose();
  }

  /// 单元测试专用：强制覆盖某服务的实现（自动替换已有实例）
  void registerOverride<T>(T instance, [String? name]) {
    registerSingleton<T>(instance, name: name, allowOverride: true);
  }

  /// 清空并销毁容器中所有已注册的服务
  Future<void> reset({bool dispose = true}) async {
    if (dispose) {
      for (final entry in _registrations.values) {
        entry.dispose();
      }
    }
    _registrations.clear();
  }

  /// 单元测试专用快速重置与状态复位
  static void resetForTest() {
    if (_instance != null) {
      for (final entry in _instance!._registrations.values) {
        entry.dispose();
      }
      _instance!._registrations.clear();
      _instance = null;
    }
  }

  // ==============================================================
  // 生产与运行环境装配助手 (Assembly Setup Helpers)
  // ==============================================================

  /// 装配生产环境 Flutter GUI 客户端所用的全套领域服务
  static Future<AppContainer> initializeProductionClient([
    AppSettings? settings,
  ]) async {
    ServiceRegistrations.ensureInitialized();
    final container = AppContainer.instance;
    await container.reset();

    final actualSettings = settings ?? await AppSettings.load();
    container.registerSingleton<AppSettings>(actualSettings);

    // 存储与会话
    container.registerLazySingleton<ChatHistoryService>(
      () => ChatHistoryService(),
    );
    container.registerLazySingleton<SessionManager>(
      () => SessionManager(
        chatHistoryService: container.get<ChatHistoryService>(),
      ),
    );

    // 语音辅助与声纹
    container.registerLazySingleton<TriggerMatcher>(
      () => TriggerMatcher(settings: container.get<AppSettings>())..warmUp(),
    );
    container.registerLazySingleton<SpeakerVerificationService>(
      () => SpeakerVerificationService(settings: container.get<AppSettings>()),
      onDispose: (s) => s.dispose(),
    );
    container.registerLazySingleton<TargetSpeakerExtractionService>(
      () => TargetSpeakerExtractionService(
        settings: container.get<AppSettings>(),
        speakerVerificationService: container.get<SpeakerVerificationService>(),
      ),
    );
    container.registerLazySingleton<PromptSoundService>(
      () => PromptSoundService(
        outputDeviceId: container.get<AppSettings>().audioOutputDeviceId,
      ),
    );

    // AI 模型与多模态
    container.registerLazySingleton<LlmService>(
      () => LlmService(settings: container.get<AppSettings>()),
    );
    container.registerLazySingleton<TtsService>(
      () => TtsService(settings: container.get<AppSettings>()),
      onDispose: (s) => s.dispose(),
    );
    container.registerLazySingleton<CameraService>(
      () => CameraService(settings: container.get<AppSettings>()),
      onDispose: (s) => s.dispose(),
    );

    // 领域核心引擎
    container.registerLazySingleton<AssistantEngine>(
      () => AssistantEngine(
        settings: container.get<AppSettings>(),
        chatHistoryService: container.get<ChatHistoryService>(),
        injectedLlmService: container.get<LlmService>(),
        cameraService: container.get<CameraService>(),
      ),
      onDispose: (e) => e.dispose(),
    );

    return container;
  }

  /// 装配 Linux Headless 无头服务端常驻进程所需服务
  static Future<AppContainer> initializeHeadlessServer([
    AppSettings? settings,
  ]) async {
    ServiceRegistrations.ensureInitialized();
    final container = AppContainer.instance;
    await container.reset();

    final actualSettings = settings ?? await AppSettings.load();
    container.registerSingleton<AppSettings>(actualSettings);

    // 基础存储与会话
    container.registerLazySingleton<ChatHistoryService>(
      () => ChatHistoryService(),
    );
    container.registerLazySingleton<SessionManager>(
      () => SessionManager(
        chatHistoryService: container.get<ChatHistoryService>(),
      ),
    );

    // 领域模型
    container.registerLazySingleton<TriggerMatcher>(
      () => TriggerMatcher(settings: container.get<AppSettings>())..warmUp(),
    );
    container.registerLazySingleton<SpeakerVerificationService>(
      () => SpeakerVerificationService(settings: container.get<AppSettings>()),
      onDispose: (s) => s.dispose(),
    );
    container.registerLazySingleton<TargetSpeakerExtractionService>(
      () => TargetSpeakerExtractionService(
        settings: container.get<AppSettings>(),
        speakerVerificationService: container.get<SpeakerVerificationService>(),
      ),
    );
    container.registerLazySingleton<PromptSoundService>(
      () => PromptSoundService(
        outputDeviceId: container.get<AppSettings>().audioOutputDeviceId,
      ),
    );
    container.registerLazySingleton<LlmService>(
      () => LlmService(settings: container.get<AppSettings>()),
    );
    container.registerLazySingleton<TtsService>(
      () => TtsService(settings: container.get<AppSettings>()),
      onDispose: (s) => s.dispose(),
    );
    container.registerLazySingleton<CameraService>(
      () => CameraService(settings: container.get<AppSettings>()),
      onDispose: (s) => s.dispose(),
    );

    // 核心引擎（服务端不需要默认拉起内部 DriverServer，由外层托管生命周期）
    container.registerLazySingleton<AssistantEngine>(
      () => AssistantEngine(
        settings: container.get<AppSettings>(),
        chatHistoryService: container.get<ChatHistoryService>(),
        injectedLlmService: container.get<LlmService>(),
        cameraService: container.get<CameraService>(),
        enableDriverServer: false,
      ),
      onDispose: (e) => e.dispose(),
    );

    return container;
  }
}
