import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../core/platform/audio_recorder_bridge.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/storage_bridge.dart';
import 'asr_service.dart';
import 'audio_input_device_service.dart';
import 'audio_ring.dart';
import 'foreground_service_bridge.dart';

/// 定长环形音频缓冲已抽到 `audio_ring.dart`（[AudioRing]），便于单测与复用。
class VoiceListeningService {
  AsrService asrService;

  /// 两遍解码的第二遍：流式端点命中后，用内置 SenseVoice 对整段音频复检。
  AsrService? finalAsrService;

  final AppSettings settings;
  final void Function(String text) onTextRecognized;
  final void Function(String text)? onFinalTranscript;
  final void Function(String text)? onManualRecordingRecognized;
  final void Function(bool isListening, String statusHint)? onStateChanged;
  final void Function(double level, double dbfs, bool vadDetected)?
      onAudioLevelChanged;
  final void Function(String text, int durationMs)? onMicTestRecognized;
  final bool Function()? isStandbyMode;
  final bool Function()? isPlayingMode;

  bool isMicTesting = false;
  double _lastMicLevel = 0.0;
  double _lastMicDbfs = -60.0;
  bool _lastVadDetected = false;
  DateTime _lastLevelEmitAt = DateTime.fromMillisecondsSinceEpoch(0);

  double get micLevel => _lastMicLevel;
  double get micDbfs => _lastMicDbfs;
  bool get vadDetected => _lastVadDetected;

  final PlatformAudioRecorder _recorder = PlatformAudioRecorder();
  bool _isListening = false;
  bool _isManualRecording = false;
  bool _disposed = false;
  Timer? _loopTimer;

  /// 本次采集实际使用的录音设备（null = 自动/系统默认）。
  PlatformInputDevice? _activeInputDevice;

  sherpa_onnx.VoiceActivityDetector? _vad;
  sherpa_onnx.OnlineStream? _onlineStream;
  String _lastStreamText = '';
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
  static const int _audioRingCapacity = 35 * 16000;
  final AudioRing _audioRing = AudioRing(_audioRingCapacity);

  /// 实际创建 VAD 时使用的尾静音时长（引擎可能按自身特性微调）。
  /// 预卷偏移必须与它保持一致，否则会多补/少补一段音频。
  double _effectiveVadMinSilence = AppConstants.defaultVadMinSilenceSeconds;

  // ---- 两遍解码 ----
  final AudioRing _utteranceRing = AudioRing(_audioRingCapacity);
  bool _finalPassBusy = false;

  // ---- 边说边传（Gemini 等云端实时引擎） ----
  bool _liveActive = false;
  int _flushGeneration = 0;
  Future<void> _liveFinishQueue = Future<void>.value();

  /// 边说边传进行中时 VAD 弹出的那一段音频；live 失败时用它整段回退识别。
  Float32List? _lastVadSegmentAudio;

  // ---- 播报期滚动短窗打断探针（解决长语音外放不断、VAD 永不切段问题） ----
  /// 每次短窗探针截取最近 1.8 秒（28800 采样点 @ 16kHz）送检。
  static const int _bargeInWindowSamples = 28800;

  /// 每新流入 0.8 秒（12800 采样点）触发一次探针，前后两窗重叠 1.0 秒，
  /// 确保约 0.5 秒的“小曼”绝不会被卡在两个窗口接缝处截断。
  static const int _bargeInStepSamples = 12800;

  /// 音频环中至少攒够 0.8 秒才启动首次播报期探针。
  static const int _bargeInMinRingSamples = 12800;

  int _samplesSinceLastBargeInProbe = 0;
  bool _isProbingBargeIn = false;

  VoiceListeningService({
    required this.asrService,
    required this.settings,
    required this.onTextRecognized,
    this.finalAsrService,
    this.onFinalTranscript,
    this.onManualRecordingRecognized,
    this.onStateChanged,
    this.onAudioLevelChanged,
    this.onMicTestRecognized,
    this.isStandbyMode,
    this.isPlayingMode,
  });

  bool get isListening => _isListening;
  bool get isManualRecording => _isManualRecording;

  String get _hotwords {
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

  /// 运行期切换 ASR 实现（例如流式识别器初始化失败时降级到 SenseVoice）。
  ///
  /// 必须同步替换内部持有的引用，否则麦克风路径仍会调用已失效的识别器
  /// （流式实现 isStreaming 恒为 true 且拿不到 onlineStream），导致完全不识别。
  Future<void> setAsrService(AsrService next) async {
    if (identical(next, asrService)) return;
    final wasListening = _isListening;
    if (wasListening) {
      await stopContinuousListening();
    }
    _onlineStream?.free();
    _onlineStream = null;
    _vad?.free();
    _vad = null;
    _lastStreamText = '';
    _resetUtteranceBuffer();
    _resetAudioRing();
    _resetLiveState();
    asrService = next;
    if (wasListening) {
      await startContinuousListening();
    }
  }

  /// 检查当前是否处于播放结束/打断后的静音冷却保护期
  bool get isInCooldownWindow => DateTime.now().isBefore(_suppressAudioUntil);

  /// 重置当前流式识别器输入状态
  void resetStream() {
    if (_onlineStream != null && asrService.onlineRecognizer != null) {
      try {
        asrService.onlineRecognizer!.reset(_onlineStream!);
      } catch (_) {}
    }
    _lastStreamText = '';
    _resetUtteranceBuffer();
  }

  /// 清空两遍解码的整段音频缓冲
  void _resetUtteranceBuffer() {
    _utteranceRing.clear();
  }

  /// 清空预卷音频环
  void _resetAudioRing() {
    _audioRing.clear();
    _samplesSinceLastBargeInProbe = 0;
  }

  /// 清空“边说边传”的本地状态。
  ///
  /// 注意：不主动调用 `endLiveUtterance()`，由调用方决定是丢弃还是收尾。
  void _resetLiveState() {
    _liveActive = false;
    _lastVadSegmentAudio = null;
  }

  /// 重置/清空所有积压的音频切片与 VAD 缓冲区，并设立保护冷却窗（丢弃播放残余外放尾音，防回声误识别）
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
    if (_liveActive) {
      _liveActive = false;
      unawaited(asrService.endLiveUtterance());
    }
    _lastVadSegmentAudio = null;
    debugPrint(
        '[VoiceListeningService] 已清空音频与 VAD/流式缓冲，进入 ${cooldownMs}ms 冷却静音窗');
  }

  /// 检查麦克风权限
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  /// 本次采集实际使用的录音设备（null = 自动/系统默认）。
  PlatformInputDevice? get activeInputDevice => _activeInputDevice;

  /// 按设置解析要使用的录音设备，并缓存到 [_activeInputDevice]。
  ///
  /// - 设置为空 → null，交给系统自动选择（兼容性最好，推荐默认）。
  /// - 设备已断开（蓝牙耳机摘掉、换机后 id 变化）→ 回退自动，
  ///   避免把一个不存在的设备塞给 AudioRecord 导致录音直接失败。
  Future<void> refreshInputDevice() async {
    final id = settings.audioInputDeviceId.trim();
    if (id.isEmpty) {
      _activeInputDevice = null;
      return;
    }
    final options = await AudioInputDeviceService.listInputDevices();
    for (final option in options) {
      if (option.id == id) {
        _activeInputDevice =
            PlatformInputDevice(id: option.id, label: option.label);
        return;
      }
    }
    debugPrint('[VoiceListeningService] 设置的录音设备不可用 (id=$id)，回退系统默认');
    _activeInputDevice = null;
  }

  /// 供 UI / 调试用的设备描述。
  String get activeInputDeviceLabel => _activeInputDevice?.label ?? '自动（系统默认）';

  /// 设置里的录音设备变化后立即生效。
  ///
  /// 只重建音频采集链路，不重建 ASR 服务：模型与云端连接保持不动，
  /// 比整轮 `_initServices()` 快得多，也不会打断正在识别的内容。
  /// 话筒未开启时只更新缓存，下次开启采集时自然生效。
  Future<void> applyInputDeviceChange() async {
    if (_disposed || _isManualRecording) return;
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
      content: '低功耗待机中，可随时说“晓漫”唤醒',
      micListening: true,
      capsuleEnabled: settings.enableFloatingCapsule,
      status: '待机',
    );
    onStateChanged?.call(true, '话筒监听中（可随时说“晓漫”唤醒）');

    bool streamStarted = false;
    try {
      if (asrService.isStreaming) {
        _onlineStream ??= asrService.createOnlineStream(hotwords: _hotwords);
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
      _startNextChunk();
    }
    return true;
  }

  /// 把新到的 PCM 追加到预卷环，保留最近 35 秒。
  void _appendAudioRing(Float32List samples) {
    _audioRing.add(samples);
  }

  /// 从预卷环中截取 VAD 段之前的 [settings.preRollMs] 毫秒音频。
  ///
  /// VAD 在检测到 [minSilenceDuration] 的尾静音后才输出段，因此：
  ///   段尾 ≈ 环尾 - minSilenceDuration
  ///   段首 ≈ 段尾 - segment.length
  /// 再往前取 preRollMs 即为需要补回的预卷。
  Float32List _prependPreRoll(Float32List segment) {
    final preRollSamples = (settings.preRollMs * 16).clamp(0, 16000);
    if (preRollSamples <= 0 || _audioRing.length <= 0) return segment;

    // 达到 maxSpeechDuration 被强制切段的，尾部没有尾静音，反推段首会错位；
    // 这种情况下不补预卷，避免把段内音频重复送进模型。
    if (segment.length >= settings.vadMaxSpeechSeconds * 16000 * 0.95) {
      return segment;
    }

    final silenceSamples = (_effectiveVadMinSilence * 16000).round();
    final segmentEnd = _audioRing.length - silenceSamples;
    final segmentStart = segmentEnd - segment.length;
    if (segmentStart <= 0) return segment;

    final start = math.max(0, segmentStart - preRollSamples);
    if (start >= segmentStart) return segment;

    final pre = _audioRing.slice(start, segmentStart);
    final out = Float32List(pre.length + segment.length);
    out.setRange(0, pre.length, pre);
    out.setRange(pre.length, out.length, segment);
    return out;
  }

  /// 在段尾补一小段静音，帮助 CTC/注意力模型收尾。
  Float32List _appendTailSilence(Float32List segment) {
    final tailSamples = (settings.postRollMs * 16).clamp(0, 16000);
    if (tailSamples <= 0) return segment;
    final out = Float32List(segment.length + tailSamples);
    out.setRange(0, segment.length, segment);
    return out;
  }

  /// 追加到两遍解码的整段音频缓冲（最多 35 秒）。
  void _appendUtterance(Float32List samples) {
    _utteranceRing.add(samples);
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
      _samplesSinceLastBargeInProbe = 0;
      if (segment.samples.isEmpty) continue;

      final processed = _appendTailSilence(_prependPreRoll(segment.samples));
      if (!transcribe) {
        // 边说边传已经覆盖了这一段，这里只留一份音频，live 没接住时整段回退。
        _lastVadSegmentAudio = processed;
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
          processed,
          sampleRate: 16000,
          isStandbyWakeCheck: isMicTesting ? false : (isStandby || isPlaying),
          fromVad: true,
        );
        sw.stop();
        if (text.isNotEmpty &&
            flushGen == _flushGeneration &&
            !DateTime.now().isBefore(_suppressAudioUntil)) {
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
          onStateChanged?.call(true, '话筒监听中（可随时说“${settings.startWord}”唤醒）');
        }
      }
    }
  }

  /// 播报期滚动短窗打断探针：
  /// 当助手正在外放长段消息时，扬声器声音持续进入麦克风，导致 VAD 无法凑够 0.5s 尾静音而一直不切段。
  /// 此处每累积 0.8s 音频且 VAD 未自然切段时，从音频环截取最近 1.8s 窗口（前后窗重叠 1.0s）送检，
  /// 确保用户随时喊“小曼”都能在 <1s 内被识别并打断播报。
  Future<void> _maybeProbePlayingBargeIn(int addedSamples) async {
    if (_disposed || !_isListening || asrService.isStreaming || asrService.supportsLiveStreaming) {
      return;
    }
    if (!(isPlayingMode?.call() ?? false)) {
      _samplesSinceLastBargeInProbe = 0;
      return;
    }
    if (DateTime.now().isBefore(_suppressAudioUntil)) {
      _samplesSinceLastBargeInProbe = 0;
      return;
    }

    _samplesSinceLastBargeInProbe += addedSamples;
    if (_samplesSinceLastBargeInProbe < _bargeInStepSamples) return;
    if (_audioRing.length < _bargeInMinRingSamples) return;
    if (_isTranscribing || _isProbingBargeIn) return;

    _samplesSinceLastBargeInProbe = 0;
    final windowLen = math.min(_audioRing.length, _bargeInWindowSamples);
    final start = _audioRing.length - windowLen;
    final slice = _audioRing.slice(start, _audioRing.length);
    if (slice.isEmpty || isNearSilence(slice)) return;

    _isProbingBargeIn = true;
    try {
      final processed = _appendTailSilence(slice);
      final text = await asrService.transcribeSamples(
        processed,
        sampleRate: 16000,
        isStandbyWakeCheck: true,
        fromVad: true,
      );
      if (text.isNotEmpty &&
          !DateTime.now().isBefore(_suppressAudioUntil) &&
          (isPlayingMode?.call() ?? false)) {
        debugPrint(
          '[VoiceListeningService] 播报期短窗探针 (${slice.length ~/ 16}ms) 识别出文本: "$text"',
        );
        onTextRecognized(text);
      }
    } catch (e, st) {
      debugPrint('[VoiceListeningService] 播报期短窗探针异常: $e\n$st');
    } finally {
      _isProbingBargeIn = false;
    }
  }

  /// 边说边传：VAD 一判定“正在说话”就开始推流，而不是等切完段。
  void _pumpLiveAudio(Float32List samples) {
    final vad = _vad;
    if (vad == null || _disposed || !_isListening) return;

    final detected = vad.isDetected();
    if (detected) {
      if (!_liveActive) {
        _liveActive = true;
        _lastVadSegmentAudio = null;
        // VAD 要累积 minSpeechDuration 才置位，真正开口在更早；从预卷环里把
        // “预卷 + 已说出的部分”一次性补齐，避免句首被 VAD 的判定延迟削掉。
        final backfillMs = settings.preRollMs +
            (settings.vadMinSpeechSeconds * 1000).round() +
            120;
        final backfillSamples = math.min(_audioRing.length, backfillMs * 16);
        final start = _audioRing.length - backfillSamples;
        final backfill = _audioRing.slice(start, _audioRing.length);
        final isPlaying = isPlayingMode?.call() ?? false;
        final isStandby = isStandbyMode?.call() ?? true;
        if (!isPlaying) {
          onStateChanged?.call(true, '检测到声音，正在识别...');
        }
        // 播报期间必须将 isStandbyWakeCheck 设为 false 以开启云端实时中间结果 (onPartialText)，
        // 从而无需等待外放静音即可实时探测“小曼”打断词。
        asrService.beginLiveUtterance(
          backfill,
          isStandbyWakeCheck: isStandby && !isPlaying,
        );
      } else {
        asrService.appendLiveAudio(samples);
      }
      return;
    }

    if (_liveActive) {
      // 触发“结束”的最后一个静音块也要送进去，保证模型听到完整尾音。
      asrService.appendLiveAudio(samples);
      _liveActive = false;
      final fallback = _lastVadSegmentAudio;
      _lastVadSegmentAudio = null;
      final isStandby = isStandbyMode?.call() ?? true;
      final flushGen = _flushGeneration;
      _liveFinishQueue = _liveFinishQueue.then(
        (_) => _finishLiveUtterance(
          fallbackAudio: fallback,
          isStandby: isStandby,
          flushGen: flushGen,
        ),
        onError: (Object _, StackTrace __) {},
      );
    }
  }

  Future<void> _finishLiveUtterance({
    required Float32List? fallbackAudio,
    required bool isStandby,
    required int flushGen,
  }) async {
    final started = DateTime.now();
    try {
      final text = await asrService.endLiveUtterance();
      debugPrint(
        '[VoiceListeningService] 边说边传收尾耗时 '
        '${DateTime.now().difference(started).inMilliseconds}ms',
      );
      if (flushGen != _flushGeneration) {
        if (text != null && text.isNotEmpty) {
          debugPrint('[VoiceListeningService] 已丢弃跨越缓冲清空的陈旧语音片段: "$text"');
        }
        return;
      }
      if (text != null) {
        // 非空 = 云端给出了最终文本；空串 = 识别到了但不可用（非中文），直接丢弃。
        if (text.isNotEmpty && !DateTime.now().isBefore(_suppressAudioUntil)) {
          debugPrint('[VoiceListeningService] 边说边传识别出文本: "$text"');
          onMicTestRecognized?.call(
            text,
            DateTime.now().difference(started).inMilliseconds,
          );
          if (!isMicTesting) {
            onTextRecognized(text);
          }
        }
        return;
      }

      // 云端没接住（连接失败/超时）：用刚才 VAD 弹出的整段音频回退识别。
      if (fallbackAudio == null || fallbackAudio.isEmpty) return;
      if (flushGen != _flushGeneration) return;
      debugPrint('[VoiceListeningService] 边说边传未返回结果，回退整段识别');
      final fallbackText = await asrService.transcribeSamples(
        fallbackAudio,
        sampleRate: 16000,
        isStandbyWakeCheck: isMicTesting ? false : isStandby,
        fromVad: true,
      );
      if (fallbackText.isNotEmpty &&
          flushGen == _flushGeneration &&
          !DateTime.now().isBefore(_suppressAudioUntil)) {
        onMicTestRecognized?.call(
          fallbackText,
          DateTime.now().difference(started).inMilliseconds,
        );
        if (!isMicTesting) {
          onTextRecognized(fallbackText);
        }
      }
    } catch (e, st) {
      debugPrint('[VoiceListeningService] 边说边传收尾异常: $e\n$st');
    } finally {
      if (_isListening && !_liveActive) {
        onStateChanged?.call(true, '话筒监听中（可随时说“${settings.startWord}”唤醒）');
      }
    }
  }

  void _processStreamingSamples(Float32List samples) {
    if (_onlineStream == null) {
      _onlineStream = asrService.createOnlineStream(hotwords: _hotwords);
      if (_onlineStream == null) return;
    }

    final recognizer = asrService.onlineRecognizer;
    if (recognizer == null) return;

    _onlineStream!.acceptWaveform(samples: samples, sampleRate: 16000);

    while (recognizer.isReady(_onlineStream!)) {
      recognizer.decode(_onlineStream!);
    }

    final result = recognizer.getResult(_onlineStream!);
    final rawText = result.text.trim();
    final isPlaying = isPlayingMode?.call() ?? false;
    final isStandby = isStandbyMode?.call() ?? true;
    final text = rawText.isEmpty
        ? ''
        : postProcessAsrText(
            rawText,
            wakeContext: isMicTesting ? false : (isStandby || isPlaying),
          );

    if (text.isNotEmpty &&
        text != _lastStreamText &&
        !DateTime.now().isBefore(_suppressAudioUntil)) {
      _lastStreamText = text;
      debugPrint('[VoiceListeningService] 原生流式实时识别: "$text"');
      onMicTestRecognized?.call(text, 0);
      if (!isMicTesting) {
        onTextRecognized(text);
      }
    }

    // 播报长语音期间扬声器无长静音，流式解码器可能迟迟不命中 isEndpoint；
    // 当单段累积超过 36 字且尚未打断时主动滚动重置，并回填最近 0.6s 重叠音频，
    // 防止流式束搜索因长回声退化，同时保证跨重置边界的“小曼”不被切断。
    if (isPlaying &&
        _onlineStream != null &&
        rawText.length >= 36 &&
        !recognizer.isEndpoint(_onlineStream!)) {
      final overlapLen = math.min(_utteranceRing.length, 9600);
      final overlap = overlapLen > 0
          ? _utteranceRing.slice(
              _utteranceRing.length - overlapLen,
              _utteranceRing.length,
            )
          : Float32List(0);
      resetStream();
      if (overlap.isNotEmpty && _onlineStream != null) {
        _utteranceRing.add(overlap);
        _onlineStream!.acceptWaveform(samples: overlap, sampleRate: 16000);
      }
      return;
    }

    if (recognizer.isEndpoint(_onlineStream!)) {
      debugPrint('[VoiceListeningService] 流式 ASR 命中端点断句 (isEndpoint): "$text"');
      // 两遍解码：端点命中后，把整段音频交给内置 SenseVoice 复检。
      final finalAudio = _utteranceRing.length >= 16000 * 0.2
          ? _utteranceRing.snapshot()
          : Float32List(0);
      // 无论是否识别出文字都必须复位，否则识别器会停留在端点状态导致后续音频错位。
      resetStream();
      if (finalAudio.isNotEmpty) {
        unawaited(_runFinalPass(finalAudio));
      }
    }
  }

  /// 第二遍解码：流式负责“快”，内置 SenseVoice 负责“准”。
  ///
  /// 只会在倾听态使用；控制器侧还会再次校验状态，避免在思考/播放阶段误触发。
  Future<void> _runFinalPass(Float32List audio) async {
    final finalAsr = finalAsrService;
    if (finalAsr == null || !finalAsr.isReady) return;
    if (_finalPassBusy) return;
    if (audio.length < 16000 * 0.2) return;

    _finalPassBusy = true;
    final sw = Stopwatch()..start();
    try {
      final text = await finalAsr.transcribeSamples(
        audio,
        sampleRate: 16000,
        fromVad: true,
      );
      sw.stop();
      if (text.isNotEmpty) {
        debugPrint(
          '[VoiceListeningService] 两遍解码复检完成 (${finalAsr.engineName}, '
          '${audio.length ~/ 16}ms, 耗时 ${sw.elapsedMilliseconds}ms): "$text"',
        );
        onFinalTranscript?.call(text);
      }
    } catch (e, st) {
      debugPrint('[VoiceListeningService] 两遍解码异常: $e\n$st');
    } finally {
      _finalPassBusy = false;
    }
  }

  static Float32List _pcm16ToFloat32(Uint8List bytes) {
    final numSamples = bytes.length ~/ 2;
    if (numSamples == 0) return Float32List(0);
    final byteData = ByteData.sublistView(bytes);
    final floatList = Float32List(numSamples);
    for (int i = 0; i < numSamples; i++) {
      final sample = byteData.getInt16(i * 2, Endian.little);
      floatList[i] = sample / 32768.0;
    }
    return floatList;
  }

  /// 启动（或重建）实时 PCM 流并挂上看门狗。
  Future<void> _startAudioStream() async {
    final device = _activeInputDevice;
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
    final samples = _pcm16ToFloat32(pcmBytes);
    if (samples.isEmpty) return;

    // 计算实时音量（RMS / dBFS）与 VAD 状态
    double sumSq = 0.0;
    for (int i = 0; i < samples.length; i++) {
      final s = samples[i];
      sumSq += s * s;
    }
    final rms = math.sqrt(sumSq / samples.length);
    final dbfs =
        (20.0 * math.log(math.max(rms, 1e-5)) / math.ln10).clamp(-60.0, 0.0);
    final level = ((dbfs + 55.0) / 50.0).clamp(0.0, 1.0);
    final vadNow = (_vad != null ? _vad!.isDetected() : false) || rms > 0.018;
    final now = DateTime.now();
    final vadChanged = vadNow != _lastVadDetected;
    _lastMicLevel = level;
    _lastMicDbfs = dbfs;
    _lastVadDetected = vadNow;
    if (vadChanged ||
        now.difference(_lastLevelEmitAt).inMilliseconds >= 90) {
      _lastLevelEmitAt = now;
      onAudioLevelChanged?.call(level, dbfs, vadNow);
    }

    if (asrService.isStreaming) {
      _appendUtterance(samples);
      _processStreamingSamples(samples);
    } else {
      if (_vad == null) return;
      _appendAudioRing(samples);
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
      _startNextChunk();
    }
  }

  /// 停止持续待机监听
  Future<void> stopContinuousListening() async {
    _loopTimer?.cancel();
    _loopTimer = null;
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
    if (_liveActive) {
      _liveActive = false;
      unawaited(asrService.endLiveUtterance());
    }
    _resetLiveState();
    _isListening = false;
    _lastMicLevel = 0.0;
    _lastMicDbfs = -60.0;
    _lastVadDetected = false;
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
  Future<bool> toggleContinuousListening() async {
    if (_isListening) {
      await stopContinuousListening();
      return false;
    } else {
      return await startContinuousListening();
    }
  }

  /// 开始手动单次录音（对讲模式）
  Future<bool> startManualRecording() async {
    if (_isListening) {
      await stopContinuousListening();
    }
    final permitted = await hasPermission();
    if (!permitted) return false;

    await refreshInputDevice();

    final tempDir = await StorageBridge.getAppTemporaryDirectory();
    final manualPath =
        '${tempDir.path}/manual_voice_${DateTime.now().millisecondsSinceEpoch}.wav';

    try {
      await _recorder.startWavFile(
        path: manualPath,
        device: _activeInputDevice,
      );
      _isManualRecording = true;
      onStateChanged?.call(true, '正在录音...松开或点击发送');
      return true;
    } catch (e) {
      _isManualRecording = false;
      return false;
    }
  }

  /// 停止手动单次录音并立即识别
  Future<String> stopManualRecording() async {
    if (!_isManualRecording) return '';
    _isManualRecording = false;

    try {
      final path = await _recorder.stop();
      if (path != null && File(path).existsSync()) {
        onStateChanged?.call(false, '正在本地离线识别...');
        final recognizedText = await asrService.transcribeAudioFile(path,
            isStandbyWakeCheck: false);
        try {
          File(path).deleteSync();
        } catch (_) {}

        if (recognizedText.isNotEmpty) {
          if (onManualRecordingRecognized != null) {
            onManualRecordingRecognized!(recognizedText);
          } else {
            onTextRecognized(recognizedText);
          }
        }
        onStateChanged?.call(false, '识别完成');
        return recognizedText;
      }
    } catch (_) {}

    onStateChanged?.call(false, '已取消录音');
    return '';
  }

  void _startNextChunk() async {
    if (!_isListening || _disposed) return;

    try {
      final tempDir = await StorageBridge.getAppTemporaryDirectory();
      final chunkFile =
          '${tempDir.path}/mic_chunk_${DateTime.now().millisecondsSinceEpoch}.wav';

      await _recorder.startWavFile(
        path: chunkFile,
        device: _activeInputDevice,
      );

      bool hasSpeechActivity = false;
      bool amplitudeFailedOrUnsupported = false;

      final ampTimer =
          Timer.periodic(const Duration(milliseconds: 200), (_) async {
        try {
          final amp = await _recorder.getAmplitude();
          if (amp.current > -58.0 || amp.max > -58.0) {
            hasSpeechActivity = true;
          }
        } catch (_) {
          amplitudeFailedOrUnsupported = true;
        }
      });

      // 降级模式：录制 1200ms 短音频切片（避免过大延迟）
      _loopTimer = Timer(const Duration(milliseconds: 1200), () async {
        ampTimer.cancel();
        if (!_isListening || _disposed) return;

        try {
          final stoppedPath = await _recorder.stop();
          // 无缝启动下一个切片
          _startNextChunk();

          if (DateTime.now().isBefore(_suppressAudioUntil)) {
            // 处于静音保护窗内，直接丢弃该切片
            if (stoppedPath != null && File(stoppedPath).existsSync()) {
              try {
                File(stoppedPath).deleteSync();
              } catch (_) {}
            }
            return;
          }

          final shouldTranscribe =
              hasSpeechActivity || amplitudeFailedOrUnsupported;

          if (shouldTranscribe &&
              stoppedPath != null &&
              File(stoppedPath).existsSync()) {
            final isStandby = isStandbyMode?.call() ?? true;
            debugPrint(
                '[VoiceListeningService] 切片录制就绪，送检 ASR: $stoppedPath (isStandby=$isStandby)');
            onStateChanged?.call(true, '检测到声音，正在识别...');

            try {
              final wave = sherpa_onnx.readWave(stoppedPath);
              final text = wave.samples.isEmpty
                  ? ''
                  : await asrService.transcribeSamples(
                      wave.samples,
                      sampleRate: wave.sampleRate,
                      isStandbyWakeCheck: isStandby,
                      fromVad: true,
                    );
              if (text.isNotEmpty) {
                debugPrint('[VoiceListeningService] 识别到有效文字: "$text"');
                onTextRecognized(text);
              }
            } finally {
              try {
                if (File(stoppedPath).existsSync()) {
                  File(stoppedPath).deleteSync();
                }
              } catch (_) {}
            }
          } else if (stoppedPath != null && File(stoppedPath).existsSync()) {
            // 纯静音切片直接清除，0 神经网络开销
            try {
              File(stoppedPath).deleteSync();
            } catch (_) {}
          }
        } catch (e, st) {
          debugPrint('[VoiceListeningService] 切片处理异常: $e\n$st');
          if (_isListening) {
            _startNextChunk();
          }
        }
      });
    } catch (e, st) {
      debugPrint('[VoiceListeningService] 启动录音切片失败: $e\n$st');
      _loopTimer = Timer(const Duration(seconds: 1), _startNextChunk);
    }
  }

  void dispose() {
    _disposed = true;
    _loopTimer?.cancel();
    _audioWatchdog?.cancel();
    _audioWatchdog = null;
    _recordStreamSub?.cancel();
    _recordStreamSub = null;
    _vad?.free();
    _vad = null;
    _onlineStream?.free();
    _onlineStream = null;
    ForegroundServiceBridge.stop();
    _recorder.dispose();
  }
}
