import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../../core/models/app_settings.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/storage_bridge.dart';
import 'asr_post_processor.dart';

/// 统一的 ASR 抽象。
///
/// 说明：`fromVad` 为 true 时表示音频已经过 Silero VAD 判定为有效语音，
/// 此时跳过能量门控，避免把远场/轻声说话再次误杀。
abstract class AsrService {
  AppSettings get settings;

  bool get isStreaming => false;

  /// 是否为云端实时识别：识别过程中会通过 [onPartialText] 回调累计文本。
  ///
  /// 与 [isStreaming] 区分开：`isStreaming` 代表内置 sherpa 在线识别器，
  /// 麦克风采集路径会走 `OnlineStream`；云端实时识别仍然复用 VAD 分段，
  /// 只是在等待最终结果期间额外提供“中间结果”，用于提前命中结束词。
  bool get isCloudStreaming => false;

  /// 云端实时识别的中间结果回调（累计文本）。
  ///
  /// 只有 [isCloudStreaming] 为 true 的引擎才会调用；普通离线引擎不会触发。
  void Function(String text)? onPartialText;

  /// 底层模型是否已加载就绪（用于引擎选择与降级判定）。
  bool get isReady => false;

  /// 用于日志/UI 的引擎名称。
  String get engineName => runtimeType.toString();

  /// 允许引擎按自身特性微调 VAD 的尾静音时长。
  ///
  /// 默认原样返回；云端实时识别为了降低“说完结束词还要等 VAD 收尾”的延迟，
  /// 会在用户仍使用默认值时使用更短的尾静音。调用方必须使用返回值同时创建
  /// VAD 和计算预卷偏移，否则预卷会错位。
  double adjustVadMinSilence(double requested) => requested;

  /// 加载底层模型。默认无操作。
  Future<void> initialize() async {}

  sherpa_onnx.OnlineRecognizer? get onlineRecognizer => null;
  sherpa_onnx.OnlineStream? createOnlineStream({String hotwords = ''}) => null;

  Future<String> transcribeAudioFile(
    String filePath, {
    bool isStandbyWakeCheck = false,
  }) async {
    ensureSherpaBindings();
    final file = File(filePath);
    if (!await file.exists()) return '';

    try {
      final wave = sherpa_onnx.readWave(filePath);
      if (wave.samples.isEmpty) return '';
      return transcribeSamples(
        wave.samples,
        sampleRate: wave.sampleRate,
        isStandbyWakeCheck: isStandbyWakeCheck,
      );
    } catch (e, st) {
      debugPrint('[$runtimeType] 读文件识别异常: $e\n$st');
      return '';
    }
  }

  Future<String> transcribeSamples(
    Float32List samples, {
    int sampleRate = 16000,
    bool isStandbyWakeCheck = false,
    bool fromVad = false,
  });

  /// 是否支持“边说边传”：VAD 判定正在说话期间就把音频实时送给引擎。
  ///
  /// 只有云端实时引擎会返回 true。返回 true 时，[VoiceListeningService] 会改走
  /// [beginLiveUtterance] / [appendLiveAudio] / [endLiveUtterance] 这条路径，
  /// 不再等 VAD 切完段才整段上传。
  bool get supportsLiveStreaming => false;

  /// 开始一段实时语音。
  ///
  /// [backfill] 是预卷 + VAD 判定“正在说话”之前已经说出的音频，调用方一次性补齐，
  /// 避免句首被 VAD 的判定延迟削掉。
  void beginLiveUtterance(
    Float32List backfill, {
    bool isStandbyWakeCheck = false,
  }) {}

  /// 说话过程中追加 16k 单声道音频（按到达顺序）。
  void appendLiveAudio(Float32List samples) {}

  /// 说话结束，返回最终文本。
  ///
  /// 返回 `null` 表示这段没接住（连接失败/超时），调用方应回退到整段识别；
  /// 返回空串表示识别到了但不可用（例如非中文），直接丢弃即可。
  Future<String?> endLiveUtterance() async => null;

  Future<sherpa_onnx.VoiceActivityDetector?> createVad({
    double minSilenceDuration = 0.50,
    double minSpeechDuration = 0.25,
    double maxSpeechDuration = 30.0,
    double threshold = 0.40,
  }) {
    return createSileroVad(
      settings: settings,
      minSilenceDuration: minSilenceDuration,
      minSpeechDuration: minSpeechDuration,
      maxSpeechDuration: maxSpeechDuration,
      threshold: threshold,
    );
  }

  /// 释放底层原生资源（识别器 / VAD 等）。默认无操作。
  void dispose() {}
}

// ---------------------------------------------------------------------------
// 公共工具
// ---------------------------------------------------------------------------

bool _bindingsReady = false;

/// 初始化 sherpa-onnx 原生绑定（Windows/Linux 下先预加载动态库，避免路径或版本冲突）。
void ensureSherpaBindings() {
  if (_bindingsReady) return;
  _bindingsReady = true;

  String? customSherpaDir;

  if (Platform.isWindows) {
    final currentDir = Directory.current.path;
    final possibleOrtDlls = [
      '$currentDir\\onnxruntime.dll',
      r'C:\Users\wh101\AppData\Local\Pub\Cache\hosted\pub.dev\sherpa_onnx_windows-1.13.8\windows\onnxruntime.dll',
    ];
    for (final dllPath in possibleOrtDlls) {
      if (File(dllPath).existsSync()) {
        try {
          DynamicLibrary.open(dllPath);
          break;
        } catch (_) {}
      }
    }
    final possibleSherpaDlls = [
      '$currentDir\\sherpa-onnx-c-api.dll',
      r'C:\Users\wh101\AppData\Local\Pub\Cache\hosted\pub.dev\sherpa_onnx_windows-1.13.8\windows\sherpa-onnx-c-api.dll',
    ];
    for (final dllPath in possibleSherpaDlls) {
      if (File(dllPath).existsSync()) {
        try {
          DynamicLibrary.open(dllPath);
          break;
        } catch (_) {}
      }
    }
  } else if (Platform.isLinux) {
    final currentDir = Directory.current.path;
    final exeDir = p.dirname(Platform.resolvedExecutable);
    final home = Platform.environment['HOME'] ?? '';
    final candidateDirs = <String>[
      currentDir,
      p.join(currentDir, 'lib'),
      p.join(currentDir, 'linux_server', 'lib'),
      exeDir,
      p.join(exeDir, 'lib'),
      if (home.isNotEmpty)
        p.join(
          home,
          '.pub-cache',
          'hosted',
          'pub.dev',
          'sherpa_onnx_linux-1.13.8',
          'linux',
          'x64',
        ),
      '/usr/local/lib',
    ];
    for (final dir in candidateDirs) {
      final ortSo = File(p.join(dir, 'libonnxruntime.so'));
      final sherpaSo = File(p.join(dir, 'libsherpa-onnx-c-api.so'));
      if (sherpaSo.existsSync()) {
        if (ortSo.existsSync()) {
          try {
            DynamicLibrary.open(ortSo.path);
          } catch (_) {}
        }
        try {
          DynamicLibrary.open(sherpaSo.path);
          customSherpaDir = dir;
          break;
        } catch (_) {}
      }
    }
  }

  sherpa_onnx.initBindings(customSherpaDir);
}

/// 解析内置模型文件路径。查找顺序：
/// 1. 工程相对目录或可执行文件同级目录（桌面调试 / Linux 服务端）
/// 2. 应用文档目录（移动端）
/// 3. Flutter 资产包（Android/打包后）
Future<String?> resolveModelPath(
  String assetPath, {
  int minBytes = 1024,
}) async {
  bool usable(File f) {
    try {
      return f.existsSync() && f.lengthSync() >= minBytes;
    } catch (_) {
      return false;
    }
  }

  // 1. 工程相对目录或可执行文件同级目录
  final directCandidates = <File>[
    File(assetPath),
    File(p.join(p.dirname(Platform.resolvedExecutable), assetPath)),
  ];
  for (final direct in directCandidates) {
    if (usable(direct)) return direct.path;
  }

  // 2. 应用文档目录
  try {
    final appDir = await StorageBridge.getAppDocumentsDirectory();
    final local = File('${appDir.path}${Platform.pathSeparator}$assetPath');
    if (usable(local)) return local.path;
  } catch (_) {}

  // 3. 资产包（首次运行时释放到应用文档目录）
  try {
    final data = await StorageBridge.loadAssetBytes(assetPath);
    if (data == null || data.lengthInBytes < minBytes) return null;
    try {
      final appDir = await StorageBridge.getAppDocumentsDirectory();
      final local = File('${appDir.path}${Platform.pathSeparator}$assetPath');
      local.parent.createSync(recursive: true);
      await local.writeAsBytes(data, flush: true);
      return local.path;
    } catch (_) {
      return null;
    } finally {
      // 大模型（SenseVoice 约 228MB）释放到磁盘后立即清掉资产缓存，
      // 避免首次启动时 ByteData 与模型推理内存叠加导致 Android OOM。
      StorageBridge.evictAsset(assetPath);
    }
  } catch (_) {
    return null;
  }
}

/// 判断音频是否近似静音。阈值比旧版更宽松，避免误杀远场/轻声说话。
bool isNearSilence(Float32List samples) {
  if (samples.isEmpty) return true;
  double sumSq = 0.0;
  double peak = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final absVal = samples[i].abs();
    if (absVal > peak) peak = absVal;
    sumSq += absVal * absVal;
  }
  final rms = math.sqrt(sumSq / samples.length);
  return peak < 0.006 && rms < 0.0015;
}

/// 构建 Silero VAD。所有引擎共用同一套参数，保证行为一致。
Future<sherpa_onnx.VoiceActivityDetector?> createSileroVad({
  required AppSettings settings,
  double? minSilenceDuration,
  double? minSpeechDuration,
  double? maxSpeechDuration,
  double? threshold,
}) async {
  ensureSherpaBindings();
  final vadPath = await resolveModelPath(
    'assets/models/silero_vad.onnx',
    minBytes: 100000,
  );
  if (vadPath == null) {
    debugPrint('[AsrService] 未找到 silero_vad.onnx');
    return null;
  }

  try {
    final config = sherpa_onnx.VadModelConfig(
      sileroVad: sherpa_onnx.SileroVadModelConfig(
        model: vadPath,
        threshold: threshold ?? settings.vadThreshold,
        minSilenceDuration:
            minSilenceDuration ?? settings.vadMinSilenceSeconds,
        minSpeechDuration: minSpeechDuration ?? settings.vadMinSpeechSeconds,
        maxSpeechDuration: maxSpeechDuration ?? settings.vadMaxSpeechSeconds,
        windowSize: 512,
      ),
      sampleRate: 16000,
      numThreads: 1,
      provider: 'cpu',
      debug: false,
    );
    final vad = sherpa_onnx.VoiceActivityDetector(
      config: config,
      bufferSizeInSeconds: 30,
    );
    debugPrint(
      '[AsrService] Silero VAD 就绪 (threshold=${threshold ?? settings.vadThreshold}, '
      'minSilence=${minSilenceDuration ?? settings.vadMinSilenceSeconds}s, '
      'minSpeech=${minSpeechDuration ?? settings.vadMinSpeechSeconds}s, '
      'maxSpeech=${maxSpeechDuration ?? settings.vadMaxSpeechSeconds}s)',
    );
    return vad;
  } catch (e, st) {
    debugPrint('[AsrService] 初始化 VAD 失败: $e\n$st');
    return null;
  }
}

/// 所有识别引擎共用的文本后处理（清理特殊标记 + 同音词/领域词纠正）。
String postProcessAsrText(String text, {required bool wakeContext}) {
  final cleaned = text.replaceAll(RegExp(r'<\|[^>]+?>'), '').trim();
  return AsrPostProcessor.instance.process(cleaned, wakeContext: wakeContext);
}

int _threadCount({int max = 4}) {
  return math.max(1, math.min(max, Platform.numberOfProcessors));
}

// ---------------------------------------------------------------------------
// SenseVoice 离线
// ---------------------------------------------------------------------------

/// 本地 SenseVoice 离线语音识别服务（内置模型，无需下载）。
class LocalSenseVoiceAsrService extends AsrService {
  @override
  final AppSettings settings;
  sherpa_onnx.OfflineRecognizer? _recognizer;
  Future<void>? _initFuture;
  bool _isReady = false;
  bool _disposed = false;

  LocalSenseVoiceAsrService({required this.settings});

  @override
  bool get isReady => _isReady;

  @override
  String get engineName => 'SenseVoice';

  @override
  Future<void> initialize() {
    if (_isReady) return Future.value();
    final existing = _initFuture;
    if (existing != null) return existing;
    _initFuture = _doInitialize().whenComplete(() {
      if (!_isReady) _initFuture = null;
    });
    return _initFuture!;
  }

  Future<void> _doInitialize() async {
    try {
      ensureSherpaBindings();
      await AsrPostProcessor.instance.ensureLoaded();

      final modelPath = await resolveModelPath(
        'assets/models/sense-voice/model.int8.onnx',
        minBytes: 10000000,
      );
      final tokensPath = await resolveModelPath(
        'assets/models/sense-voice/tokens.txt',
        minBytes: 100,
      );

      debugPrint(
        '[LocalSenseVoiceAsrService] model=$modelPath, tokens=$tokensPath',
      );

      if (modelPath == null || tokensPath == null) {
        debugPrint('[LocalSenseVoiceAsrService] 模型或词表缺失，初始化中止');
        return;
      }

      final threadCount = _threadCount(max: 4);
      final modelConfig = sherpa_onnx.OfflineModelConfig(
        senseVoice: sherpa_onnx.OfflineSenseVoiceModelConfig(
          model: modelPath,
          language: 'zh',
          useInverseTextNormalization: true,
        ),
        tokens: tokensPath,
        modelType: 'sense_voice',
        numThreads: threadCount,
        debug: false,
      );

      final loadedRecognizer = sherpa_onnx.OfflineRecognizer(
        sherpa_onnx.OfflineRecognizerConfig(model: modelConfig),
      );

      if (_disposed) {
        debugPrint('[LocalSenseVoiceAsrService] 加载完成时实例已释放，回收识别器');
        loadedRecognizer.free();
        return;
      }

      _recognizer = loadedRecognizer;
      _isReady = true;
      debugPrint(
        '[LocalSenseVoiceAsrService] 初始化成功 (numThreads=$threadCount)',
      );
    } catch (e, st) {
      debugPrint('[LocalSenseVoiceAsrService] 初始化异常: $e\n$st');
      _isReady = false;
    }
  }

  @override
  Future<String> transcribeSamples(
    Float32List samples, {
    int sampleRate = 16000,
    bool isStandbyWakeCheck = false,
    bool fromVad = false,
  }) async {
    if (!_isReady) await initialize();
    if (_recognizer == null || samples.isEmpty) return '';

    // VAD 已经判定为有效语音时不再做能量门控，避免远场/轻声被二次误杀。
    if (!fromVad && isNearSilence(samples)) return '';

    try {
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      _recognizer!.decode(stream);
      final rawResult = _recognizer!.getResult(stream).text;
      stream.free();

      final cleaned = postProcessAsrText(
        rawResult,
        wakeContext: isStandbyWakeCheck,
      );
      debugPrint(
        '[LocalSenseVoiceAsrService] 识别完成 -> "$cleaned" (原始: "$rawResult")',
      );
      return cleaned;
    } catch (e, st) {
      debugPrint('[LocalSenseVoiceAsrService] 识别过程异常: $e\n$st');
      return '';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _recognizer?.free();
    _recognizer = null;
    _isReady = false;
  }
}

// ---------------------------------------------------------------------------
// 流式 Zipformer（内置 14M 小模型）
// ---------------------------------------------------------------------------

/// 基于 Sherpa-ONNX Zipformer 的流式识别服务。
///
/// 只使用仓库内置的 14M 小模型：
/// `assets/models/streaming-zipformer/encoder-epoch-99-avg-1.int8.onnx` 等。
class StreamingZipformerAsrService extends AsrService {
  @override
  final AppSettings settings;

  sherpa_onnx.OnlineRecognizer? _recognizer;
  Future<void>? _initFuture;
  bool _isReady = false;
  bool _disposed = false;

  StreamingZipformerAsrService({required this.settings});

  @override
  bool get isReady => _isReady;

  @override
  bool get isStreaming => true;

  @override
  String get engineName => 'Zipformer 流式';

  @override
  sherpa_onnx.OnlineRecognizer? get onlineRecognizer => _recognizer;

  @override
  sherpa_onnx.OnlineStream? createOnlineStream({String hotwords = ''}) {
    if (!_isReady || _recognizer == null) return null;
    try {
      if (hotwords.isNotEmpty) {
        final method = _recognizer!.config.decodingMethod;
        if (method == 'modified_beam_search') {
          return _recognizer!.createStream(hotwords: hotwords);
        }
        debugPrint(
          '[StreamingZipformerAsrService] decodingMethod=$method 不支持 hotwords，已忽略：$hotwords',
        );
      }
      return _recognizer!.createStream();
    } catch (e) {
      debugPrint('[StreamingZipformerAsrService] 创建在线流失败: $e');
      return null;
    }
  }

  @override
  Future<void> initialize() {
    if (_isReady) return Future.value();
    final existing = _initFuture;
    if (existing != null) return existing;
    _initFuture = _doInitialize().whenComplete(() {
      if (!_isReady) _initFuture = null;
    });
    return _initFuture!;
  }

  Future<void> _doInitialize() async {
    try {
      ensureSherpaBindings();
      await AsrPostProcessor.instance.ensureLoaded();

      final encoderPath = await resolveModelPath(
        'assets/models/streaming-zipformer/encoder-epoch-99-avg-1.int8.onnx',
        minBytes: 10000000,
      );
      final decoderPath = await resolveModelPath(
        'assets/models/streaming-zipformer/decoder-epoch-99-avg-1.onnx',
        minBytes: 100000,
      );
      final joinerPath = await resolveModelPath(
        'assets/models/streaming-zipformer/joiner-epoch-99-avg-1.int8.onnx',
        minBytes: 100000,
      );
      final tokensPath = await resolveModelPath(
        'assets/models/streaming-zipformer/tokens.txt',
        minBytes: 100,
      );

      if (encoderPath == null ||
          decoderPath == null ||
          joinerPath == null ||
          tokensPath == null) {
        debugPrint('[StreamingZipformerAsrService] 模型文件缺失，初始化中止');
        return;
      }

      final threadCount = _threadCount(max: 2);
      final modelConfig = sherpa_onnx.OnlineModelConfig(
        transducer: sherpa_onnx.OnlineTransducerModelConfig(
          encoder: encoderPath,
          decoder: decoderPath,
          joiner: joinerPath,
        ),
        tokens: tokensPath,
        modelType: 'zipformer',
        numThreads: threadCount,
        debug: false,
      );

      // modified_beam_search 才支持 hotwords；greedy_search 会静默丢弃偏置词。
      final recognizerConfig = sherpa_onnx.OnlineRecognizerConfig(
        model: modelConfig,
        decodingMethod: 'modified_beam_search',
        maxActivePaths: 4,
        hotwordsScore: 2.0,
        enableEndpoint: true,
        // 与 sherpa-onnx 默认量级对齐：避免换气处被误判断句。
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 1.2,
        rule3MinUtteranceLength: 20.0,
      );

      final loadedRecognizer = sherpa_onnx.OnlineRecognizer(recognizerConfig);
      if (_disposed) {
        loadedRecognizer.free();
        return;
      }

      _recognizer = loadedRecognizer;
      _isReady = true;
      debugPrint(
        '[StreamingZipformerAsrService] 初始化成功 (numThreads=$threadCount)',
      );
    } catch (e, st) {
      debugPrint('[StreamingZipformerAsrService] 初始化异常: $e\n$st');
      _isReady = false;
    }
  }

  @override
  Future<String> transcribeSamples(
    Float32List samples, {
    int sampleRate = 16000,
    bool isStandbyWakeCheck = false,
    bool fromVad = false,
  }) async {
    if (!_isReady) await initialize();
    if (_recognizer == null || samples.isEmpty) return '';
    if (!fromVad && isNearSilence(samples)) return '';

    try {
      final stream = _recognizer!.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      stream.inputFinished();
      while (_recognizer!.isReady(stream)) {
        _recognizer!.decode(stream);
      }
      final text = _recognizer!.getResult(stream).text.trim();
      stream.free();
      return postProcessAsrText(text, wakeContext: isStandbyWakeCheck);
    } catch (e, st) {
      debugPrint('[StreamingZipformerAsrService] 识别样本异常: $e\n$st');
      return '';
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _recognizer?.free();
    _recognizer = null;
    _isReady = false;
  }
}
