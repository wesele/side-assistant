import 'dart:async';
import 'package:uuid/uuid.dart';
import '../core/constants/app_constants.dart';
import '../core/models/app_settings.dart';
import '../core/models/chat_message.dart';
import '../core/models/chat_session.dart';
import '../core/platform/foundation_bridge.dart';
import '../services/llm/llm_service.dart';
import '../services/lightrag/lightrag_service.dart';
import '../services/linux/linux_hardware_service.dart';
import '../services/storage/chat_history_service.dart';
import '../services/nlp/embedding_service.dart';
import '../services/nlp/trigger_matcher.dart';
import '../services/nlp/vector_math.dart';
import '../services/speech/asr_service.dart';
import '../services/speech/audio_input_device_service.dart';
import '../services/speech/gemini_live_asr_service.dart';
import '../services/speech/prompt_sound_service.dart';
import '../services/speech/tts_service.dart';
import '../services/speech/transcript_processor.dart';
import '../services/speech/voice_listening_service.dart';
import '../services/speech/foreground_service_bridge.dart';
import '../services/automation/app_driver_server.dart';
import '../services/automation/diagnostic_self_test_runner.dart';
import '../services/system/floating_capsule_service.dart';
import '../services/vision/vision_intent_service.dart';
import '../services/vision/camera_service.dart';

enum AssistantStatus {
  idle, // 低功耗待机中（监听开始词/新会话词）
  listeningContent, // 已唤醒，正在倾听用户指令（等待结束词）
  thinking, // 正在请求大模型思考
  playing, // 正在朗读回复（支持随时打断）
}

class AssistantController extends ChangeNotifier {
  AppSettings settings;
  late EmbeddingService _embeddingService;
  late TriggerMatcher _triggerMatcher;
  late LlmService _llmService;
  LightRagService? _lightRagService;
  Timer? _lightRagIdleTimer;
  late TtsService _ttsService;
  late AsrService _asrService;
  AsrService? _finalAsrService;
  late VoiceListeningService _voiceListeningService;
  late PromptSoundService _promptSoundService;
  late VisionIntentService _visionIntentService;
  CameraService? _cameraService;
  int _acknowledgeBeepCount = 0;
  bool _servicesInitialized = false;
  bool _disposed = false;
  int _servicesGeneration = 0;

  AssistantStatus _status = AssistantStatus.idle;
  String _currentSessionId = const Uuid().v4();
  final List<ChatMessage> _messages = [];
  final List<ChatSession> _sessions = [];
  late final ChatHistoryService _chatHistoryService;

  String _liveTranscript = '';
  String _lastRecognizedSpeech = '';
  String _currentSpeakingReply = '';
  bool _isWakeWordMatched = false;
  Timer? _unmatchedSpeechTimer;
  String _statusHint = '话筒未开启，点击右上角开启语音监听';
  Timer? _silenceTimer;
  Future<void> _textProcessQueue = Future<void>.value();

  AssistantController({
    required this.settings,
    bool enableDriverServer = true,
    ChatHistoryService? chatHistoryService,
  }) {
    _chatHistoryService = chatHistoryService ?? ChatHistoryService();
    _initServices(enableDriverServer: enableDriverServer);
    unawaited(loadChatHistory());
  }

  bool _isSelfTesting = false;
  final List<String> _selfTestLogs = [];
  AppDriverServer? _driverServer;

  bool _isMicTesting = false;
  String _micTestText = '';
  final List<Map<String, dynamic>> _micTestHistory = [];

  AssistantStatus get status => _status;
  List<ChatMessage> get messages => List.unmodifiable(_messages);
  List<ChatSession> get sessions => List.unmodifiable(_sessions);
  ChatHistoryService get chatHistoryService => _chatHistoryService;
  String get liveTranscript => _liveTranscript;
  String get lastRecognizedSpeech => _lastRecognizedSpeech;
  bool get isWakeWordMatched => _isWakeWordMatched;
  double get micLevel => _voiceListeningService.micLevel;
  double get micDbfs => _voiceListeningService.micDbfs;
  bool get vadDetected => _voiceListeningService.vadDetected;
  bool get isMicTesting => _isMicTesting;
  String get micTestText => _micTestText;
  List<Map<String, dynamic>> get micTestHistory =>
      List.unmodifiable(_micTestHistory);
  String get displayTranscript =>
      _status == AssistantStatus.listeningContent && _liveTranscript.isNotEmpty
          ? _liveTranscript
          : _lastRecognizedSpeech;
  String get statusHint {
    if (_status == AssistantStatus.idle &&
        !_voiceListeningService.isListening) {
      if (_statusHint.contains('唤醒') || _statusHint.contains('呼唤')) {
        return '话筒未开启，点击右上角开启语音监听';
      }
    }
    return _statusHint;
  }

  String get currentSessionId => _currentSessionId;
  AsrService get asrService => _asrService;
  TtsService get ttsService => _ttsService;
  VoiceListeningService get voiceService => _voiceListeningService;
  bool get isMicListening => _voiceListeningService.isListening;
  bool get isManualRecording => _voiceListeningService.isManualRecording;
  bool get isSelfTesting => _isSelfTesting;
  List<String> get selfTestLogs => List.unmodifiable(_selfTestLogs);
  VisionIntentService get visionIntentService => _visionIntentService;

  void _setupCameraService() {
    if (_cameraService != null) {
      _cameraService!.updateSettings(settings);
      return;
    }
    _cameraService = CameraService(settings: settings);
    _cameraService!.nanoSource.bleDriver.onBatteryUpdate = (percent, charging) {
      notifyListeners();
    };
    _cameraService!.nanoSource.onCaptureStateChanged = (_) {
      notifyListeners();
    };
  }

  CameraService get cameraService {
    if (_cameraService == null) {
      _setupCameraService();
    }
    return _cameraService!;
  }

  bool _isNanoConnecting = false;
  bool _isQuickCapturing = false;
  String _lastFloatingStatus = '';
  bool? _lastFloatingMic;

  bool get isCameraOpen => _cameraService?.isCameraOpen ?? false;
  bool get isNanoConnected => _cameraService?.nanoSource.isOpen ?? false;
  bool get isNanoConnecting =>
      _isNanoConnecting || (_cameraService?.nanoSource.isConnecting ?? false);
  bool get isNanoCameraMode =>
      settings.captureSource == AppConstants.captureSourceNano;
  int get nanoBatteryPercent => _cameraService?.nanoSource.batteryPercent ?? -1;
  bool get isNanoCharging => _cameraService?.nanoSource.isCharging ?? false;
  bool get isNanoCapturing => _cameraService?.nanoSource.isCapturing ?? false;

  /// 一键抓拍进行中（含相机连接/唤醒与快门触发阶段）
  bool get isQuickCapturing =>
      _isQuickCapturing || isNanoConnecting || isNanoCapturing;

  /// 一键抓拍并追问大模型「这是什么，介绍一下」。
  ///
  /// 拍照源按设置 [AppSettings.captureSource] 路由：本地镜头或 DJI Osmo Nano。
  Future<void> captureAndAskAboutScene({
    String question = '这是什么，介绍一下',
  }) async {
    if (_isQuickCapturing) {
      debugPrint('[AssistantController] 正在抓拍中，忽略重复点击');
      return;
    }

    _isQuickCapturing = true;
    notifyListeners();

    try {
      // 若正在朗读，先停止，避免与抓拍/提问冲突
      await _ttsService.stop();
      _voiceListeningService.flushBuffers(cooldownMs: 300);
      _setStatus(AssistantStatus.thinking, '正在抓拍画面...');
      unawaited(_promptSoundService.playShutterSound());

      final captureResult = await cameraService.capturePhoto();
      if (captureResult.imageBytes.isEmpty) {
        throw Exception('未获取到有效画面');
      }

      _isQuickCapturing = false;
      notifyListeners();

      await _submitToLlm(
        question,
        preCapturedImageBytes: captureResult.imageBytes,
        preCapturedImagePath: captureResult.filePath,
      );
    } catch (e) {
      debugPrint('[AssistantController] 一键抓拍失败: $e');
      _isQuickCapturing = false;
      notifyListeners();
      _setStatus(AssistantStatus.idle, '抓拍失败：$e');
      try {
        await _ttsService.speakImmediate('抓拍失败，请检查相机连接');
      } catch (_) {}
    } finally {
      _isQuickCapturing = false;
    }
  }

  /// 悬浮胶囊右侧显示的工作状态，最多两个汉字。
  ///
  /// 左侧图标单独表达话筒是否在监听，因此这里只保留状态短标签：
  /// 待机 / 倾听 / 思考 / 播报 / 失败。
  String get floatingCapsuleStatusLabel {
    switch (_status) {
      case AssistantStatus.idle:
        if (_statusHint.contains('失败') ||
            _statusHint.contains('未成功') ||
            _statusHint.contains('异常')) {
          return '失败';
        }
        return '待机';
      case AssistantStatus.listeningContent:
        return '倾听';
      case AssistantStatus.thinking:
        return '思考';
      case AssistantStatus.playing:
        return '播报';
    }
  }

  /// 把状态与话筒开关同步到 Android 悬浮胶囊。
  ///
  /// 仅在值变化时发通道调用，避免每帧 notify 都跨平台通信。
  Future<void> _syncFloatingCapsule({bool force = false}) async {
    if (_disposed || !FloatingCapsuleService.isSupported) return;

    final status = floatingCapsuleStatusLabel;
    final mic = _voiceListeningService.isListening;
    if (!force && status == _lastFloatingStatus && mic == _lastFloatingMic) {
      return;
    }
    _lastFloatingStatus = status;
    _lastFloatingMic = mic;

    await FloatingCapsuleService.update(
      status: status,
      micListening: mic,
      enabled: settings.enableFloatingCapsule,
    );
  }

  Future<void> toggleNanoConnection() async {
    if (_isNanoConnecting) {
      debugPrint('[AssistantController] Nano 正在连接中，忽略重复点击');
      return;
    }
    _isNanoConnecting = true;
    notifyListeners();

    final nano = cameraService.nanoSource;
    try {
      if (settings.captureSource != AppConstants.captureSourceNano) {
        // 1. 如果不是 nano 相机模式，切换到 nano 相机模式并保存设置
        settings.captureSource = AppConstants.captureSourceNano;
        await settings.save();
        _cameraService?.updateSettings(settings);
        // 2. 连接到蓝牙
        if (!nano.isOpen) {
          await nano.ensureOpen();
        }
      } else {
        // 如果已经是 nano 相机模式，则根据当前蓝牙状态切换（断开 / 连接）
        if (nano.isOpen) {
          await nano.close();
        } else {
          await nano.ensureOpen();
        }
      }
    } catch (e) {
      debugPrint('[AssistantController] 切换 Nano 蓝牙连接状态异常: $e');
    } finally {
      _isNanoConnecting = false;
      notifyListeners();
    }
  }

  Future<void> toggleMicListening() async {
    await _voiceListeningService.toggleContinuousListening();
    notifyListeners();
    await _syncFloatingCapsule(force: true);
  }

  Future<void> startManualRecording() async {
    // 若当前正在播报回复，点击语音输入时立即停止 TTS 播放，
    // 并将状态切回待机，避免后续句子继续入队或扬声器声音被录进麦克风。
    if (_status == AssistantStatus.playing) {
      _setStatus(AssistantStatus.idle, '已停止朗读，准备录音...');
    }
    await _ttsService.stop();
    await _voiceListeningService.startManualRecording();
    notifyListeners();
  }

  Future<void> stopManualRecording() async {
    await _voiceListeningService.stopManualRecording();
    notifyListeners();
  }

  // ---- 录音输入设备（Android） ----

  /// 当前实际生效的录音设备名（'自动（系统默认）' 或具体设备）。
  /// 仅在话筒启动/重启采集后被刷新。
  String get activeAudioInputDeviceLabel =>
      _voiceListeningService.activeInputDeviceLabel;

  /// 枚举可用录音输入设备；非 Android 平台返回空列表。
  Future<List<AudioInputDeviceOption>> listAudioInputDevices() {
    return AudioInputDeviceService.listInputDevices();
  }

  /// 切换录音设备（写回设置并立即切换采集设备）。
  ///
  /// 刻意只重建音频采集链路，不走 [_initServices]：后者会重建识别器、
  /// 重载模型并重启调试服务，对“换个麦克风”来说代价过大。
  Future<void> setAudioInputDevice(String id, String label) async {
    settings.audioInputDeviceId = id;
    settings.audioInputDeviceLabel = label;
    await settings.save();
    await _voiceListeningService.applyInputDeviceChange();
    notifyListeners();
  }

  /// 设置服务器扬声器播放音量百分比（0 - 150），立即应用到系统混音器与播放链路
  Future<void> setPlaybackVolume(int volumePercent) async {
    final clamped = volumePercent.clamp(0, 150);
    settings.playbackVolume = clamped;
    await settings.save();
    await LinuxHardwareService.setOutputVolume(
      clamped,
      outputDeviceId: settings.audioOutputDeviceId,
    );
    notifyListeners();
  }

  /// 开启/关闭麦克风测试模式（测试模式下说话仅显示音量与识别文字，不触发大模型对话）
  Future<void> setMicTestMode(bool enabled, {bool clear = false}) async {
    if (clear) {
      _micTestText = '';
      _micTestHistory.clear();
    }
    _isMicTesting = enabled;
    _voiceListeningService.isMicTesting = enabled;
    if (enabled && !_voiceListeningService.isListening) {
      await _voiceListeningService.startContinuousListening();
    }
    notifyListeners();
  }

  /// 测试候选短语与开始词的 Embedding 余弦相似度（与 SettingsScreen._runEmbeddingTest 对齐）
  Future<Map<String, dynamic>> testTriggerPhraseSimilarity(
    String candidate,
  ) async {
    final trimmed = candidate.trim();
    if (trimmed.isEmpty) {
      return {'error': '请输入测试词'};
    }
    final words = settings.startWords;
    final startWord = words.isEmpty ? settings.startWord.trim() : words.first;
    final vecB = await _embeddingService.getEmbedding(trimmed);
    var bestWord = startWord;
    var bestSim = -1.0;
    for (final word in (words.isEmpty ? [startWord] : words)) {
      final vecA = await _embeddingService.getEmbedding(word);
      final sim = VectorMath.cosineSimilarity(vecA, vecB);
      if (sim > bestSim) {
        bestSim = sim;
        bestWord = word;
      }
    }
    final isPass = bestSim >= settings.similarityThreshold;
    final text =
        '与开始词「$bestWord」余弦相似度: ${(bestSim * 100).toStringAsFixed(2)}% '
        '(${isPass ? "✅ 判定命中唤醒" : "❌ 未达到阈值 ${(settings.similarityThreshold * 100).toInt()}%"})';
    return {
      'bestWord': bestWord,
      'similarity': bestSim,
      'passed': isPass,
      'text': text,
    };
  }

  /// 通过 ASR 识别录音文件并将文字送入状态机处理
  Future<void> processAudioFile(String filePath) async {
    try {
      final text = await _asrService.transcribeAudioFile(filePath);
      if (text.isNotEmpty) {
        await processRecognizedText(text);
      }
    } catch (_) {}
  }

  /// 用当前填写的 Key/模型做一次 Gemini Live 连接测试（不会切换当前识别引擎）。
  Future<String> testGeminiAsrConnection({
    String? apiKey,
    String? model,
  }) async {
    final probe = GeminiLiveAsrService(
      settings: AppSettings(
        geminiApiKey: apiKey ?? settings.geminiApiKey,
        geminiAsrModel: model ?? settings.geminiAsrModel,
      ),
    );
    try {
      await probe.initialize();
      if (probe.isReady) {
        return '连接成功：${probe.engineName}';
      }
      return '连接失败：${probe.lastError ?? '请检查 API Key、模型名与网络'}';
    } catch (e) {
      return '连接失败：$e';
    } finally {
      probe.dispose();
    }
  }

  void _disposeAsrInstances() {
    final oldAsr = _asrService;
    final oldFinalAsr = _finalAsrService;
    oldAsr.dispose();
    // 两遍解码会复用同一个 SenseVoice 实例作为回退/复检引擎，
    // 回退发生后 _asrService 与 _finalAsrService 可能指向同一对象，避免重复释放。
    if (oldFinalAsr != null && !identical(oldFinalAsr, oldAsr)) {
      oldFinalAsr.dispose();
    }
    _finalAsrService = null;
  }

  void _initServices({bool enableDriverServer = true}) {
    final generation = ++_servicesGeneration;
    // 重建前必须先释放旧的监听服务与识别器：updateSettings() 也会走到这里，
    // 若旧 AudioRecorder 及其 onTextRecognized 回调仍然存活，就会出现
    // 两路麦克风同时上报识别结果（表现为重复/串扰的文本，看起来像识别不准）。
    bool restoreListening = false;
    if (_servicesInitialized) {
      restoreListening = _voiceListeningService.isListening;
      _voiceListeningService.dispose();
      _disposeAsrInstances();
    }
    _servicesInitialized = true;

    if (settings.useRemoteEmbedding) {
      _embeddingService = RemoteOpenAiEmbeddingService(settings: settings);
    } else {
      _embeddingService = LocalQwenEmbeddingService(settings: settings);
    }

    _triggerMatcher = TriggerMatcher(
      settings: settings,
      embeddingService: _embeddingService,
    );
    _triggerMatcher.warmUp();

    _setupCameraService();

    _visionIntentService = VisionIntentService(
      settings: settings,
      embeddingService: _embeddingService,
    );
    unawaited(_visionIntentService.warmUp());

    _llmService = LlmService(settings: settings);
    _lightRagService = (settings.enableLightRag &&
            settings.lightRagBaseUrl.trim().isNotEmpty)
        ? LightRagService(
            baseUrl: settings.lightRagBaseUrl,
            describeImage: _llmService.describeImage,
          )
        : null;
    // 启动/重新配置时补传此前失败的会话归档
    if (_lightRagService != null) unawaited(_lightRagService!.retryPending());
    _ttsService = TtsService(settings: settings);

    // 依据设置选择识别引擎：
    //  - streaming    内置 14M 流式 Zipformer（低延迟，逐字实时）
    //  - sensevoice   内置 SenseVoice（VAD 分段，中文准确率高）
    //  - gemini_live  Gemini 3.5 Transcribe Live（云端，需联网，供对比测试）
    AsrService primaryAsr;
    AsrService fallbackAsr;
    String primaryName;
    String fallbackName;

    // 同一个 SenseVoice 实例既可作为流式引擎的回退，也可作为两遍解码的复检引擎，
    // 避免同时加载两份约 200MB 的离线模型。
    final senseVoiceAsr = LocalSenseVoiceAsrService(settings: settings);

    switch (settings.asrEngine) {
      case AppConstants.asrEngineStreaming:
        primaryAsr = StreamingZipformerAsrService(settings: settings);
        fallbackAsr = senseVoiceAsr;
        primaryName = 'Zipformer 流式';
        fallbackName = 'SenseVoice';
        break;
      case AppConstants.asrEngineGeminiLive:
        primaryAsr = GeminiLiveAsrService(settings: settings);
        fallbackAsr = senseVoiceAsr;
        primaryName = 'Gemini Transcribe Live';
        fallbackName = 'SenseVoice';
        break;
      case AppConstants.asrEngineSenseVoice:
      default:
        primaryAsr = senseVoiceAsr;
        fallbackAsr = StreamingZipformerAsrService(settings: settings);
        primaryName = 'SenseVoice';
        fallbackName = 'Zipformer 流式';
        break;
    }

    // 两遍解码：流式先出字，端点后用内置 SenseVoice 对整段音频复检。
    // 只有流式引擎才需要第二遍；模型未就绪时 finalAsr.isReady 为 false，会自动跳过。
    if (settings.enableTwoPass && primaryAsr.isStreaming) {
      _finalAsrService = senseVoiceAsr;
      unawaited(senseVoiceAsr.initialize());
    }

    // 先把首选引擎挂上，保证麦克风监听可立即启动（模型就绪前会自动补齐，失败则热切换回退）
    _asrService = primaryAsr;

    _voiceListeningService = VoiceListeningService(
      asrService: primaryAsr,
      settings: settings,
      finalAsrService: _finalAsrService,
      onFinalTranscript: (text) => processFinalTranscript(text),
      onTextRecognized: (text) => processRecognizedText(text),
      onManualRecordingRecognized: (text) => sendDirectUserMessage(text),
      onAudioLevelChanged: (level, dbfs, vadNow) {
        notifyListeners();
      },
      onMicTestRecognized: (text, durationMs) {
        _micTestText = text;
        final now = DateTime.now();
        final timeStr =
            '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';
        _micTestHistory.insert(0, {
          'time': timeStr,
          'text': text,
          'durationMs': durationMs,
          'engine': _asrService.engineName,
        });
        if (_micTestHistory.length > 20) {
          _micTestHistory.removeRange(20, _micTestHistory.length);
        }
        notifyListeners();
      },
      onStateChanged: (active, hint) {
        _statusHint = hint;
        notifyListeners();
        _syncForegroundNotification();
        unawaited(_syncFloatingCapsule(force: true));
      },
      isStandbyMode: () => _status == AssistantStatus.idle,
      isPlayingMode: () => _status == AssistantStatus.playing,
    )..isMicTesting = _isMicTesting;

    // 云端实时识别会在最终结果之前给出中间文本。这里只把它当作“结束词探针”：
    // 命中后立即提交大模型，不必等 Gemini 收尾和 VAD 的最终结果。
    if (primaryAsr.isCloudStreaming) {
      primaryAsr.onPartialText = (text) {
        unawaited(processPartialTranscript(text));
      };
    }

    unawaited(() async {
      await primaryAsr.initialize();
      // 初始化期间可能已切换设置或销毁控制器，此时不要再改动当前引擎。
      if (_disposed || generation != _servicesGeneration) return;
      if (primaryAsr.isReady) {
        debugPrint('[AssistantController] $primaryName 识别引擎就绪');
        return;
      }
      debugPrint('[AssistantController] $primaryName 识别引擎未就绪，回退 $fallbackName');
      await fallbackAsr.initialize();
      if (_disposed || generation != _servicesGeneration) return;
      await _swapAsrIfCurrent(primaryAsr, fallbackAsr, fallbackName);
    }());

    if (restoreListening) {
      unawaited(_voiceListeningService.startContinuousListening());
    }

    if (enableDriverServer) {
      // 复用已在运行的调试服务：先 stop 再 bind 同一端口存在竞态，
      // 旧 socket 未释放时会 bind 失败（异常被吞掉），调试接口就此消失。
      _driverServer ??= AppDriverServer(controller: this);
      unawaited(_driverServer!.start());
    }

    _promptSoundService = PromptSoundService(
      outputDeviceId: settings.audioOutputDeviceId,
    );
    unawaited(
      LinuxHardwareService.setOutputVolume(
        settings.playbackVolume,
        outputDeviceId: settings.audioOutputDeviceId,
      ),
    );

    // 悬浮胶囊：绑定展开面板的操作，并把当前状态同步给原生侧。
    FloatingCapsuleService.setActionHandler((action) async {
      switch (action) {
        case 'captureAndAsk':
          await captureAndAskAboutScene();
          break;
        case 'toggleMic':
          await toggleMicListening();
          break;
      }
    });
    unawaited(
      FloatingCapsuleService.setEnabled(
        settings.enableFloatingCapsule,
        micListening: _voiceListeningService.isListening,
        status: floatingCapsuleStatusLabel,
      ),
    );
    unawaited(_syncFloatingCapsule(force: true));
  }

  int get acknowledgeBeepCount => _acknowledgeBeepCount;

  /// 若 [current] 仍是当前生效的识别器且 [next] 已就绪，则热切换到 [next]；
  /// 否则释放 [next]，避免原生模型资源泄露。
  /// 若期间又执行了一轮 [_initServices]，[current] 已不是当前识别器，直接放弃切换。
  Future<void> _swapAsrIfCurrent(
      AsrService current, AsrService next, String nextName) async {
    if (_disposed) {
      next.dispose();
      return;
    }
    if (identical(_asrService, current) && next.isReady) {
      _asrService = next;
      // 关键：同步替换 VoiceListeningService 内部持有的 ASR 引用。
      // 仅改 _asrService 字段时，麦克风路径仍指向已失效的识别器。
      await _voiceListeningService.setAsrService(next);
      // 旧引擎（尤其是 Gemini 的长连接和中间结果回调）已经不再被麦克风路径使用，
      // 必须释放，避免后台 WebSocket/回调继续存活。
      if (!identical(current, next)) {
        current.dispose();
      }
      debugPrint('[AssistantController] 已切换识别引擎到 $nextName');
    } else if (!identical(next, _finalAsrService)) {
      next.dispose();
    }
  }

  /// 确认识别到“小曼/晓漫”激活唤醒或“回答”等结束指令后，立即播放提示音（轻滴声）
  Future<void> playAcknowledgeBeep() async {
    _acknowledgeBeepCount++;
    if (!settings.enablePromptTone) return;
    try {
      await _promptSoundService.playAcknowledgeBeep();
    } catch (_) {}
  }

  /// 更新并保存设置
  Future<void> updateSettings(AppSettings newSettings) async {
    settings = newSettings;
    await settings.save();
    _initServices();
    notifyListeners();
  }

  /// 状态机切换：
  /// 一旦离开 `listeningContent`（例如发送消息进入 `thinking`/`playing` 或返回 `idle`），
  /// 立即清空上一次的唤醒识别字稿与 `[已激活]` 标记，避免发送消息后顶部胶囊仍残留旧的「已命中 / 已激活」状态。
  void _setStatus(AssistantStatus newStatus, [String? hint]) {
    _status = newStatus;
    _scheduleLightRagIdleReset();
    if (newStatus != AssistantStatus.listeningContent) {
      _unmatchedSpeechTimer?.cancel();
      _liveTranscript = '';
      _lastRecognizedSpeech = '';
      _isWakeWordMatched = false;
    }
    if (hint != null) {
      _statusHint = hint;
    }
    notifyListeners();
    _syncForegroundNotification();
    unawaited(_syncFloatingCapsule());
  }

  /// 待机且当前会话非空时开始空闲计时；超过 [AppConstants.lightRagIdleMinutes] 分钟无任何活动则静默切换新会话（触发归档）。
  /// 任何状态变化（录音/思考/播报/新消息）都会重置该计时。
  void _scheduleLightRagIdleReset() {
    _lightRagIdleTimer?.cancel();
    if (_disposed || _status != AssistantStatus.idle || _messages.isEmpty) {
      return;
    }
    _lightRagIdleTimer = Timer(
      const Duration(minutes: AppConstants.lightRagIdleMinutes),
      () {
        if (_disposed ||
            _status != AssistantStatus.idle ||
            _messages.isEmpty) {
          return;
        }
        unawaited(startNewSession(playVoice: false));
      },
    );
  }

  void _syncForegroundNotification() {
    if (!_voiceListeningService.isListening) return;
    // 与悬浮胶囊保持同一套短状态，展开面板第一行统一为
    // “随身助理 - 待机/倾听/思考/播报/失败”。
    ForegroundServiceBridge.update(
      title: '随身助理 - $floatingCapsuleStatusLabel',
      content: _statusHint,
    );
  }

  /// 加载本地持久化的历史对话列表（冷启动默认保持当前空白新对话）
  Future<void> loadChatHistory() async {
    final loaded = await _chatHistoryService.loadSessions();
    if (_disposed) return;

    // 合并可能已在当前内存中产生的会话，避免异步加载覆盖刚发起的提问
    final currentMap = <String, ChatSession>{
      for (final s in _sessions) s.id: s,
    };
    for (final s in loaded) {
      currentMap.putIfAbsent(s.id, () => s);
    }
    _sessions
      ..clear()
      ..addAll(currentMap.values);
    _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    notifyListeners();
  }

  /// 将当前非空会话同步至 `_sessions` 列表，并按需写入持久化存储
  Future<void> _syncCurrentSessionToHistory({bool persist = true}) async {
    if (_messages.isEmpty) return;

    final now = DateTime.now();
    final existingIdx = _sessions.indexWhere((s) => s.id == _currentSessionId);
    final snapshotMessages = List<ChatMessage>.from(_messages);

    if (existingIdx != -1) {
      final existing = _sessions[existingIdx];
      final updated = existing.copyWith(
        updatedAt: now,
        messages: snapshotMessages,
      );
      _sessions.removeAt(existingIdx);
      _sessions.insert(0, updated);
    } else {
      final firstUserMsg = snapshotMessages.firstWhere(
        (m) => m.role == 'user' && m.content.trim().isNotEmpty,
        orElse: () => snapshotMessages.first,
      );
      final title = ChatSession.generateDefaultTitle(firstUserMsg.content);
      final created = ChatSession(
        id: _currentSessionId,
        title: title,
        createdAt: snapshotMessages.first.timestamp,
        updatedAt: now,
        messages: snapshotMessages,
      );
      _sessions.insert(0, created);
    }

    if (persist) {
      await _chatHistoryService.saveSessions(_sessions);
    }
  }

  /// 切换到指定的历史对话，恢复其上下文供继续追问
  Future<void> switchSession(String sessionId) async {
    if (sessionId == _currentSessionId) return;
    final targetIdx = _sessions.indexWhere((s) => s.id == sessionId);
    if (targetIdx == -1) return;

    if (_messages.isNotEmpty) {
      await _syncCurrentSessionToHistory(persist: true);
    }

    final target = _sessions.firstWhere((s) => s.id == sessionId);

    _silenceTimer?.cancel();
    _voiceListeningService.flushBuffers(cooldownMs: 400);
    _currentSpeakingReply = '';
    _currentSessionId = target.id;
    _messages
      ..clear()
      ..addAll(target.messages);
    _liveTranscript = '';
    _lastRecognizedSpeech = '';
    _isWakeWordMatched = false;
    _unmatchedSpeechTimer?.cancel();
    _setStatus(AssistantStatus.idle, '已切换到对话「${target.title}」');
    await _ttsService.stop();
  }

  /// 重命名指定历史对话标题
  Future<void> renameSession(String sessionId, String newTitle) async {
    final trimmed = newTitle.trim();
    if (trimmed.isEmpty) return;
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    if (idx == -1) return;

    _sessions[idx] = _sessions[idx].copyWith(title: trimmed);
    notifyListeners();
    await _chatHistoryService.saveSessions(_sessions);
  }

  /// 删除单条历史对话并清理其关联图片；若删除的是当前活动对话则重置为空白新对话
  Future<void> deleteSession(String sessionId) async {
    final idx = _sessions.indexWhere((s) => s.id == sessionId);
    ChatSession? removed;
    if (idx != -1) {
      removed = _sessions.removeAt(idx);
    }

    if (removed != null) {
      await _chatHistoryService.deleteSessionImages(removed);
      await _chatHistoryService.saveSessions(_sessions);
    }

    if (sessionId == _currentSessionId) {
      _messages.clear();
      await startNewSession(playVoice: false);
    } else {
      notifyListeners();
    }
  }

  /// 清空全部历史对话及关联图片，并重置当前会话为空白新对话
  Future<void> clearAllHistory() async {
    final toDelete = List<ChatSession>.from(_sessions);
    _sessions.clear();
    _messages.clear();
    await _chatHistoryService.deleteAllSessionsImages(toDelete);
    await _chatHistoryService.saveSessions(_sessions);
    await startNewSession(playVoice: false);
  }

  /// 将全部历史对话导出为单个自包含 HTML 文件，返回保存路径
  Future<String> exportAllHistoryToHtml() async {
    if (_messages.isNotEmpty) {
      await _syncCurrentSessionToHistory(persist: true);
    }
    return _chatHistoryService.exportSessionsToHtmlFile(_sessions);
  }

  /// 明确起一个新会话（保留原非空会话到历史记录，清空当前上下文，可选播放“好的”）
  Future<void> startNewSession({bool playVoice = true}) async {
    if (_messages.isNotEmpty) {
      await _syncCurrentSessionToHistory(persist: true);
      // 切到新会话后自动把刚结束的会话（含图片）归档到 LightRAG（后台执行，失败进待传队列）
      final finished = _sessions.where((s) => s.id == _currentSessionId);
      if (finished.isNotEmpty && _lightRagService != null) {
        unawaited(_lightRagService!.archiveSession(finished.first));
      }
    }
    _silenceTimer?.cancel();
    _voiceListeningService.flushBuffers(cooldownMs: 400);
    _currentSessionId = const Uuid().v4();
    _messages.clear();
    _liveTranscript = '';
    _lastRecognizedSpeech = '';
    _isWakeWordMatched = false;
    _unmatchedSpeechTimer?.cancel();
    _setStatus(AssistantStatus.idle, '已开启全新会话，上下文已重置');
    await _ttsService.stop();

    if (playVoice) {
      await _ttsService.speakImmediate(AppConstants.resetPromptReply);
      _voiceListeningService.flushBuffers(cooldownMs: 400);
    }
  }

  Future<void> _enqueueTextProcess(Future<void> Function() action) {
    final next = _textProcessQueue.then((_) => action());
    _textProcessQueue = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return next;
  }

  /// 处理接收到的实时文字片段（无论来自麦克风 ASR 还是测试输入）
  Future<void> processRecognizedText(String recognizedText) {
    final text = recognizedText.trim();
    if (text.isEmpty) return Future<void>.value();
    return _enqueueTextProcess(() => _processRecognizedTextNow(text));
  }

  Future<void> _processRecognizedTextNow(String text) async {
    // 播报状态：走专属的“回声剥离 + 触发词打断”通道，既防止外放回声污染 UI 或误打断，
    // 又能从「外放朗读 + 用户喊小曼」的混音文本中精准剥离出“小曼”并立即中止播报。
    if (_status == AssistantStatus.playing) {
      await _handlePlayingText(text);
      return;
    }

    // 0. 声学回声拒识（Acoustic Echo Rejection）——非播报状态下的统一前置闸门。
    //    桌面端录音链路没有任何平台级 AEC，助手外放的语音会被麦克风回采、再被 ASR 识别成
    //    「用户说话」。若整句为纯回声则直接丢弃；若播报刚结束的尾音里混入了用户喊的“小曼”，
    //    则剥离回声后只保留唤醒词进入倾听态。
    if (_looksLikeAssistantEcho(text)) {
      final residual = TranscriptProcessor.stripAssistantEcho(
        recognized: text,
        recentlySpokenText: _ttsService.recentlySpokenText,
        triggerMatcher: _triggerMatcher,
      );
      final startMatch = residual.isNotEmpty
          ? await _triggerMatcher.checkStartWord(residual)
          : TriggerMatchResult.none();
      if (!startMatch.isMatched) {
        debugPrint('[AssistantController] 已丢弃疑似外放回声（忽略助手自身的朗读内容）: "$text"');
        return;
      }
      debugPrint(
        '[AssistantController] 从外放尾音混音中剥离出唤醒词: 原文="$text" -> 唤醒词="${startMatch.matchedText}"',
      );
      text = startMatch.matchedText;
    }

    _unmatchedSpeechTimer?.cancel();
    _lastRecognizedSpeech = text;

    switch (_status) {
      case AssistantStatus.idle:
        await _handleIdleState(text);
        break;

      case AssistantStatus.listeningContent:
        _isWakeWordMatched = true;
        await _handleListeningState(text);
        break;

      case AssistantStatus.playing:
        // 打断逻辑 (Barge-in)
        await _handlePlayingBargeIn(text);
        break;

      case AssistantStatus.thinking:
        // 思考期间暂时忽略一般语音，若检测到停止也可打断
        break;
    }
  }

  /// 云端实时识别的中间结果：
  /// - 倾听态：用于提前探测结束词，不必等 Gemini 最终收尾；
  /// - 播报态：用于实时探测“小曼/停止”打断词，绕开外放连续发声导致 VAD 不切段的问题。
  Future<void> processPartialTranscript(String partialText) {
    final text = partialText.trim();
    if (text.isEmpty) return Future<void>.value();
    return _enqueueTextProcess(() async {
      if (_status == AssistantStatus.playing) {
        await _handlePlayingText(text);
        return;
      }
      if (_status != AssistantStatus.listeningContent) return;

      final combined = mergeStreamingTranscript(_liveTranscript, text);
      if (!_mightContainEndWord(combined)) return;

      final endMatch = await _triggerMatcher.checkEndWord(combined);
      if (!endMatch.isMatched || _status != AssistantStatus.listeningContent) {
        return;
      }

      debugPrint(
        '[AssistantController] 结束词提前命中（云端中间结果），跳过最终收尾等待: "$combined"',
      );
      _liveTranscript = combined;
      await _submitLiveTranscript(endMatch);
    });
  }

  /// 零成本字面预检：中间结果里必须出现结束词或内置兼容收尾词，
  /// 才值得调用 `checkEndWord`（后者在拼音不匹配时可能触发 embedding）。
  bool _mightContainEndWord(String text) {
    final clean = _triggerMatcher.stripPunctuation(text, all: true);
    if (clean.isEmpty) return false;

    for (final word in settings.endWords) {
      final end = _triggerMatcher.stripPunctuation(word, all: true);
      if (end.isNotEmpty && clean.contains(end)) return true;
    }

    for (final alias in _triggerMatcher.endWordAliases) {
      final a = _triggerMatcher.stripPunctuation(alias, all: true);
      if (a.isNotEmpty && clean.contains(a)) return true;
    }
    return false;
  }

  /// 两遍解码的第二遍结果到达（流式端点后用内置 SenseVoice 复检）。
  ///
  /// 只在“倾听内容”状态生效，避免在思考/播放阶段把复检结果当成新指令。
  Future<void> processFinalTranscript(String finalText) async {
    final text = finalText.trim();
    if (text.isEmpty) return;

    if (_status != AssistantStatus.listeningContent) {
      debugPrint(
        '[AssistantController] 两遍解码结果到达时状态=${_status.name}，忽略: "$text"',
      );
      return;
    }

    final merged = chooseFinalTranscript(_liveTranscript, text);
    if (merged.trim() == _liveTranscript.trim()) return;

    debugPrint(
      '[AssistantController] 两遍解码替换/合并: "$_liveTranscript" + "$text" -> "$merged"',
    );
    _liveTranscript = merged;
    notifyListeners();
    _resetSilenceTimer();

    final endMatch = await _triggerMatcher.checkEndWord(_liveTranscript);
    if (endMatch.isMatched) {
      await _submitLiveTranscript(endMatch);
    }
  }

  /// 选择流式文本与离线复检文本的最终版本。
  @visibleForTesting
  static String chooseFinalTranscript(String live, String finalText) =>
      TranscriptProcessor.chooseFinalTranscript(live, finalText);

  void _scheduleUnmatchedSpeechFade() {
    _isWakeWordMatched = false;
    notifyListeners();

    _unmatchedSpeechTimer?.cancel();
    _unmatchedSpeechTimer = Timer(const Duration(seconds: 4), () {
      if (!_isWakeWordMatched && _status == AssistantStatus.idle) {
        _lastRecognizedSpeech = '';
        notifyListeners();
      }
    });
  }

  /// 待机状态处理：检测“新起一个”或“开始词”
  Future<void> _handleIdleState(String text) async {
    // 0. 极速初筛待机语句（<0.01ms）：若完全无唤醒词/控制指令特征，立即显示灰色未匹配并在4秒后淡化，跳过全部重度计算
    if (!_triggerMatcher.quickWakePlausibilityCheck(text)) {
      _scheduleUnmatchedSpeechFade();
      return;
    }

    // 1. 先检测是否是“新起会话词”（如“新起一个”或“新起一个。”）
    final resetMatch = await _triggerMatcher.checkResetWord(text);
    if (resetMatch.isMatched) {
      _isWakeWordMatched = true;
      notifyListeners();
      await startNewSession(playVoice: true);
      return;
    }

    // 2. 检查是否是一句包含开始词与结束词的完整提问（如“小曼 xxx 回答。”）
    final oneShot = await _triggerMatcher.extractOneShotCommand(text);
    if (oneShot != null) {
      _isWakeWordMatched = true;
    _silenceTimer?.cancel();
      _liveTranscript = '';
      _voiceListeningService.resetStream();
      unawaited(playAcknowledgeBeep());
      _setStatus(
        AssistantStatus.thinking,
        '识别到指令【${oneShot.promptContent}】，正在请求回复...',
      );
      await _submitToLlm(oneShot.promptContent);
      return;
    }

    // 3. 检测是否包含“开始词”（如“晓漫”或同音“小曼”）
    final startMatch = await _triggerMatcher.checkStartWord(text);
    if (startMatch.isMatched) {
      _isWakeWordMatched = true;
      _liveTranscript = '';
      _voiceListeningService.resetStream();
      unawaited(playAcknowledgeBeep());
      _setStatus(
        AssistantStatus.listeningContent,
        '听到开始词【${startMatch.matchedText}】，正在倾听内容...（说“${settings.endWords.join("、")}”结束）',
      );

      final remaining =
          TranscriptProcessor.extractRemainingAfterStart(text, startMatch);

      _startSilenceTimer();

      if (remaining.isNotEmpty) {
        await _handleListeningState(remaining);
      }
      return;
    }

    // 4. 未能匹配到小曼/开始词：显示为灰色未命中，并在 4 秒后自动淡化消隐
    _scheduleUnmatchedSpeechFade();
  }

  /// 倾听内容状态处理：检测“结束词”
  Future<void> _handleListeningState(String text) async {
    _resetSilenceTimer();

    // 仅当文本具备唤醒词或重置词特征时，才检测重置/二次唤醒，
    // 避免普通提问内容（如“听得到吗”）或单纯结束词（如“回答。”）触发多次冗余计算。
    if (_triggerMatcher.quickWakePlausibilityCheck(text)) {
      // 0. 优先检测是否说出“新起一个”（重置指令）
      final resetMatch = await _triggerMatcher.checkResetWord(text);
      if (resetMatch.isMatched) {
        _liveTranscript = '';
        await startNewSession(playVoice: true);
        return;
      }

      // 1. 若倾听过程中再次听到“开始词”（如“小曼”、“晓漫”、“小麦”等）：
      // 抛弃之前的所有倾听内容，重新开始收集新指令
      final oneShot = await _triggerMatcher.extractOneShotCommand(text);
      if (oneShot != null) {
        _liveTranscript = '';
    _silenceTimer?.cancel();
        unawaited(playAcknowledgeBeep());
        _setStatus(
          AssistantStatus.thinking,
          '识别到新指令【${oneShot.promptContent}】，正在请求回复...',
        );
        await _submitToLlm(oneShot.promptContent);
        return;
      }

      final startMatch = await _triggerMatcher.checkStartWord(text);
      if (startMatch.isMatched) {
        _liveTranscript = '';
        _voiceListeningService.resetStream();
        unawaited(playAcknowledgeBeep());
        _setStatus(
          AssistantStatus.listeningContent,
          '重新听到开始词【${startMatch.matchedText}】，已清空前文，正在倾听新内容...（说“${settings.endWords.join("、")}”结束）',
        );
        _resetSilenceTimer();

        final remaining =
            TranscriptProcessor.extractRemainingAfterStart(text, startMatch);

        if (remaining.isNotEmpty) {
          await _handleListeningState(remaining);
        } else {
          notifyListeners();
        }
        return;
      }
    }

    // 2. 正常内容追加
    if (_asrService.isStreaming || _asrService.isCloudStreaming) {
      // 流式识别器每次返回的是「当前这一句」的累计文本。当用户在提问与结束词之间停顿、
      // 识别器命中端点复位后，结束词会被当成新的一句返回；此处若直接覆盖就会丢掉前面的问题，
      // 于是出现「明明听到了‘回答’，却因为没有内容而不发送」。因此按重叠关系合并。
      _liveTranscript = mergeStreamingTranscript(_liveTranscript, text);
    } else {
      _liveTranscript += (_liveTranscript.isEmpty ? '' : ' ') + text;
    }
    notifyListeners();

    // 3. 检测是否命中了结束词（如“回答”或同音、语义结束词及带标点如“回答。”）
    final endMatch = await _triggerMatcher.checkEndWord(_liveTranscript);
    if (endMatch.isMatched) {
      await _submitLiveTranscript(endMatch);
    }
  }

  /// 命中结束词后，截断并提交 `_liveTranscript` 中的提问内容。
  Future<void> _submitLiveTranscript(TriggerMatchResult endMatch) async {
    _silenceTimer?.cancel();
    final originalTranscript = _liveTranscript;
    // 精准截断结束词之前的内容，坚决丢弃结束词本身及后续的一切内容与杂音
    String promptContent = '';
    if (endMatch.startIndex >= 0 &&
        endMatch.startIndex <= _liveTranscript.length) {
      promptContent = _triggerMatcher.stripPunctuation(
        _liveTranscript.substring(0, endMatch.startIndex),
      );
    } else {
      promptContent = _triggerMatcher.stripEndWord(_liveTranscript);
    }
    _liveTranscript = '';
    _voiceListeningService.flushBuffers(cooldownMs: 300);

    if (promptContent.isEmpty) {
      debugPrint(
        '[AssistantController] 命中结束词【${endMatch.matchedText}】但未捕获到提问内容，返回待机。原文: "$originalTranscript"',
      );
      _setStatus(AssistantStatus.idle, '只听到结束词，未捕获到提问内容，返回待机');
      return;
    }

    unawaited(playAcknowledgeBeep());
    await _submitToLlm(promptContent);
  }

  /// 合并流式识别文本：识别器每次给出的是「当前句」的累计结果。
  @visibleForTesting
  static String mergeStreamingTranscript(String current, String incoming) =>
      TranscriptProcessor.mergeStreamingTranscript(current, incoming);

  /// 判断 [recognized] 是否只是助手刚外放的朗读内容被麦克风回采后又被识别出来的回声。
  bool _looksLikeAssistantEcho(String recognized) {
    return TranscriptProcessor.looksLikeAssistantEcho(
      recognized: recognized,
      recentlySpokenText: _ttsService.recentlySpokenText,
      triggerMatcher: _triggerMatcher,
    );
  }

  /// 播报期间收到识别文本：先剥离外放回声，再检查残余部分是否包含打断词（“小曼/晓漫/停止/暂停”）。
  Future<void> _handlePlayingText(String rawText) async {
    if (!settings.enableBargeIn) return;

    final residual = TranscriptProcessor.stripAssistantEcho(
      recognized: rawText,
      recentlySpokenText: _ttsService.recentlySpokenText,
      triggerMatcher: _triggerMatcher,
    );
    if (residual.isEmpty) {
      debugPrint('[AssistantController] 播报期间已丢弃外放回声: "$rawText"');
      return;
    }

    await _handlePlayingBargeIn(residual);
  }

  /// 播放中打断处理 (Barge-in)
  Future<void> _handlePlayingBargeIn(String text) async {
    if (!settings.enableBargeIn) return;

    final cleanRecognized = _triggerMatcher.stripPunctuation(text, all: true);
    if (cleanRecognized.isEmpty) return;

    // 1. 用户真实发出的打断指令（如说出开始词“小曼/晓漫”，或“停止”、“暂停”）
    final isStopCommand = text.contains('停止') || text.contains('暂停');
    if (!isStopCommand && !_triggerMatcher.quickWakePlausibilityCheck(text)) {
      return;
    }
    final startMatch = isStopCommand
        ? TriggerMatchResult.none()
        : await _triggerMatcher.checkStartWord(text);
    if (startMatch.isMatched || isStopCommand) {
      debugPrint(
        '[AssistantController] 播报期触发语音打断: text="$text", '
        'matched="${startMatch.matchedText}", method=${startMatch.method}',
      );
      _unmatchedSpeechTimer?.cancel();
      _lastRecognizedSpeech =
          startMatch.isMatched ? startMatch.matchedText : text;
      _isWakeWordMatched = startMatch.isMatched;

      await _ttsService.stop();
      _voiceListeningService.flushBuffers(cooldownMs: 400);
      _currentSpeakingReply = '';
      if (startMatch.isMatched) {
        _liveTranscript = '';
        unawaited(playAcknowledgeBeep());
        _setStatus(
          AssistantStatus.listeningContent,
          '已打断！正在倾听新指令...（说“${settings.endWords.join("、")}”结束）',
        );
        _startSilenceTimer();
      } else {
        _setStatus(AssistantStatus.idle, '已停止朗读，返回待机');
      }
    }
  }

  static final RegExp _sentenceBoundaryRegExp = RegExp(r'[。！？\n!?]');

  void _updateAssistantMessageContent(
    String assistantMsgId,
    int preferredIndex,
    String content,
  ) {
    int idx = (preferredIndex >= 0 &&
            preferredIndex < _messages.length &&
            _messages[preferredIndex].id == assistantMsgId)
        ? preferredIndex
        : _messages.indexWhere((m) => m.id == assistantMsgId);
    if (idx != -1) {
      _messages[idx] = ChatMessage(
        id: assistantMsgId,
        role: 'assistant',
        content: content,
        timestamp: DateTime.now(),
        sessionId: _currentSessionId,
      );
      notifyListeners();
    }
  }
  ///
  /// 提交给大模型并流式朗读回复
  ///
  /// [preCapturedImageBytes]/[preCapturedImagePath] 用于一键抓拍场景：
  /// 图片已在进入本方法前拍好，不再重复做视觉意图识别与二次抓拍。
  Future<void> _submitToLlm(
    String userText, {
    Uint8List? preCapturedImageBytes,
    String? preCapturedImagePath,
    bool enableTts = true,
  }) async {
    _setStatus(AssistantStatus.thinking, '正在思考回复...');

    Uint8List? capturedImageBytes = preCapturedImageBytes;
    String? capturedImagePath = preCapturedImagePath;

    final hasPreCapturedImage =
        capturedImageBytes != null && capturedImageBytes.isNotEmpty;
    if (!hasPreCapturedImage) {
      // 向量语义识别是否需要发送摄像头画面
      final visionStopwatch = Stopwatch()..start();
      final visionMatch =
          await _visionIntentService.checkVisionIntent(userText);
      visionStopwatch.stop();
      debugPrint(
        '[AssistantController] 视觉意图检查耗时 ${visionStopwatch.elapsedMilliseconds}ms '
        '(matched=${visionMatch.isMatched}, sim=${visionMatch.similarity.toStringAsFixed(3)})',
      );
      if (visionMatch.isMatched) {
        // 1. 播放相机快门声（咔嚓声）
        unawaited(_promptSoundService.playShutterSound());
        _setStatus(
          AssistantStatus.thinking,
          '识别到视觉需求（匹配“${visionMatch.matchedPrototype}”），正在抓拍画面...',
        );

        // 2. 按需激活相机并抓拍当前画面（重置X分钟空闲保持计时器）
        try {
          final captureResult = await cameraService.capturePhoto();
          capturedImageBytes = captureResult.imageBytes;
          capturedImagePath = captureResult.filePath;
        } catch (e) {
          debugPrint('[AssistantController] 抓拍未能成功: $e');
          _setStatus(
            AssistantStatus.thinking,
            '抓拍未成功 ($e)，正在继续分析对话...',
          );
        }
      }
    }

    final activeSessionId = _currentSessionId;
    final userMsgId = const Uuid().v4();
    if ((capturedImagePath != null && capturedImagePath.isNotEmpty) ||
        (capturedImageBytes != null && capturedImageBytes.isNotEmpty)) {
      capturedImagePath = await _chatHistoryService.persistImage(
        sessionId: activeSessionId,
        messageId: userMsgId,
        sourcePath: capturedImagePath,
        imageBytes: capturedImageBytes,
      );
    }

    final userMsg = ChatMessage(
      id: userMsgId,
      role: 'user',
      content: userText,
      timestamp: DateTime.now(),
      sessionId: activeSessionId,
      imagePath: capturedImagePath,
    );
    _messages.add(userMsg);
    await _syncCurrentSessionToHistory(persist: true);
    notifyListeners();

    final assistantMsgId = const Uuid().v4();
    final assistantContentBuffer = StringBuffer();
    final currentAssistantMsg = ChatMessage(
      id: assistantMsgId,
      role: 'assistant',
      content: '',
      timestamp: DateTime.now(),
      sessionId: activeSessionId,
    );
    _messages.add(currentAssistantMsg);
    final assistantMsgIndex = _messages.length - 1;
    await _syncCurrentSessionToHistory(persist: false);
    notifyListeners();

    try {
      _setStatus(
        enableTts ? AssistantStatus.playing : AssistantStatus.thinking,
        '正在回答...',
      );

      final sentenceBuffer = StringBuffer();
      _currentSpeakingReply = '';

      final llmStopwatch = Stopwatch()..start();
      var loggedFirstToken = false;

      // 流式请求大模型（若附带图片则传递 imageBytes）
      await for (final token in _llmService.sendChatStream(
        history: _messages.sublist(0, _messages.length - 1),
        newUserContent: userText,
        sessionId: activeSessionId,
        imageBytes: capturedImageBytes,
        onToolCall: (toolName, query) {
          if (_currentSessionId != activeSessionId) return;
          assistantContentBuffer.clear();
          sentenceBuffer.clear();
          _currentSpeakingReply = '';
          final q = query.trim();
          final searchDisplay = q.isNotEmpty ? '正在搜索：$q...' : '正在搜索...';
          _updateAssistantMessageContent(
            assistantMsgId,
            assistantMsgIndex,
            searchDisplay,
          );
        },
      )) {
        if (_currentSessionId != activeSessionId) {
          break;
        }
        if (!loggedFirstToken && token.isNotEmpty) {
          loggedFirstToken = true;
          debugPrint(
            '[AssistantController] 大模型首字延迟 ${llmStopwatch.elapsedMilliseconds}ms',
          );
        }
        assistantContentBuffer.write(token);
        sentenceBuffer.write(token);
        _currentSpeakingReply = assistantContentBuffer.toString();

        // 更新 UI 中的文本展示
        _updateAssistantMessageContent(
          assistantMsgId,
          assistantMsgIndex,
          _currentSpeakingReply,
        );
        unawaited(_syncCurrentSessionToHistory(persist: false));

        if (enableTts) {
          // 按标点切句，流式追加进 TTS 顺序队列（仅截取到最后一个句末标点，保留后续残余字符）
          final currentText = sentenceBuffer.toString();
          final matches = _sentenceBoundaryRegExp.allMatches(currentText);
          if (matches.isNotEmpty) {
            final lastMatch = matches.last;
            final readySentence = currentText.substring(0, lastMatch.end);
            if (readySentence.trim().length >= 6) {
              final remainder = currentText.substring(lastMatch.end);
              sentenceBuffer
                ..clear()
                ..write(remainder);
              if (_status == AssistantStatus.playing) {
                _ttsService.enqueueSentence(
                  readySentence,
                  shouldCancel: () => _status != AssistantStatus.playing,
                );
              }
            }
          }
        }
      }

      debugPrint(
        '[AssistantController] 大模型输出完成，总耗时 ${llmStopwatch.elapsedMilliseconds}ms',
      );

      if (enableTts) {
        // 朗读最后剩余的尾句
        final remaining = sentenceBuffer.toString().trim();
        if (_currentSessionId == activeSessionId &&
            remaining.isNotEmpty &&
            _status == AssistantStatus.playing) {
          _ttsService.enqueueSentence(remaining,
              shouldCancel: () => _status != AssistantStatus.playing);
        }

        // 等待 TTS 顺序播放队列彻底播放完毕（避免流式结束后立即切回待机导致语音截断）
        if (_currentSessionId == activeSessionId &&
            _status == AssistantStatus.playing) {
          await _ttsService.waitForCompletion();
        }
      }
    } catch (e) {
      if (_currentSessionId == activeSessionId) {
        _updateAssistantMessageContent(
          assistantMsgId,
          assistantMsgIndex,
          '请求大模型失败: $e',
        );
        if (enableTts) {
          await _ttsService.speakImmediate('抱歉，网络或模型请求异常');
        }
      }
    } finally {
      if (_currentSessionId == activeSessionId) {
        await _syncCurrentSessionToHistory(persist: true);
      }
      _currentSpeakingReply = '';
      if (_status == AssistantStatus.playing ||
          _status == AssistantStatus.thinking) {
        _voiceListeningService.flushBuffers(cooldownMs: 500);
        _setStatus(AssistantStatus.idle, '待机中，可说“${settings.startWord}”随时呼唤');
      }
    }
  }

  void _startSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer =
        Timer(Duration(seconds: settings.silenceTimeoutSeconds), () async {
      if (_status != AssistantStatus.listeningContent) return;

      // 超时保护：如果已经识别到内容，说明用户只是忘了说结束词，
      // 此时应自动提交，而不是把整段话丢掉。
      final pending = _liveTranscript.trim();
      if (settings.autoSubmitOnTimeout && pending.isNotEmpty) {
        final prompt = _triggerMatcher.stripEndWord(pending).trim();
        _liveTranscript = '';
        _voiceListeningService.flushBuffers(cooldownMs: 300);
        if (prompt.isNotEmpty) {
          debugPrint('[AssistantController] 静音超时，自动提交已识别内容: "$prompt"');
          unawaited(playAcknowledgeBeep());
          await _submitToLlm(prompt);
          return;
        }
      }

      _liveTranscript = '';
      _setStatus(AssistantStatus.idle, '长时间未收到结束词，已自动取消');
      await _ttsService.speakImmediate(AppConstants.timeoutPromptReply);
      _voiceListeningService.flushBuffers(cooldownMs: 400);
    });
  }

  void _resetSilenceTimer() {
    if (_status == AssistantStatus.listeningContent) {
      _startSilenceTimer();
    }
  }

  /// 模拟输入或文本命令测试
  Future<void> simulateUserInput(String text) async {
    await processRecognizedText(text);
  }

  /// 统一处理手动文本/手动录音输入的前置状态清理及控制指令拦截。
  /// 返回 true 表示已被控制指令（重置/停止）消费，无需继续提交给大模型。
  Future<bool> _prepareDirectUserInput(
    String text, {
    bool playVoice = true,
  }) async {
    await _ttsService.stop();
    _voiceListeningService.flushBuffers(cooldownMs: 300);
    _silenceTimer?.cancel();
    _unmatchedSpeechTimer?.cancel();
    _liveTranscript = '';
    _lastRecognizedSpeech = '';
    _isWakeWordMatched = false;

    final resetMatch = await _triggerMatcher.checkResetWord(text);
    if (resetMatch.isMatched) {
      await startNewSession(playVoice: playVoice);
      return true;
    }

    if (text == '停止' || text == '暂停') {
      _setStatus(AssistantStatus.idle, '已停止朗读，返回待机');
      return true;
    }

    return false;
  }

  /// 直接发送文本消息（文本输入框直接发送，不检测、不要求、不剥离开始词和结束词，直接送入大模型，且不自动朗读）
  Future<void> sendTextMessage(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) return;
    if (await _prepareDirectUserInput(text, playVoice: false)) return;

    // 直接送入大模型思考（文本发送不自动朗读，绝不检测或剥离开始词与结束词）
    await _submitToLlm(text, enableTts: false);
  }

  /// 直接发送用户语音/文本指令（手动对讲录音触发，不需启动词与结束词，直接送入大模型）
  Future<void> sendDirectUserMessage(String rawText) async {
    final text = rawText.trim();
    if (text.isEmpty) return;
    if (await _prepareDirectUserInput(text)) return;

    // 如果录音中包含了启动词或结束词（例如顺口说了“晓漫 ... 回答”），予以清洗保留核心指令；没有则直接作为指令内容
    String promptContent = text;
    final startMatch = await _triggerMatcher.checkStartWord(promptContent);
    if (startMatch.isMatched) {
      promptContent = TranscriptProcessor.extractRemainingAfterStart(
        promptContent,
        startMatch,
      );
    }
    promptContent = _triggerMatcher.stripEndWord(promptContent);
    if (promptContent.isEmpty) {
      promptContent = text; // 若剥离后为空则回退到原始文本
    }

    // 确认识别后播放轻滴提示音（与自动模式一致的交互反馈）
    unawaited(playAcknowledgeBeep());

    // 直接送入大模型思考并朗读回答
    await _submitToLlm(promptContent);
  }

  /// 运行全链路自动化诊断自测
  Future<Map<String, dynamic>> runDiagnosticSelfTest() async {
    _isSelfTesting = true;
    _selfTestLogs.clear();

    final result = await DiagnosticSelfTestRunner.run(
      startWord: settings.startWord,
      embeddingService: _embeddingService,
      triggerMatcher: _triggerMatcher,
      llmService: _llmService,
      visionIntentService: _visionIntentService,
      cameraService: cameraService,
      getSessionId: () => _currentSessionId,
      isMessagesEmpty: () => _messages.isEmpty,
      onResetSession: () => startNewSession(playVoice: false),
      onLog: _addTestLog,
      onStepCompleted: notifyListeners,
    );

    _isSelfTesting = false;
    notifyListeners();

    return {
      'success': result['success'],
      'logs': _selfTestLogs,
      'timestamp': result['timestamp'],
    };
  }

  void _addTestLog(String log) {
    _selfTestLogs
        .add('[${DateTime.now().toIso8601String().substring(11, 19)}] $log');
  }

  AppDriverServer? get driverServer => _driverServer;

  Future<void> disposeAsync() async {
    await _driverServer?.stop();
    dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    _servicesGeneration++;
    FloatingCapsuleService.setActionHandler(null);
    _lightRagIdleTimer?.cancel();
    _silenceTimer?.cancel();
    _unmatchedSpeechTimer?.cancel();
    _voiceListeningService.dispose();
    _disposeAsrInstances();
    _ttsService.dispose();
    _promptSoundService.dispose();
    _cameraService?.dispose();
    _driverServer?.stop();
    super.dispose();
  }
}
