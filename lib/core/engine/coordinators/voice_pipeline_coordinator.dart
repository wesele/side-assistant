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
  bool isEnrollingSpeaker = false;
  int servicesGeneration = 0;
  bool _disposed = false;
  bool _servicesInitialized = false;

  // ASR 引擎装配函数（可选外部注入，默认由 AsrFactoryRegistry 装配）
  final AsrEngineBundle Function(AppSettings settings)? asrEngineBuilder;
  final Future<String> Function(AppSettings settings, {String? apiKey, String? model})?
      geminiTester;

  VoicePipelineCoordinator({
    required this.settings,
    required this.emit,
    required this.onNotify,
    this.onRecognizedText,
    this.onPartialTranscript,
    this.onFinalTranscript,
    this.onManualRecordingRecognized,
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
  int get enrolledSpeakerCount => speakerVerificationService.enrolledSampleCount;
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
            const _DummySpeakerVerifier();
    targetSpeakerExtractionService =
        TargetSpeakerExtractionFactoryRegistry.defaultFactory?.call(
              settings,
              speakerVerificationService,
            ) ??
            const _DummyTargetSpeakerExtraction();
    if (settings.enableSpeakerVerification ||
        settings.enableTargetSpeakerExtraction) {
      unawaited(speakerVerificationService.initialize());
    }

    final AsrEngineBundle bundle;
    final builder = asrEngineBuilder ?? AsrFactoryRegistry.defaultFactory;
    if (builder != null) {
      bundle = builder(settings);
    } else {
      const dummyAsr = _DummyAsrPort();
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
          micTestHistory.insert(0, {
            'time': timeStr,
            'text': text,
            'durationMs': durationMs,
            'engine': asrService.engineName,
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
      voiceListeningService = _DummyVoiceListening()
        ..isMicTesting = isMicTesting
        ..isEnrollingSpeaker = isEnrollingSpeaker;
    }

    if (primaryAsr.isCloudStreaming) {
      primaryAsr.onPartialText = (text) {
        onPartialTranscript?.call(text);
      };
    }

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
  }) {
    if (!settings.enableSpeakerVerification) return true;
    if (!speakerVerificationService.hasEnrolledOwner) return true;

    final audio = voiceListeningService.lastRecognizedAudio ??
        voiceListeningService.getRecentAudio(seconds: 2.5);
    if (audio.isEmpty) return true;

    final isShortContext = contextHint.contains('唤醒') ||
        contextHint.contains('打断') ||
        contextHint.contains('重置');
    final effectiveThreshold = isShortContext
        ? (settings.speakerSimilarityThreshold - 0.08).clamp(0.40, 0.65)
        : settings.speakerSimilarityThreshold;

    final result = speakerVerificationService.verifyOwner(
      audio,
      customThreshold: effectiveThreshold,
    );
    if (result.bypassed || result.isMatched) {
      debugPrint(
        '[VoicePipelineCoordinator] 主人声纹校验通过 ($contextHint): '
        '${(result.similarity * 100).toStringAsFixed(1)}% (耗时 ${result.durationMs}ms)',
      );
      return true;
    }

    debugPrint(
      '[VoicePipelineCoordinator] 主人声纹校验拦截 ($contextHint): '
      '${(result.similarity * 100).toStringAsFixed(1)}% < ${(effectiveThreshold * 100).toStringAsFixed(1)}% (耗时 ${result.durationMs}ms)',
    );
    final reason =
        '检测到$contextHint词，但声纹不匹配 (${(result.similarity * 100).toStringAsFixed(1)}% < ${(effectiveThreshold * 100).toInt()}%)，已忽略';
    onRejected?.call(reason);
    return false;
  }

  /// 校验指定原始 PCM 字节数据是否匹配主人声纹
  @override
  Future<SpeakerVerificationResult> verifyOwnerSpeakerData(
    List<int> pcmData, {
    required int sampleRate,
  }) async {
    if (pcmData.isEmpty) {
      return SpeakerVerificationResult.bypassed(reason: 'PCM 数据为空');
    }
    final numSamples = pcmData.length ~/ 2;
    final floatList = Float32List(numSamples);
    final byteData = ByteData.sublistView(Uint8List.fromList(pcmData));
    for (int i = 0; i < numSamples; i++) {
      floatList[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    final res = speakerVerificationService.verifyOwner(
      floatList,
      sampleRate: sampleRate,
    );
    return SpeakerVerificationResult(
      isMatched: res.isMatched,
      similarity: res.similarity,
      hasEnrolledOwner: res.hasEnrolledOwner,
      bypassed: res.bypassed,
      reason: res.reason,
      durationMs: res.durationMs,
    );
  }

  /// 获取最近音频切片 (Float32List)
  Float32List? getRecentAudioSnippet({double seconds = 3.0}) {
    return voiceListeningService.lastRecognizedAudio ??
        voiceListeningService.getRecentAudio(seconds: seconds);
  }

  /// 使用提供的样本录入主人声纹
  Future<bool> enrollOwnerSpeaker({Float32List? samples}) async {
    final audio = samples ??
        voiceListeningService.lastRecognizedAudio ??
        voiceListeningService.getRecentAudio(seconds: 3.0);
    final minEnrollSamples = (0.75 * 16000).round();
    if (audio.isEmpty || audio.length < minEnrollSamples) {
      debugPrint(
        '[VoicePipelineCoordinator] 录制声纹失败：有效音频过短（需 >= 0.75s）',
      );
      return false;
    }

    await speakerVerificationService.saveDebugWave(audio);
    final success = await speakerVerificationService.enrollOwner(audio);
    if (success) {
      voiceListeningService.flushBuffers(cooldownMs: 500);
      voiceListeningService.resetStream();
      onNotify();
    }
    return success;
  }

  /// 录制并录入主人声纹
  Future<bool> recordAndEnrollOwnerSpeaker({double seconds = 3.5}) async {
    final wasListening = voiceListeningService.isListening;
    isEnrollingSpeaker = true;
    voiceListeningService.isEnrollingSpeaker = true;
    onNotify();

    try {
      if (!wasListening) {
        await voiceListeningService.startContinuousListening();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final recordDurationMs = (seconds * 1000).round();
      final preClickAudio = voiceListeningService.getRecentAudio(seconds: 1.5);
      voiceListeningService.clearRecentAudio();
      await Future<void>.delayed(Duration(milliseconds: recordDurationMs));

      var totalWindowSec = seconds;
      var audio = voiceListeningService.getRecentAudio(seconds: totalWindowSec);
      if (audio.isNotEmpty) {
        for (int extra = 0; extra < 4; extra++) {
          final trimmed = speakerVerificationService.trimAudioToSpeech(
            audio,
            minSeconds: 0.75,
          );
          if (trimmed.length >= (16000 * 1.2).round()) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
          totalWindowSec += 0.25;
          audio = voiceListeningService.getRecentAudio(seconds: totalWindowSec);
        }
      }
      if (preClickAudio.isNotEmpty &&
          speakerVerificationService.trimAudioToSpeech(
                audio,
                minSeconds: 0.75,
              ).length <
              (0.75 * 16000).round()) {
        final combined = Float32List(preClickAudio.length + audio.length);
        combined.setRange(0, preClickAudio.length, preClickAudio);
        combined.setRange(preClickAudio.length, combined.length, audio);
        if (speakerVerificationService.trimAudioToSpeech(
              combined,
              minSeconds: 0.75,
            ).length >=
            (0.75 * 16000).round()) {
          audio = combined;
        }
      }
      final success = await enrollOwnerSpeaker(samples: audio);
      return success;
    } finally {
      voiceListeningService.flushBuffers(cooldownMs: 600);
      voiceListeningService.resetStream();
      isEnrollingSpeaker = false;
      voiceListeningService.isEnrollingSpeaker = false;

      if (!wasListening) {
        await voiceListeningService.stopContinuousListening();
      }
      onNotify();
    }
  }

  /// 清空已录入的主人声纹
  Future<void> clearOwnerSpeaker() async {
    await speakerVerificationService.clearOwnerEmbeddings();
    onNotify();
  }

  /// 录制并测试与主人声纹的相似度
  Future<Map<String, dynamic>> recordAndTestOwnerSpeakerSimilarity({
    double seconds = 3.0,
  }) async {
    final wasListening = voiceListeningService.isListening;
    isEnrollingSpeaker = true;
    voiceListeningService.isEnrollingSpeaker = true;
    onNotify();

    try {
      if (!wasListening) {
        await voiceListeningService.startContinuousListening();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final recordDurationMs = (seconds * 1000).round();
      final preClickAudio = voiceListeningService.getRecentAudio(seconds: 1.5);
      voiceListeningService.clearRecentAudio();
      await Future<void>.delayed(Duration(milliseconds: recordDurationMs));

      var totalWindowSec = seconds;
      var audio = voiceListeningService.getRecentAudio(seconds: totalWindowSec);
      final minSamples = speakerVerificationService.minAudioSamples;
      final minSec = speakerVerificationService.minSpeechSeconds;
      if (audio.isNotEmpty) {
        for (int extra = 0; extra < 4; extra++) {
          final trimmed = speakerVerificationService.trimAudioToSpeech(
            audio,
            minSeconds: minSec,
          );
          if (trimmed.length >= (16000 * 1.0).round()) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
          totalWindowSec += 0.25;
          audio = voiceListeningService.getRecentAudio(seconds: totalWindowSec);
        }
      }
      if (preClickAudio.isNotEmpty &&
          speakerVerificationService.trimAudioToSpeech(
            audio,
            minSeconds: minSec,
          ).length < minSamples) {
        final combined = Float32List(preClickAudio.length + audio.length);
        combined.setRange(0, preClickAudio.length, preClickAudio);
        combined.setRange(preClickAudio.length, combined.length, audio);
        if (speakerVerificationService.trimAudioToSpeech(
              combined,
              minSeconds: minSec,
            ).length >= minSamples) {
          audio = combined;
        }
      }
      return await testOwnerSpeakerSimilarity(samples: audio);
    } finally {
      voiceListeningService.flushBuffers(cooldownMs: 600);
      voiceListeningService.resetStream();
      isEnrollingSpeaker = false;
      voiceListeningService.isEnrollingSpeaker = false;

      if (!wasListening) {
        await voiceListeningService.stopContinuousListening();
      }
      onNotify();
    }
  }

  /// 测试样本与主人声纹的余弦相似度
  Future<Map<String, dynamic>> testOwnerSpeakerSimilarity({
    Float32List? samples,
  }) async {
    if (!speakerVerificationService.isReady) {
      final ok = await speakerVerificationService.initialize();
      if (!ok) {
        return {
          'error': '声纹模型加载失败，请检查模型文件',
          'passed': false,
          'similarity': 0.0,
        };
      }
    }
    if (!speakerVerificationService.hasEnrolledOwner ||
        speakerVerificationService.enrolledSampleCount == 0) {
      return {
        'error': '尚未录入主人声纹（当前模型需要重新录制），请先点击录制样本',
        'passed': false,
        'similarity': 0.0,
      };
    }

    final audio = samples ??
        voiceListeningService.lastRecognizedAudio ??
        voiceListeningService.getRecentAudio(seconds: 3.0);
    final minSamples = speakerVerificationService.minAudioSamples;
    final minSec = speakerVerificationService.minSpeechSeconds;
    if (audio.isEmpty || audio.length < minSamples) {
      return {
        'error':
            '未捕获到足够时长的语音（请先对着麦克风说话 >= ${minSec.toStringAsFixed(2)}秒）',
        'passed': false,
        'similarity': 0.0,
      };
    }

    final debugPath =
        await speakerVerificationService.saveDebugWave(audio);

    final analysis = speakerVerificationService.analyzeOwner(audio);
    if (analysis.hasError) {
      return {
        'error': analysis.error,
        'passed': false,
        'similarity': 0.0,
        'durationMs': analysis.durationMs,
        'text': analysis.error,
        if (debugPath != null) 'debugWavePath': debugPath,
      };
    }

    final threshold = settings.speakerSimilarityThreshold;
    final isPass = analysis.similarity >= threshold;
    final simPct = (analysis.similarity * 100).toStringAsFixed(1);
    final threshPct = (threshold * 100).toStringAsFixed(0);
    final samplePcts = analysis.sampleSimilarities
        .map((s) => double.parse((s * 100).toStringAsFixed(1)))
        .toList(growable: false);
    final text = '与主人声纹匹配度: $simPct% '
        '(${isPass ? "✅ 判定为主人" : "❌ 未达到阈值 $threshPct%"})';

    debugPrint(
      '[VoicePipelineCoordinator] 声纹测试: 综合=$simPct% '
      '质心=${(analysis.centroidSimilarity * 100).toStringAsFixed(1)}% '
      '单样本最高=${(analysis.maxSampleSimilarity * 100).toStringAsFixed(1)}% '
      '均值=${(analysis.meanSampleSimilarity * 100).toStringAsFixed(1)}% '
      '有效语音=${analysis.speechSeconds.toStringAsFixed(2)}s '
      '阈值=$threshPct% 样本=${samplePcts.join("/")}',
    );

    return {
      'similarity': analysis.similarity,
      'similarityPercent': double.parse(simPct),
      'threshold': threshold,
      'passed': isPass,
      'durationMs': analysis.durationMs,
      'speechSeconds': analysis.speechSeconds,
      'centroidSimilarity': analysis.centroidSimilarity,
      'maxSampleSimilarity': analysis.maxSampleSimilarity,
      'meanSampleSimilarity': analysis.meanSampleSimilarity,
      'sampleSimilarities': analysis.sampleSimilarities,
      'samplePercents': samplePcts,
      'enrolledCount': speakerVerificationService.enrolledSampleCount,
      'debugAudioPath': debugPath,
      'text': text,
    };
  }

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

  /// 局部增量应用音频配置更新
  void applyAudioConfig(AudioConfig newAudioConfig, {AppSettings? newSettings}) {
    final oldSettings = settings;
    if (newSettings != null) {
      settings = newSettings;
    }
    final needAsrRebuild =
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
                const _DummySpeakerVerifier();
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
              const _DummyTargetSpeakerExtraction();

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

class _DummySpeakerVerifier implements SpeakerVerifierPort {
  const _DummySpeakerVerifier();

  @override
  int get enrolledSampleCount => 0;

  @override
  bool get hasEnrolledOwner => false;

  @override
  String get modelLabel => '未配置声纹服务';

  @override
  String? get lastEnrollError => null;

  @override
  bool get isReady => false;

  @override
  double get energyThreshold => 1e-4;

  @override
  int get minAudioSamples => 4800;

  @override
  double get minSpeechSeconds => 0.3;

  @override
  Future<bool> initialize() async => true;

  @override
  SpeakerVerificationResult verifyOwner(
    Float32List audio, {
    int sampleRate = 16000,
    double? customThreshold,
    double? customMinSpeechSeconds,
    String contextHint = '唤醒',
  }) =>
      SpeakerVerificationResult.bypassed(reason: '未配置声纹服务');

  @override
  Future<bool> enrollOwner(Float32List audio) async => false;

  @override
  Future<void> clearOwnerEmbeddings() async {}

  @override
  SpeakerAnalysisResult analyzeOwner(Float32List audio) =>
      const _DummySpeakerAnalysis();

  @override
  Future<String?> saveDebugWave(Float32List samples, {String fileName = 'speaker_test_last.wav'}) async =>
      null;

  @override
  Float32List trimAudioToSpeech(Float32List samples, {double minSeconds = 0.75}) =>
      samples;

  @override
  void dispose() {}
}

class _DummySpeakerAnalysis implements SpeakerAnalysisResult {
  const _DummySpeakerAnalysis();

  @override
  bool get hasError => true;

  @override
  String? get error => '未配置声纹服务';

  @override
  double get similarity => 0.0;

  @override
  double get centroidSimilarity => 0.0;

  @override
  double get maxSampleSimilarity => 0.0;

  @override
  double get meanSampleSimilarity => 0.0;

  @override
  List<double> get sampleSimilarities => const [];

  @override
  double get speechSeconds => 0.0;

  @override
  int get durationMs => 0;

  @override
  bool get insufficientSpeech => false;
}

class _DummyTargetSpeakerExtraction implements TargetSpeakerExtractionPort {
  const _DummyTargetSpeakerExtraction();

  @override
  bool get hasEnrolledOwner => false;

  @override
  dynamic extractTargetSpeaker(Float32List audio) => null;
}

class _DummyVoiceListening implements VoiceListeningPort {
  @override
  bool isListening = false;

  @override
  bool isManualRecording = false;

  @override
  double micLevel = 0.0;

  @override
  double micDbfs = -100.0;

  @override
  bool vadDetected = false;

  @override
  String activeInputDeviceLabel = '默认麦克风';

  @override
  bool isEnrollingSpeaker = false;

  @override
  bool isMicTesting = false;

  @override
  Future<bool> startContinuousListening() async => true;

  @override
  Future<void> stopContinuousListening() async {}

  @override
  Future<void> toggleContinuousListening() async {}

  @override
  Future<bool> startManualRecording() async => true;

  @override
  Future<String?> stopManualRecording() async => null;

  @override
  Future<void> applyInputDeviceChange() async {}

  @override
  void flushBuffers({int cooldownMs = 600}) {}

  @override
  void resetStream() {}

  @override
  void performIdleHygiene() {}

  @override
  Float32List? get lastRecognizedAudio => null;

  @override
  Float32List getRecentAudio({double seconds = 2.5}) => Float32List(0);

  @override
  void clearRecentAudio() {}

  @override
  bool get isInCooldownWindow => false;

  @override
  void Function(double level, double dbfs, bool vadDetected)? get onAudioLevelChanged => null;

  @override
  void Function(bool isListening, String statusHint)? get onStateChanged => null;

  @override
  void Function(String text, int durationMs)? get onMicTestRecognized => null;

  @override
  Future<void> setAsrService(AsrPort next) async {}

  @override
  void applyConfig(AudioConfig config) {}

  @override
  void dispose() {}
}

class _DummyAsrPort implements AsrPort {
  const _DummyAsrPort();

  @override
  bool get isStreaming => false;

  @override
  bool get isCloudStreaming => false;

  @override
  bool get isReady => false;

  @override
  String get engineName => 'dummy';

  @override
  void Function(String text)? get onPartialText => null;

  @override
  set onPartialText(void Function(String text)? callback) {}

  @override
  double adjustVadMinSilence(double requested) => requested;

  @override
  Future<void> initialize() async {}

  @override
  Future<String> transcribeAudioFile(String filePath, {bool isStandbyWakeCheck = false}) async =>
      '';

  @override
  void dispose() {}
}

