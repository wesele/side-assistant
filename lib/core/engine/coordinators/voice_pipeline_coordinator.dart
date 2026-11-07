import 'dart:async';

import '../engine_events.dart';
import '../../models/app_settings.dart';
import '../../models/device_options.dart';
import '../../platform/foundation_bridge.dart';
import '../../platform/linux/linux_hardware_adapter.dart';
import '../../ports/asr_port.dart';
import '../../ports/audio_hardware_port.dart';
import '../../ports/audio_stream_control_port.dart';
import '../../ports/speaker_verification_port.dart';
import '../../ports/target_speaker_extraction_port.dart';
import '../../ports/voice_listening_port.dart';
import '../support/null_ports.dart';
import '../support/speaker_pipeline.dart';

export '../../ports/audio_stream_control_port.dart';
export '../../ports/speaker_verification_port.dart';
export '../../ports/target_speaker_extraction_port.dart';
export '../../ports/voice_listening_port.dart';

/// 语音管线协调器 (VoicePipelineCoordinator)
///
/// 垂直闭环声学输入、VAD指标监测、两阶段 ASR 仲裁、TSE 说话人抽取、声纹识别与麦克风诊断。
/// 纯 Dart 实现，无 Flutter UI 或 `dart:ui` 依赖。
class VoicePipelineCoordinator
    implements AudioStreamControlPort, SpeakerVerificationPort {
  AppSettings settings;
  final void Function(AssistantEngineEvent event) emit;
  final void Function() onNotify;

  // 上层业务回调
  void Function(String text)? onRecognizedText;
  void Function(String text)? onPartialTranscript;
  void Function(String text)? onFinalTranscript;
  void Function(String text)? onManualRecordingRecognized;
  void Function(Float32List samples)? onRawAudioSamples;
  void Function(bool active, String hint)? onStateChanged;
  bool Function()? isStandbyMode;
  bool Function()? isPlayingMode;

  // 内部子服务
  late AsrPort asrService;
  AsrPort? finalAsrService;
  late VoiceListeningPort voiceListeningService;
  late SpeakerVerifierPort speakerVerificationService;
  late TargetSpeakerExtractionPort targetSpeakerExtractionService;

  // 状态变量
  bool isMicTesting = false;
  String micTestText = '';
  final List<Map<String, dynamic>> micTestHistory = [];
  int servicesGeneration = 0;
  bool _disposed = false;
  bool _servicesInitialized = false;

  // 主人声纹子管线（声纹校验 / 录入 / 相似度诊断）
  late final SpeakerPipeline _speakerPipeline;

  /// 是否正在录制声纹样本（状态由子管线持有）
  bool get isEnrollingSpeaker => _speakerPipeline.isEnrolling;
  set isEnrollingSpeaker(bool value) => _speakerPipeline.isEnrolling = value;

  // ASR 引擎装配函数（可选外部注入，默认由 AsrFactoryRegistry 装配）
  final AsrEngineBundle Function(AppSettings settings)? asrEngineBuilder;
  final Future<String> Function(AppSettings settings,
      {String? apiKey, String? model})? geminiTester;

  VoicePipelineCoordinator({
    required this.settings,
    required this.emit,
    required this.onNotify,
    this.onRecognizedText,
    this.onPartialTranscript,
    this.onFinalTranscript,
    this.onManualRecordingRecognized,
    this.onRawAudioSamples,
    this.onStateChanged,
    this.isStandbyMode,
    this.isPlayingMode,
    this.asrEngineBuilder,
    this.geminiTester,
    AsrPort? asrService,
    AsrPort? finalAsrService,
    VoiceListeningPort? voiceListeningService,
    SpeakerVerifierPort? speakerVerificationService,
    TargetSpeakerExtractionPort? targetSpeakerExtractionService,
  }) {
    _speakerPipeline = SpeakerPipeline(
      settingsOf: _currentSettings,
      verifierOf: _currentSpeakerVerifier,
      listeningOf: _currentVoiceListening,
      onNotify: onNotify,
    );
    if (asrService != null &&
        voiceListeningService != null &&
        speakerVerificationService != null &&
        targetSpeakerExtractionService != null) {
      this.asrService = asrService;
      this.finalAsrService = finalAsrService;
      this.voiceListeningService = voiceListeningService;
      this.speakerVerificationService = speakerVerificationService;
      this.targetSpeakerExtractionService = targetSpeakerExtractionService;
      _servicesInitialized = true;
    } else {
      initServices();
    }
  }

  // 子管线协作者访问器：服务实例会被 initServices/applyAudioConfig 热替换，
  // 因此以访问器形式注入，保证子管线始终读取最新实例。
  AppSettings _currentSettings() => settings;
  SpeakerVerifierPort _currentSpeakerVerifier() => speakerVerificationService;
  VoiceListeningPort _currentVoiceListening() => voiceListeningService;

  bool get isDisposed => _disposed;

  @override
  bool get isMicListening => voiceListeningService.isListening;

  @override
  bool get isAsrStreaming =>
      asrService.isStreaming || asrService.isCloudStreaming;

  bool get isManualRecording => voiceListeningService.isManualRecording;
  double get micLevel => voiceListeningService.micLevel;
  double get micDbfs => voiceListeningService.micDbfs;
  bool get vadDetected => voiceListeningService.vadDetected;
  int get enrolledSpeakerCount =>
      speakerVerificationService.enrolledSampleCount;
  bool get hasEnrolledOwner => speakerVerificationService.hasEnrolledOwner;
  String get speakerModelLabel => speakerVerificationService.modelLabel;
  String? get lastEnrollError => speakerVerificationService.lastEnrollError;
  String get activeAudioInputDeviceLabel =>
      voiceListeningService.activeInputDeviceLabel;

  @override
  bool get isEnrolling =>
      isEnrollingSpeaker ||
      (_servicesInitialized && voiceListeningService.isEnrollingSpeaker);

  void _disposeAsrInstances() {
    final oldAsr = asrService;
    final oldFinalAsr = finalAsrService;
    oldAsr.dispose();
    if (oldFinalAsr != null && !identical(oldFinalAsr, oldAsr)) {
      oldFinalAsr.dispose();
    }
    finalAsrService = null;
  }

  /// 初始化与重建声学子服务
  void initServices() {
    final generation = ++servicesGeneration;
    bool restoreListening = false;
    if (_servicesInitialized) {
      restoreListening = voiceListeningService.isListening;
      voiceListeningService.dispose();
      _disposeAsrInstances();
      speakerVerificationService.dispose();
    }
    _servicesInitialized = true;

    speakerVerificationService =
        SpeakerVerifierFactoryRegistry.defaultFactory?.call(settings) ??
            const NullSpeakerVerifier();
    targetSpeakerExtractionService =
        TargetSpeakerExtractionFactoryRegistry.defaultFactory?.call(
              settings,
              speakerVerificationService,
            ) ??
            const NullTargetSpeakerExtraction();
    if (settings.enableSpeakerVerification ||
        settings.enableTargetSpeakerExtraction) {
      unawaited(speakerVerificationService.initialize());
    }

    final AsrEngineBundle bundle;
    final builder = asrEngineBuilder ?? AsrFactoryRegistry.defaultFactory;
    if (builder != null) {
      bundle = builder(settings);
    } else {
      const dummyAsr = NullAsrPort();
      bundle = const AsrEngineBundle<AsrPort>(
        primaryAsr: dummyAsr,
        fallbackAsr: dummyAsr,
        primaryName: 'dummy',
        fallbackName: 'dummy',
      );
    }
    final primaryAsr = bundle.primaryAsr;
    final fallbackAsr = bundle.fallbackAsr;
    final primaryName = bundle.primaryName;
    final fallbackName = bundle.fallbackName;
    finalAsrService = bundle.finalAsr;
    asrService = primaryAsr;

    final voiceListeningFactory = VoiceListeningFactoryRegistry.defaultFactory;
    if (voiceListeningFactory != null) {
      voiceListeningService = voiceListeningFactory(
        asrService: primaryAsr,
        settings: settings,
        finalAsrService: finalAsrService,
        speakerVerificationService: speakerVerificationService,
        onFinalTranscript: (text) => onFinalTranscript?.call(text),
        onTextRecognized: (text) => onRecognizedText?.call(text),
        onManualRecordingRecognized: (text) =>
            onManualRecordingRecognized?.call(text),
        onRawAudioSamples: (samples) => onRawAudioSamples?.call(samples),
        onAudioLevelChanged: (level, dbfs, vadNow) {
          emit(MetricsUpdatedEvent.fromValues(
            level: level,
            dbfs: dbfs,
            vadDetected: vadNow,
          ));
        },
        onMicTestRecognized: (text, durationMs) {
          micTestText = text;
          final now = DateTime.now();
          final timeStr =
              '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

          final audio = voiceListeningService.lastRecognizedAudio ??
              voiceListeningService.getRecentAudio(seconds: 2.5);

          double? similarity;
          double? similarityPercent;
          bool? speakerMatched;
          String? speakerStatus;

          if (audio.isNotEmpty &&
              speakerVerificationService.hasEnrolledOwner &&
              speakerVerificationService.isReady) {
            try {
              final analysis = speakerVerificationService.analyzeOwner(audio);
              if (!analysis.hasError) {
                similarity = analysis.similarity;
                similarityPercent = double.parse(
                    (analysis.similarity * 100).toStringAsFixed(1));
                final threshold = settings.speakerSimilarityThreshold;
                speakerMatched = analysis.similarity >= threshold;
                speakerStatus = speakerMatched ? '声纹匹配' : '未达阈值';
              } else {
                if (analysis.similarity > 0) {
                  similarity = analysis.similarity;
                  similarityPercent = double.parse(
                      (analysis.similarity * 100).toStringAsFixed(1));
                }
                speakerMatched = false;
                speakerStatus = analysis.error ?? '比对失败';
              }
            } catch (_) {
              speakerStatus = '声纹分析异常';
            }
          } else if (!speakerVerificationService.hasEnrolledOwner) {
            speakerStatus = '未录入声纹';
          } else if (!speakerVerificationService.isReady) {
            speakerStatus = '模型未就绪';
          }

          micTestHistory.insert(0, {
            'time': timeStr,
            'text': text,
            'durationMs': durationMs,
            'engine': asrService.engineName,
            'similarity': similarity,
            'similarityPercent': similarityPercent,
            'speakerMatched': speakerMatched,
            'speakerStatus': speakerStatus,
            'llmDecision': isMicTesting ? '测试模式' : '识别完成',
            'shouldReply': isMicTesting ? false : null,
            'detail': isMicTesting ? '麦克风测试未触发大模型' : null,
          });
          if (micTestHistory.length > 20) {
            micTestHistory.removeRange(20, micTestHistory.length);
          }
          emit(MicTestUpdatedEvent(
            text,
            micTestHistory,
            durationMs: durationMs,
            engine: asrService.engineName,
          ));
          onNotify();
        },
        onStateChanged: (active, hint) {
          onStateChanged?.call(active, hint);
          emit(MicListeningChangedEvent(
            voiceListeningService.isListening,
            isManualRecording: voiceListeningService.isManualRecording,
            activeDeviceLabel: activeAudioInputDeviceLabel,
          ));
          onNotify();
        },
        isStandbyMode: () => isStandbyMode?.call() ?? true,
        isPlayingMode: () => isPlayingMode?.call() ?? false,
      )
        ..isMicTesting = isMicTesting
        ..isEnrollingSpeaker = isEnrollingSpeaker;
    } else {
      voiceListeningService = NullVoiceListening()
        ..isMicTesting = isMicTesting
        ..isEnrollingSpeaker = isEnrollingSpeaker;
    }

    if (primaryAsr.isCloudStreaming) {
      primaryAsr.onPartialText = (text) {
        onPartialTranscript?.call(text);
      };
    }

    if (!settings.isGeminiLiveMode) {
      unawaited(() async {
        await primaryAsr.initialize();
        if (_disposed || generation != servicesGeneration) return;
        if (primaryAsr.isReady) {
          debugPrint('[VoicePipelineCoordinator] $primaryName 识别引擎就绪');
          return;
        }
        debugPrint(
          '[VoicePipelineCoordinator] $primaryName 识别引擎未就绪，回退 $fallbackName',
        );
        await fallbackAsr.initialize();
        if (_disposed || generation != servicesGeneration) return;
        await _swapAsrIfCurrent(primaryAsr, fallbackAsr, fallbackName);
      }());
    }

    if (restoreListening) {
      unawaited(voiceListeningService.startContinuousListening());
    }
  }

  Future<void> _swapAsrIfCurrent(
    AsrPort current,
    AsrPort next,
    String nextName,
  ) async {
    if (_disposed) {
      next.dispose();
      return;
    }
    if (identical(asrService, current) && next.isReady) {
      asrService = next;
      await voiceListeningService.setAsrService(next);
      if (!identical(current, next)) {
        current.dispose();
      }
      debugPrint('[VoicePipelineCoordinator] 已切换识别引擎到 $nextName');
    } else if (!identical(next, finalAsrService)) {
      next.dispose();
    }
  }

  /// 开启麦克风常驻监听
  Future<bool> startContinuousListening() async {
    final ok = await voiceListeningService.startContinuousListening();
    emit(MicListeningChangedEvent(
      voiceListeningService.isListening,
      isManualRecording: voiceListeningService.isManualRecording,
      activeDeviceLabel: activeAudioInputDeviceLabel,
    ));
    onNotify();
    return ok;
  }

  /// 停止麦克风常驻监听
  Future<void> stopContinuousListening() async {
    await voiceListeningService.stopContinuousListening();
    emit(MicListeningChangedEvent(
      voiceListeningService.isListening,
      isManualRecording: voiceListeningService.isManualRecording,
      activeDeviceLabel: activeAudioInputDeviceLabel,
    ));
    onNotify();
  }

  /// 切换麦克风监听状态
  Future<void> toggleContinuousListening() async {
    await voiceListeningService.toggleContinuousListening();
    emit(MicListeningChangedEvent(
      voiceListeningService.isListening,
      isManualRecording: voiceListeningService.isManualRecording,
      activeDeviceLabel: activeAudioInputDeviceLabel,
    ));
    onNotify();
  }

  /// 启动手动按住录音
  Future<void> startManualRecording() async {
    await voiceListeningService.startManualRecording();
    emit(MicListeningChangedEvent(
      voiceListeningService.isListening,
      isManualRecording: true,
      activeDeviceLabel: activeAudioInputDeviceLabel,
    ));
    onNotify();
  }

  /// 停止手动按住录音并触发转写
  Future<void> stopManualRecording() async {
    await voiceListeningService.stopManualRecording();
    emit(MicListeningChangedEvent(
      voiceListeningService.isListening,
      isManualRecording: false,
      activeDeviceLabel: activeAudioInputDeviceLabel,
    ));
    onNotify();
  }

  /// 列出可用音频输入设备
  Future<List<AudioInputDeviceOption>> listInputDevices() {
    final lister = AudioHardwareRegistry.defaultInputDeviceLister;
    if (lister != null) {
      return lister();
    }
    return LinuxHardwareAdapter.listInputDevices();
  }

  /// 切换音频输入设备
  Future<void> setAudioInputDevice(String id, String label) async {
    settings.audioInputDeviceId = id;
    settings.audioInputDeviceLabel = label;
    await settings.save();
    await voiceListeningService.applyInputDeviceChange();
    emit(MicListeningChangedEvent(
      voiceListeningService.isListening,
      isManualRecording: voiceListeningService.isManualRecording,
      activeDeviceLabel: label,
    ));
    onNotify();
  }

  /// 清空音频流与 VAD 缓冲区
  @override
  void flushBuffers({int cooldownMs = 600}) {
    voiceListeningService.flushBuffers(cooldownMs: cooldownMs);
  }

  /// 重置流式 ASR 解码流
  @override
  void resetStream() {
    voiceListeningService.resetStream();
  }

  /// 执行静默期声学缓冲垃圾回收
  @override
  void performIdleHygiene() {
    voiceListeningService.performIdleHygiene();
  }

  /// 动态切换 ASR 引擎
  Future<void> switchAsrEngine(String engine) async {
    settings.asrEngine = engine;
    await settings.save();
    initServices();
    onNotify();
  }

  /// 转写音频文件
  Future<String?> transcribeAudioFile(
    String path, {
    bool isStandbyWakeCheck = false,
  }) async {
    return await asrService.transcribeAudioFile(
      path,
      isStandbyWakeCheck: isStandbyWakeCheck,
    );
  }

  /// 测试 Gemini Transcribe Live 连接性
  Future<String> testGeminiAsrConnection({
    String? apiKey,
    String? model,
  }) {
    final tester = geminiTester ?? AsrFactoryRegistry.defaultGeminiTester;
    if (tester != null) {
      return tester(
        settings,
        apiKey: apiKey,
        model: model,
      );
    }
    return Future.value('未配置 Gemini 连通性测试服务');
  }

  /// 校验当前输入音频是否来自注册的主人声纹
  @override
  bool verifyOwnerSpeaker({
    String contextHint = '唤醒',
    void Function(String reason)? onRejected,
  }) =>
      _speakerPipeline.verifyOwnerSpeaker(
        contextHint: contextHint,
        onRejected: onRejected,
      );

  /// 校验指定原始 PCM 字节数据是否匹配主人声纹
  @override
  Future<SpeakerVerificationResult> verifyOwnerSpeakerData(
    List<int> pcmData, {
    required int sampleRate,
  }) =>
      _speakerPipeline.verifyOwnerSpeakerData(
        pcmData,
        sampleRate: sampleRate,
      );

  /// 获取最近音频切片 (Float32List)
  Float32List? getRecentAudioSnippet({double seconds = 3.0}) =>
      _speakerPipeline.getRecentAudioSnippet(seconds: seconds);

  /// 使用提供的样本录入主人声纹
  Future<bool> enrollOwnerSpeaker({Float32List? samples}) =>
      _speakerPipeline.enrollOwnerSpeaker(samples: samples);

  /// 录制并录入主人声纹
  Future<bool> recordAndEnrollOwnerSpeaker({double seconds = 3.5}) =>
      _speakerPipeline.recordAndEnrollOwnerSpeaker(seconds: seconds);

  /// 清空已录入的主人声纹
  Future<void> clearOwnerSpeaker() => _speakerPipeline.clearOwnerSpeaker();

  /// 录制并测试与主人声纹的相似度
  Future<Map<String, dynamic>> recordAndTestOwnerSpeakerSimilarity({
    double seconds = 3.0,
  }) =>
      _speakerPipeline.recordAndTestOwnerSpeakerSimilarity(seconds: seconds);

  /// 测试样本与主人声纹的余弦相似度
  Future<Map<String, dynamic>> testOwnerSpeakerSimilarity({
    Float32List? samples,
  }) =>
      _speakerPipeline.testOwnerSpeakerSimilarity(samples: samples);

  /// 设置麦克风诊断测试模式
  Future<void> setMicTestMode(bool enabled, {bool clear = false}) async {
    if (clear) {
      micTestText = '';
      micTestHistory.clear();
    }
    isMicTesting = enabled;
    voiceListeningService.isMicTesting = enabled;
    if (enabled && !voiceListeningService.isListening) {
      await voiceListeningService.startContinuousListening();
    }
    emit(MicTestUpdatedEvent(
      micTestText,
      micTestHistory,
      engine: asrService.engineName,
    ));
    onNotify();
  }

  /// 实时更新最近一条识别记录的大模型决策与意图状态
  void updateLatestMicTestHistory({
    String? forText,
    required String llmDecision,
    bool? shouldReply,
    String? intent,
    String? detail,
    double? similarity,
    double? similarityPercent,
    bool? speakerMatched,
    String? speakerStatus,
  }) {
    if (micTestHistory.isEmpty) return;
    Map<String, dynamic>? target;
    if (forText != null && forText.trim().isNotEmpty) {
      final clean = forText.trim().replaceAll(RegExp(r'[，。？！、\s]'), '');
      for (final item in micTestHistory) {
        final t = ((item['text'] as String?) ?? '')
            .replaceAll(RegExp(r'[，。？！、\s]'), '');
        if (t.isNotEmpty &&
            clean.isNotEmpty &&
            (t == clean || t.contains(clean) || clean.contains(t))) {
          target = item;
          break;
        }
      }
    }
    target ??= micTestHistory.first;

    target['llmDecision'] = llmDecision;
    if (shouldReply != null) {
      target['shouldReply'] = shouldReply;
    }
    if (intent != null) {
      target['intent'] = intent;
    }
    if (detail != null) {
      target['detail'] = detail;
    }
    if (similarity != null) {
      target['similarity'] = similarity;
    }
    if (similarityPercent != null) {
      target['similarityPercent'] = similarityPercent;
    }
    if (speakerMatched != null) {
      target['speakerMatched'] = speakerMatched;
    }
    if (speakerStatus != null) {
      target['speakerStatus'] = speakerStatus;
    }

    emit(MicTestUpdatedEvent(
      micTestText,
      micTestHistory,
      durationMs: (target['durationMs'] as int?) ?? 0,
      engine: (target['engine'] as String?) ?? asrService.engineName,
    ));
    onNotify();
  }

  /// 局部增量应用音频配置更新
  void applyAudioConfig(AudioConfig newAudioConfig,
      {AppSettings? newSettings}) {
    final oldSettings = settings;
    if (newSettings != null) {
      settings = newSettings;
    }
    final needAsrRebuild = oldSettings.pipelineMode != settings.pipelineMode ||
        oldSettings.asrEngine != settings.asrEngine ||
        oldSettings.audioInputDeviceId != settings.audioInputDeviceId ||
        oldSettings.enableTwoPass != settings.enableTwoPass ||
        oldSettings.geminiApiKey != settings.geminiApiKey ||
        oldSettings.geminiAsrModel != settings.geminiAsrModel;

    if (needAsrRebuild) {
      initServices();
    } else {
      if (oldSettings.speakerModelPath != settings.speakerModelPath) {
        speakerVerificationService.dispose();
        speakerVerificationService =
            SpeakerVerifierFactoryRegistry.defaultFactory?.call(settings) ??
                const NullSpeakerVerifier();
        if (settings.enableSpeakerVerification ||
            settings.enableTargetSpeakerExtraction) {
          unawaited(speakerVerificationService.initialize());
        }
      } else if (settings.enableSpeakerVerification ||
          settings.enableTargetSpeakerExtraction) {
        if (!speakerVerificationService.isReady) {
          unawaited(speakerVerificationService.initialize());
        }
      }
      targetSpeakerExtractionService =
          TargetSpeakerExtractionFactoryRegistry.defaultFactory?.call(
                settings,
                speakerVerificationService,
              ) ??
              const NullTargetSpeakerExtraction();

      voiceListeningService.applyConfig(newAudioConfig);
    }
  }

  /// 资源销毁
  void dispose() {
    _disposed = true;
    servicesGeneration++;
    voiceListeningService.dispose();
    _disposeAsrInstances();
    speakerVerificationService.dispose();
  }
}
