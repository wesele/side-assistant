import 'dart:async';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../core/platform/audio_recorder_bridge.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/ports/asr_port.dart';
import '../../core/ports/target_speaker_extraction_port.dart';
import '../../core/ports/voice_listening_port.dart';
import 'asr_service.dart';
import 'foreground_service_bridge.dart';
import 'speaker_verification_service.dart';
import 'support/audio_segment_buffer.dart';
import 'support/barge_in_probe.dart';
import 'support/chunk_listening_recorder.dart';
import 'support/final_pass_runner.dart';
import 'support/input_device_resolver.dart';
import 'support/live_utterance_session.dart';
import 'support/manual_recording_session.dart';
import 'support/mic_level_state.dart';
import 'support/native_streaming_session.dart';
import 'support/pcm_audio_utils.dart';
import 'support/tse_applier.dart';
import 'support/voice_prompt_text.dart';

/// 麦克风语音采集与识别的编排层。
///
/// 这里只保留**时序耦合强**的部分：VAD 切段与转写互斥、静音冷却窗、
/// flush 代际、采集流建立/看门狗重启/降级切片。
/// 可独立验证的子能力已抽到 `support/`：
/// - `audio_segment_buffer.dart`：预卷环、整段环、预卷/尾垫拼装
/// - `tse_applier.dart`：目标说话人抽取后处理
/// - `live_utterance_session.dart`：边说边传（云端实时引擎）
/// - `native_streaming_session.dart`：内置流式识别器在线解码
/// - `barge_in_probe.dart`：播报期滚动短窗打断探针
/// - `final_pass_runner.dart`：两遍解码的第二遍复检
/// - `manual_recording_session.dart` / `input_device_resolver.dart` /
///   `mic_level_state.dart` / `pcm_audio_utils.dart` / `voice_prompt_text.dart`
class VoiceListeningService implements VoiceListeningPort {
  AsrService asrService;

  /// 两遍解码的第二遍：流式端点命中后，用内置 SenseVoice 对整段音频复检。
  AsrService? finalAsrService;

  /// 方案二：目标说话人语音抽取（TSE）服务
  final TargetSpeakerExtractionPort? targetSpeakerExtractionService;

  AppSettings settings;

  /// 局部热重载：更新音频/VAD参数，避免卸载重建 ASR 模型与麦克风采集流
  @override
  void applyConfig(AudioConfig config) {
    settings.audio = config;
  }

  final void Function(String text) onTextRecognized;
  final void Function(String text)? onFinalTranscript;
  final void Function(String text)? onManualRecordingRecognized;
  @override
  final void Function(bool isListening, String statusHint)? onStateChanged;
  @override
  final void Function(double level, double dbfs, bool vadDetected)?
      onAudioLevelChanged;
  @override
  final void Function(String text, int durationMs)? onMicTestRecognized;
  final bool Function()? isStandbyMode;
  final bool Function()? isPlayingMode;

  @override
  @override
  bool isMicTesting = false;
  @override
  bool isEnrollingSpeaker = false;

  /// 麦克风电平状态与发射节流，见 `support/mic_level_state.dart`。
  final MicLevelState _micLevel = MicLevelState();

  @override
  double get micLevel => _micLevel.level;
  @override
  double get micDbfs => _micLevel.dbfs;
  @override
  bool get vadDetected => _micLevel.vadDetected;

  final PlatformAudioRecorder _recorder = PlatformAudioRecorder();

  /// 录音设备解析与麦克风权限，见 `support/input_device_resolver.dart`。
  late final InputDeviceResolver _device =
      InputDeviceResolver(recorder: _recorder);

  /// 手动单次录音（对讲模式），见 `support/manual_recording_session.dart`。
  late final ManualRecordingSession _manualRecording = ManualRecordingSession(
    recorder: _recorder,
    asrService: () => asrService,
    device: () => _device.active,
    stopListening: () async {
      if (_isListening) await stopContinuousListening();
    },
    hasPermission: hasPermission,
    refreshDevice: refreshInputDevice,
    onTextRecognized: onTextRecognized,
    onManualRecordingRecognized: onManualRecordingRecognized,
    onStateChanged: onStateChanged,
  );

  bool _isListening = false;
  bool _disposed = false;
  Timer? _loopTimer;
  ChunkListeningRecorder? _chunkRecorder;

  /// 内置流式识别器（Zipformer 等）的在线解码会话，
  /// 见 `support/native_streaming_session.dart`。
  late final NativeStreamingSession _streaming = NativeStreamingSession(
    asrService: () => asrService,
    buffer: _segmentBuffer,
    hotwords: () => _hotwords,
    isStandby: () => isStandbyMode?.call() ?? true,
    isPlaying: () => isPlayingMode?.call() ?? false,
    isMicTesting: () => isMicTesting,
    isEnrollingSpeaker: () => isEnrollingSpeaker,
    isInCooldown: () => isInCooldownWindow,
    onTextRecognized: onTextRecognized,
    onRecognizedAudio: (audio) => _lastRecognizedAudio = audio,
    onFinalPass: (audio) => unawaited(_runFinalPass(audio)),
    onMicTestRecognized: onMicTestRecognized,
  );

  sherpa_onnx.VoiceActivityDetector? _vad;
  StreamSubscription<Uint8List>? _recordStreamSub;
  bool _isTranscribing = false;
  DateTime _suppressAudioUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // ---- 音频采集看门狗 ----
  // 即使修好了音频焦点问题，OEM 后台策略、来电、音频 HAL 异常仍可能让采集流
  // 悄悄停掉。只要连续若干秒一个 PCM 包都没到，就自动重建采集。
  Timer? _audioWatchdog;
  DateTime? _lastAudioChunkAt;
  bool _usingStreamMode = false;
  bool _restartingAudio = false;

  // ---- 预卷 / 尾垫 ----
  // 维护最近 35 秒的连续音频环，VAD 段输出时按“段尾 - 尾静音”反推段首，
  // 从环里精确截取段前 300ms 补回去，避免句首轻辅音被削掉。
  // 环与拼装规则见 `support/audio_segment_buffer.dart`。
  final AudioSegmentBuffer _segmentBuffer = AudioSegmentBuffer();

  /// 最近一次识别事件所对应的原始音频片段（可供声纹比对校验）
  Float32List? _lastRecognizedAudio;
  @override
  Float32List? get lastRecognizedAudio => _lastRecognizedAudio;

  /// 获取最近 N 秒的连续 PCM 音频切片
  @override
  Float32List getRecentAudio({double seconds = 2.5}) =>
      _segmentBuffer.recent(seconds: seconds);

  /// 清空最近音频缓存并立即解除静音冷却窗（不影响 VAD/ASR 状态）。
  ///
  /// 声纹录入/测试前调用，既避免把上一次说话的旧音频当成新样本，
  /// 也防止上一次操作残留的 600ms 冷却窗吞掉新录音开头的语音。
  @override
  void clearRecentAudio() {
    _suppressAudioUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _resetAudioRing();
  }

  /// 实际创建 VAD 时使用的尾静音时长（引擎可能按自身特性微调）。
  /// 预卷偏移必须与它保持一致，否则会多补/少补一段音频。
  double _effectiveVadMinSilence = AppConstants.defaultVadMinSilenceSeconds;

  // ---- 两遍解码 ----
  /// 第二遍复检，见 `support/final_pass_runner.dart`。
  late final FinalPassRunner _finalPass = FinalPassRunner(
    finalAsrService: () => finalAsrService,
    tse: _tse,
    onFinalTranscript: onFinalTranscript,
  );

  // ---- 边说边传（Gemini 等云端实时引擎） ----
  int _flushGeneration = 0;

  /// 边说边传会话，见 `support/live_utterance_session.dart`。
  late final LiveUtteranceSession _live = LiveUtteranceSession(
    asrService: () => asrService,
    buffer: _segmentBuffer,
    isStandby: () => isStandbyMode?.call() ?? true,
    isPlaying: () => isPlayingMode?.call() ?? false,
    isMicTesting: () => isMicTesting,
    isEnrollingSpeaker: () => isEnrollingSpeaker,
    isInCooldown: () => isInCooldownWindow,
    flushGeneration: () => _flushGeneration,
    isListening: () => _isListening,
    standbyHint: () => standbyHint,
    onStateChanged: onStateChanged,
    onTextRecognized: onTextRecognized,
    onRecognizedAudio: (audio) => _lastRecognizedAudio = audio,
    onMicTestRecognized: onMicTestRecognized,
  );

  // ---- 播报期滚动短窗打断探针（解决长语音外放不断、VAD 永不切段问题） ----
  /// 探针状态机见 `support/barge_in_probe.dart`。
  late final BargeInProbe _bargeIn = BargeInProbe(
    asrService: () => asrService,
    buffer: _segmentBuffer,
    tse: _tse,
    isPlaying: () => isPlayingMode?.call() ?? false,
    isInCooldown: () => isInCooldownWindow,
    isTranscribing: () => _isTranscribing,
    onTextRecognized: onTextRecognized,
    onRecognizedAudio: (audio) => _lastRecognizedAudio = audio,
    postRollMs: () => settings.postRollMs,
  );

  VoiceListeningService({
    required this.asrService,
    required this.settings,
    required this.onTextRecognized,
    this.finalAsrService,
    this.targetSpeakerExtractionService,
    this.onFinalTranscript,
    this.onManualRecordingRecognized,
    this.onStateChanged,
    this.onAudioLevelChanged,
    this.onMicTestRecognized,
    this.isStandbyMode,
    this.isPlayingMode,
  });

  /// 方案二：目标说话人抽取（TSE）后处理，见 `support/tse_applier.dart`。
  late final TseApplier _tse = TseApplier(
    service: targetSpeakerExtractionService,
    isEnabled: () => settings.enableTargetSpeakerExtraction,
  );

  @override
  bool get isListening => _isListening;
  @override
  bool get isManualRecording => _manualRecording.isRecording;

  /// 待机提示文案，见 `support/voice_prompt_text.dart`。
  String get standbyHint => VoicePromptText.standbyHint(settings);

  /// 送 ASR 的热词表，见 `support/voice_prompt_text.dart`。
  String get _hotwords => VoicePromptText.hotwords(settings);

  /// 运行期切换 ASR 实现（例如流式识别器初始化失败时降级到 SenseVoice）。
  ///
  /// 必须同步替换内部持有的引用，否则麦克风路径仍会调用已失效的识别器
  /// （流式实现 isStreaming 恒为 true 且拿不到 onlineStream），导致完全不识别。
  @override
  Future<void> setAsrService(AsrPort next) async {
    final asr = next as AsrService;
    if (identical(asr, asrService)) return;
    final wasListening = _isListening;
    if (wasListening) {
      await stopContinuousListening();
    }
    _streaming.free();
    _vad?.free();
    _vad = null;
    _resetUtteranceBuffer();
    _resetAudioRing();
    _live.reset();
    asrService = asr;
    if (wasListening) {
      await startContinuousListening();
    }
  }

  /// 检查当前是否处于播放结束/打断后的静音冷却保护期
  @override
  bool get isInCooldownWindow => DateTime.now().isBefore(_suppressAudioUntil);

  /// 重置当前流式识别器输入状态
  @override
  void resetStream() => _streaming.reset();

  /// 清空两遍解码的整段音频缓冲
  void _resetUtteranceBuffer() {
    _segmentBuffer.clearUtterance();
  }

  /// 清空预卷音频环
  void _resetAudioRing() {
    _segmentBuffer.clearRecent();
    _bargeIn.resetCounter();
  }

  /// 重置/清空所有积压的音频切片与 VAD 缓冲区，并设立保护冷却窗（丢弃播放残余外放尾音，防回声误识别）
  @override
  void flushBuffers({int cooldownMs = 400}) {
    _flushGeneration++;
    _suppressAudioUntil =
        DateTime.now().add(Duration(milliseconds: cooldownMs));
    _vad?.clear();
    _vad?.reset();
    resetStream();
    _resetUtteranceBuffer();
    _resetAudioRing();
    // 被打断或结束播报时如果正在进行边说边传，直接把它收掉并丢弃结果（这段音频已经被判为回声或已提交）。
    _live.discard();
    debugPrint(
        '[VoiceListeningService] 已清空音频与 VAD/流式缓冲，进入 ${cooldownMs}ms 冷却静音窗');
  }

  /// 空闲待机保洁：在长期待机无声时定期重置 VAD RNN 隐藏状态与音频缓冲，防止长时间静音引起的隐藏层漂移或积压
  @override
  void performIdleHygiene() {
    if (_isListening && !_live.isActive) {
      _vad?.clear();
      _vad?.reset();
      resetStream();
      _resetUtteranceBuffer();
      _resetAudioRing();
      debugPrint('[VoiceListeningService] 空闲保洁已执行：已重置 VAD 隐藏状态与音频环');
    }
  }

  /// 检查麦克风权限
  Future<bool> hasPermission() => _device.hasPermission();

  /// 本次采集实际使用的录音设备（null = 自动/系统默认）。
  PlatformInputDevice? get activeInputDevice => _device.active;

  /// 按设置解析要使用的录音设备并缓存（规则见 `support/input_device_resolver.dart`）。
  Future<void> refreshInputDevice() =>
      _device.resolve(settings.audioInputDeviceId);

  /// 供 UI / 调试用的设备描述。
  @override
  String get activeInputDeviceLabel => _device.label;

  /// 设置里的录音设备变化后立即生效。
  ///
  /// 只重建音频采集链路，不重建 ASR 服务：模型与云端连接保持不动，
  /// 比整轮 `_initServices()` 快得多，也不会打断正在识别的内容。
  /// 话筒未开启时只更新缓存，下次开启采集时自然生效。
  @override
  Future<void> applyInputDeviceChange() async {
    if (_disposed || isManualRecording) return;
    if (_isListening) {
      await _restartAudioStream();
    } else {
      await refreshInputDevice();
    }
  }

  /// 测试用：不启动麦克风，只按正式路径初始化 VAD。
  @visibleForTesting
  Future<void> initializeVadForTest() async {
    _effectiveVadMinSilence = asrService.adjustVadMinSilence(
      settings.vadMinSilenceSeconds,
    );
    _vad = await asrService.createVad(
      minSilenceDuration: _effectiveVadMinSilence,
      minSpeechDuration: settings.vadMinSpeechSeconds,
      maxSpeechDuration: settings.vadMaxSpeechSeconds,
    );
    _isListening = true;
  }

  /// 测试用：把一段 16k 音频喂进与麦克风完全相同的处理路径。
  @visibleForTesting
  Future<void> feedAudioForTest(Float32List samples) async {
    if (_disposed || !_isListening || asrService.isStreaming) return;
    if (DateTime.now().isBefore(_suppressAudioUntil)) return;
    if (_vad == null) return;

    _appendAudioRing(samples);
    _vad!.acceptWaveform(samples);
    if (asrService.supportsLiveStreaming) {
      _drainVadSegments(transcribe: false);
      _pumpLiveAudio(samples);
    } else {
      await _drainVadSegments();
      await _maybeProbePlayingBargeIn(samples.length);
    }
  }

  /// 启动持续待机监听（优先原生 Silero VAD 内存实时流，无缝降级短切片）
  @override
  Future<bool> startContinuousListening() async {
    if (_isListening) return true;

    final permitted = await hasPermission();
    if (!permitted) {
      onStateChanged?.call(false, '麦克风权限未授予');
      return false;
    }

    _isListening = true;
    await refreshInputDevice();
    await ForegroundServiceBridge.start(
      title: '随身助理后台运行中',
      content: VoicePromptText.foregroundContent(settings),
      micListening: true,
      capsuleEnabled: settings.enableFloatingCapsule,
      status: '待机',
    );
    onStateChanged?.call(true, standbyHint);

    bool streamStarted = false;
    try {
      if (asrService.isStreaming) {
        _streaming.ensureStream();
      } else {
        final effectiveMinSilence = asrService.adjustVadMinSilence(
          settings.vadMinSilenceSeconds,
        );
        _effectiveVadMinSilence = effectiveMinSilence;
        _vad ??= await asrService.createVad(
          minSilenceDuration: effectiveMinSilence,
          minSpeechDuration: settings.vadMinSpeechSeconds,
          maxSpeechDuration: settings.vadMaxSpeechSeconds,
          threshold: settings.vadThreshold,
        );
      }

      await _startAudioStream();
      streamStarted = true;
      debugPrint(
        '[VoiceListeningService] 成功启动实时流式音频监听'
        '（streamBufferSize: ${_recorder.streamBufferSize}, '
        'audioInterruption: ${_recorder.audioInterruptionName}, '
        'isStreaming=${asrService.isStreaming}）！',
      );
    } catch (e, st) {
      debugPrint('[VoiceListeningService] 启动实时音频流失败: $e\n$st，降级为切片模式');
      streamStarted = false;
    }

    if (!streamStarted) {
      await _fallbackToChunkListening();
    }
    return true;
  }

  /// 把新到的 PCM 追加到预卷环，保留最近 35 秒。
  void _appendAudioRing(Float32List samples) {
    _segmentBuffer.addRecent(samples);
  }

  /// 从预卷环中截取 VAD 段之前的 preRollMs 毫秒音频。
  Float32List _prependPreRoll(Float32List segment) =>
      _segmentBuffer.prependPreRoll(
        segment,
        preRollMs: settings.preRollMs,
        vadMinSilenceSeconds: _effectiveVadMinSilence,
        vadMaxSpeechSeconds: settings.vadMaxSpeechSeconds,
      );

  /// 在段尾补一小段静音，帮助 CTC/注意力模型收尾。
  Float32List _appendTailSilence(Float32List segment) => _segmentBuffer
      .appendTailSilence(segment, postRollMs: settings.postRollMs);

  /// 追加到两遍解码的整段音频缓冲（最多 35 秒）。
  void _appendUtterance(Float32List samples) {
    _segmentBuffer.addUtterance(samples);
  }

  Future<void> _drainVadSegments({bool transcribe = true}) async {
    if (_vad == null || _disposed || !_isListening) return;
    if (transcribe && _isTranscribing) return;

    if (DateTime.now().isBefore(_suppressAudioUntil)) {
      _vad!.clear();
      _vad!.reset();
      return;
    }

    while (!_vad!.isEmpty()) {
      if (DateTime.now().isBefore(_suppressAudioUntil)) {
        _vad!.clear();
        _vad!.reset();
        break;
      }
      final segment = _vad!.front();
      _vad!.pop();
      _bargeIn.resetCounter();
      if (segment.samples.isEmpty) continue;

      final rawWithPreRoll =
          SpeakerVerificationService.concealBluetoothScoDropouts(
        _prependPreRoll(segment.samples),
      );
      final processed = _tse.apply(rawWithPreRoll);
      if (TseApplier.isZeroed(processed)) {
        debugPrint('[VoiceListeningService] 音频已由 TSE 判定为非目标语音并静音，跳过 ASR 识别');
        continue;
      }
      final forAsr = _appendTailSilence(processed);
      if (!transcribe) {
        // 边说边传已经覆盖了这一段，这里只留一份音频，live 没接住时整段回退。
        _live.setVadSegment(forAsr);
        continue;
      }

      _isTranscribing = true;
      final isPlaying = isPlayingMode?.call() ?? false;
      try {
        final isStandby = isStandbyMode?.call() ?? true;
        if (!isPlaying) {
          onStateChanged?.call(true, '检测到声音，正在识别...');
        }
        debugPrint(
          '[VoiceListeningService] VAD 截取有效语音帧: raw=${segment.samples.length}, '
          'withPreRoll=${processed.length} (preRoll=${settings.preRollMs}ms, '
          'postRoll=${settings.postRollMs}ms), isStandby=$isStandby, isPlaying=$isPlaying',
        );
        final flushGen = _flushGeneration;
        final sw = Stopwatch()..start();
        final text = await asrService.transcribeSamples(
          forAsr,
          sampleRate: 16000,
          isStandbyWakeCheck: isMicTesting ? false : (isStandby || isPlaying),
          fromVad: true,
        );
        sw.stop();
        if (text.isNotEmpty &&
            flushGen == _flushGeneration &&
            !DateTime.now().isBefore(_suppressAudioUntil) &&
            !isEnrollingSpeaker) {
          _lastRecognizedAudio = processed;
          debugPrint('[VoiceListeningService] VAD 识别出文本: "$text"');
          onMicTestRecognized?.call(text, sw.elapsedMilliseconds);
          if (!isMicTesting) {
            onTextRecognized(text);
          }
        }
      } catch (e, st) {
        debugPrint('[VoiceListeningService] VAD 流识别异常: $e\n$st');
      } finally {
        _isTranscribing = false;
        if (_isListening && !(isPlayingMode?.call() ?? false)) {
          onStateChanged?.call(true, standbyHint);
        }
      }
    }
  }

  /// 播报期滚动短窗打断探针，见 `support/barge_in_probe.dart`。
  Future<void> _maybeProbePlayingBargeIn(int addedSamples) async {
    if (_disposed ||
        !_isListening ||
        asrService.isStreaming ||
        asrService.supportsLiveStreaming) {
      return;
    }
    await _bargeIn.probe(addedSamples);
  }

  /// 边说边传：VAD 一判定“正在说话”就开始推流，而不是等切完段。
  /// 具体状态机见 `support/live_utterance_session.dart`。
  void _pumpLiveAudio(Float32List samples) {
    final vad = _vad;
    if (vad == null || _disposed || !_isListening) return;
    _live.pump(
      samples,
      vadDetected: vad.isDetected(),
      preRollMs: settings.preRollMs,
      vadMinSpeechSeconds: settings.vadMinSpeechSeconds,
    );
  }

  /// 内置流式识别器的解码会话，见 `support/native_streaming_session.dart`。
  void _processStreamingSamples(Float32List samples) =>
      _streaming.accept(samples);

  /// 第二遍解码，实现见 `support/final_pass_runner.dart`。
  Future<void> _runFinalPass(Float32List audio) => _finalPass.run(audio);

  /// 启动（或重建）实时 PCM 流并挂上看门狗。
  Future<void> _startAudioStream() async {
    final device = activeInputDevice;
    debugPrint(
        '[VoiceListeningService] 启动音频采集，设备: ${device?.label ?? '自动（系统默认）'}');
    final stream = await _recorder.startStream(device: device);
    _usingStreamMode = true;
    _lastAudioChunkAt = DateTime.now();
    _recordStreamSub = stream.listen(
      _handlePcmChunk,
      onError: (Object e) {
        debugPrint('[VoiceListeningService] PCM 流监听发生错误: $e');
        _fallbackToChunkListening();
      },
    );
    _startAudioWatchdog();
  }

  void _handlePcmChunk(Uint8List pcmBytes) {
    // 看门狗用：只要还有包进来就说明采集链路活着（静音也会有包）。
    _lastAudioChunkAt = DateTime.now();
    if (!_isListening || _disposed) return;
    if (DateTime.now().isBefore(_suppressAudioUntil)) {
      _vad?.clear();
      _vad?.reset();
      resetStream();
      return;
    }
    final samples = PcmAudioUtils.pcm16ToFloat32(pcmBytes);
    if (samples.isEmpty) return;

    // 计算实时音量（RMS / dBFS）与 VAD 状态
    final audioLevel = PcmAudioUtils.measureLevel(samples);
    final vadNow =
        (_vad != null ? _vad!.isDetected() : false) || audioLevel.rms > 0.018;
    if (_micLevel.update(audioLevel, vadNow)) {
      onAudioLevelChanged?.call(audioLevel.level, audioLevel.dbfs, vadNow);
    }

    _appendAudioRing(samples);

    if (isEnrollingSpeaker) {
      // 正在录制/测试声纹样本中：音频仅被写入预卷环，不送入任何 ASR 解码器或 VAD 切段，杜绝识别与误唤醒
      return;
    }

    if (asrService.isStreaming) {
      _appendUtterance(samples);
      _processStreamingSamples(samples);
    } else {
      if (_vad == null) return;
      _vad!.acceptWaveform(samples);
      if (asrService.supportsLiveStreaming) {
        // 边说边传：说话期间就把音频推给云端，VAD 段只留作失败回退。
        _drainVadSegments(transcribe: false);
        _pumpLiveAudio(samples);
      } else {
        _drainVadSegments();
        unawaited(_maybeProbePlayingBargeIn(samples.length));
      }
    }
  }

  void _startAudioWatchdog() {
    _audioWatchdog?.cancel();
    _audioWatchdog = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_disposed || !_isListening || !_usingStreamMode) return;
      final last = _lastAudioChunkAt;
      if (last == null) return;
      if (DateTime.now().difference(last).inSeconds < 8) return;
      debugPrint('[VoiceListeningService] 音频流 8s 收不到任何数据，自动重启采集');
      unawaited(_restartAudioStream());
    });
  }

  /// 采集流卡死时自动重建（AudioRecord 被系统/OEM 静默停掉的兜底）。
  Future<void> _restartAudioStream() async {
    if (_disposed || !_isListening || _restartingAudio) return;
    _restartingAudio = true;
    _audioWatchdog?.cancel();
    _audioWatchdog = null;
    try {
      await _recordStreamSub?.cancel();
      _recordStreamSub = null;
      try {
        if (await _recorder.isRecording()) {
          await _recorder.stop();
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (_disposed || !_isListening) return;
      _lastAudioChunkAt = DateTime.now();
      // 蓝牙耳机可能在中途连上/断开，重建前重新按当前设备列表解析一次。
      await refreshInputDevice();
      await _startAudioStream();
      debugPrint('[VoiceListeningService] 音频采集已自动恢复');
    } catch (e, st) {
      debugPrint('[VoiceListeningService] 音频采集自动恢复失败: $e\n$st');
    } finally {
      _restartingAudio = false;
      if (!_disposed && _isListening && _usingStreamMode) {
        _startAudioWatchdog();
      }
    }
  }

  Future<void> _fallbackToChunkListening() async {
    _usingStreamMode = false;
    _audioWatchdog?.cancel();
    _audioWatchdog = null;
    await _recordStreamSub?.cancel();
    _recordStreamSub = null;
    if (_isListening && !_disposed) {
      _chunkRecorder ??= ChunkListeningRecorder(
        asrService: asrService,
        activeInputDevice: activeInputDevice,
        isListening: () => _isListening,
        isDisposed: () => _disposed,
        isEnrollingSpeaker: () => isEnrollingSpeaker,
        isStandbyMode: () => isStandbyMode?.call() ?? true,
        isInCooldown: () => DateTime.now().isBefore(_suppressAudioUntil),
        applyTse: _tse.apply,
        isTseZeroed: TseApplier.isZeroed,
        onStateChanged: onStateChanged,
        onTextRecognized: onTextRecognized,
      );
      _chunkRecorder!.start();
    }
  }

  /// 停止持续待机监听
  @override
  Future<void> stopContinuousListening() async {
    _loopTimer?.cancel();
    _loopTimer = null;
    _chunkRecorder?.stop();
    _audioWatchdog?.cancel();
    _audioWatchdog = null;
    _usingStreamMode = false;
    _lastAudioChunkAt = null;
    await _recordStreamSub?.cancel();
    _recordStreamSub = null;
    _vad?.clear();
    _vad?.reset();
    _resetUtteranceBuffer();
    _resetAudioRing();
    _live.discard();
    _isListening = false;
    _micLevel.reset();
    onAudioLevelChanged?.call(0.0, -60.0, false);
    if (settings.enableFloatingCapsule) {
      // 胶囊开启时保留前台服务，让最小化后的胶囊继续显示“话筒已关闭”。
      await ForegroundServiceBridge.setMicActive(
        false,
        capsuleEnabled: true,
        status: '待机',
      );
    } else {
      await ForegroundServiceBridge.stop();
    }

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}

    onStateChanged?.call(false, '话筒已静音');
  }

  /// 切换持续监听开关
  @override
  Future<bool> toggleContinuousListening() async {
    if (_isListening) {
      await stopContinuousListening();
      return false;
    } else {
      return await startContinuousListening();
    }
  }

  /// 开始手动单次录音（对讲模式），实现见 `support/manual_recording_session.dart`。
  @override
  Future<bool> startManualRecording() => _manualRecording.start();

  /// 停止手动单次录音并立即识别
  @override
  Future<String> stopManualRecording() => _manualRecording.stop();

  @override
  void dispose() {
    _disposed = true;
    isEnrollingSpeaker = false;
    _loopTimer?.cancel();
    _chunkRecorder?.dispose();
    _audioWatchdog?.cancel();
    _audioWatchdog = null;
    _recordStreamSub?.cancel();
    _recordStreamSub = null;
    _vad?.free();
    _vad = null;
    _streaming.free();
    ForegroundServiceBridge.stop();
    _recorder.dispose();
  }
}
