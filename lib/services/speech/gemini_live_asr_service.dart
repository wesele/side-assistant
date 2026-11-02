import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../core/platform/foundation_bridge.dart';
import 'asr_post_processor.dart';
import 'asr_service.dart';

/// Gemini 3.5 Transcribe Live 云端识别。
///
/// 该模型只支持 `bidiGenerateContent`（WebSocket 实时双向流），因此这里维护一条
/// 长连接：VAD 切出一段语音后，把整段 16k PCM 快速送上去，等待
/// `serverContent.inputTranscription` 作为最终文本。
///
/// 设计取舍：
/// - 不接管麦克风采集和 VAD，继续复用应用内已有的 Silero VAD / 预卷 / 尾垫 /
///   唤醒词 / 结束词流程，保证切换引擎时行为一致。
/// - 一次只处理一段语音（串行队列），避免多段音频在同一个 Live 会话里交错。
/// - 连接空闲被服务端关闭后，下一次识别会自动重连。
class GeminiLiveAsrService extends AsrService {
  @override
  final AppSettings settings;

  GeminiLiveAsrService({required this.settings});

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Future<void>? _connectFuture;
  Completer<void>? _setupCompleter;
  Completer<String>? _finalCompleter;
  Timer? _finishTimer;
  Timer? _hardFinishTimer;
  Future<void> _queue = Future<void>.value();

  /// 服务端会在连接空闲约 60s 后主动关闭（实测桌面端稳定在第 60s）。
  /// 与其等它关掉、等用户下一句开口时才补建连（那一句就要吃一次冷启动），
  /// 不如在接近阈值时主动重建，保证用户开口时永远有一条热连接。
  static const Duration _idleRefreshAfter = Duration(seconds: 45);
  Timer? _idleRefreshTimer;

  bool _isReady = false;
  bool _disposed = false;
  bool _generationDone = false;

  /// 是否已经发过 `audioStreamEnd`：只有发过之后，服务端的收尾信号才算整句结束。
  bool _audioEnded = false;
  bool _turnCompleteReceived = false;
  bool _needsReconnect = false;

  /// 本段音频发出后是否收到过任何服务端消息（用于区分“真的在识别”和“服务端根本没开轮次”）。
  bool _gotAnyTurnMessage = false;
  double _totalAudioSeconds = 0;
  final List<String> _completedTurns = <String>[];
  String _currentTurnFinalText = '';
  String _interimText = '';
  String? _lastError;
  int _connectionId = 0;

  // ---- 中间结果提前回调 ----
  // VAD 切段后，Gemini 会在最终结果之前先返回 interimInputTranscription。
  // 把这部分文本（防抖后）交给控制器，可以在“回答”刚被识别出来时就提交大模型，
  // 不必等 generationComplete / ACTIVITY_END 的完整收尾。
  bool _emitPartial = false;
  bool _currentWakeContext = false;
  String _lastEmittedPartial = '';
  Timer? _partialDebounceTimer;

  @override
  bool get isReady => _isReady;

  @override
  bool get isCloudStreaming => true;

  @override
  String get engineName => 'Gemini 3.5 Transcribe Live';

  /// Gemini 的云端实时 VAD 比本地 Silero 更“贪心”，但本地仍用 Silero 切段。
  /// 用户保持默认 0.50s 时，给云端识别降到 0.40s，减少说完“回答”后的固定等待；
  /// 用户手工改过尾静音则完全尊重用户值。
  @override
  double adjustVadMinSilence(double requested) {
    const tolerance = 0.001;
    if ((requested - AppConstants.defaultVadMinSilenceSeconds).abs() <
        tolerance) {
      return AppConstants.geminiVadMinSilenceSeconds;
    }
    return requested;
  }

  /// 最近一次连接/识别错误，便于 UI 或日志排查。
  String? get lastError => _lastError;

  String get _apiKey => settings.geminiApiKey.trim();

  String get _model {
    final raw = settings.geminiAsrModel.trim();
    final name = raw.isEmpty ? AppConstants.defaultGeminiAsrModel : raw;
    return name.startsWith('models/') ? name : 'models/$name';
  }

  /// 组装 Live 会话的 setup 消息。
  ///
  /// - 语言提示必须放在 `inputAudioTranscription.languageCodes`（BCP-47）里；
  ///   放到 setup 顶层或 `generationConfig.speechConfig` 都会被静默忽略。
  /// - 热词偏置放在 `inputAudioTranscription.customVocabulary` 里，把唤醒词、
  ///   结束词、重置词与领域词传给服务端解码器，提升触发词识别率且零时延损耗。
  @visibleForTesting
  static Map<String, dynamic> buildSetupMessage({
    required String model,
    String? languageCode,
    List<String>? customVocabulary,
  }) {
    final code = (languageCode ?? AppConstants.geminiAsrLanguageCode).trim();
    final vocab = <String>[
      if (customVocabulary != null)
        for (final word in customVocabulary)
          if (word.trim().isNotEmpty) word.trim(),
    ];
    return {
      'setup': {
        'model': model,
        'generationConfig': {
          'responseModalities': ['TEXT'],
        },
        'inputAudioTranscription': <String, dynamic>{
          if (code.isNotEmpty) 'languageCodes': <String>[code],
          if (vocab.isNotEmpty) 'customVocabulary': vocab,
        },
      },
    };
  }

  /// 从当前设置提取热词表（去重、去空），供 `customVocabulary` 偏置使用。
  List<String> _buildCustomVocabulary() {
    final words = <String>{
      ...settings.startWords,
      '晓漫',
      '小曼',
      ...settings.endWords,
      ...settings.resetWords,
      ...settings.exitContinuousWords,
      '侧边助手',
    };
    words.removeWhere((w) => w.trim().isEmpty);
    return words.toList(growable: false);
  }

  @override
  Future<void> initialize() {
    if (_disposed || _isReady) return Future<void>.value();
    final existing = _connectFuture;
    if (existing != null) return existing;

    // 连接失败一律转成 _lastError，不让异常逃逸成未处理的异步错误
    // （边说边传路径的 beginLiveUtterance 是 fire-and-forget 的）。
    final future = _connect().catchError((Object e, StackTrace st) {
      _lastError = e.toString();
      _isReady = false;
      debugPrint('[GeminiLiveAsrService] 连接异常: $e\n$st');
    });
    _connectFuture = future;
    return future.whenComplete(() {
      if (identical(_connectFuture, future)) _connectFuture = null;
    });
  }

  Future<void> _connect() async {
    if (_disposed) return;
    if (_apiKey.isEmpty) {
      _lastError = 'Gemini API Key 为空';
      debugPrint('[GeminiLiveAsrService] $_lastError');
      return;
    }

    _lastError = null;
    final connectionId = ++_connectionId;
    Completer<void>? setupCompleter;
    final connectStart = DateTime.now();

    try {
      await AsrPostProcessor.instance.ensureLoaded();
      await _closeSocket();
      if (_disposed) return;

      final uri = Uri.parse(
        '${AppConstants.geminiLiveWsUrl}?key=${Uri.encodeQueryComponent(_apiKey)}',
      );
      final connectFuture = WebSocket.connect(uri.toString());
      // 连接超时/被关闭后，底层 future 仍可能迟到一个错误。挂一个只吞异常的
      // 监听，避免它变成未处理的异步错误（测试环境会直接判失败）。
      unawaited(connectFuture.then<void>((_) {}, onError: (Object _) {}));
      final socket = await connectFuture.timeout(const Duration(seconds: 15));
      if (_disposed || connectionId != _connectionId) {
        await socket.close();
        return;
      }

      _socket = socket;
      _socketSub = socket.listen(
        (data) => _handleMessage(data, connectionId),
        onError: (Object error, StackTrace stackTrace) =>
            _handleSocketError(error, connectionId),
        onDone: () => _handleSocketDone(connectionId),
        cancelOnError: false,
      );

      setupCompleter = Completer<void>();
      _setupCompleter = setupCompleter;
      socket.add(
        jsonEncode(
          buildSetupMessage(
            model: _model,
            customVocabulary: _buildCustomVocabulary(),
          ),
        ),
      );

      await setupCompleter.future.timeout(const Duration(seconds: 15));
      if (_disposed || connectionId != _connectionId) return;

      _isReady = true;
      _lastError = null;
      _armIdleRefresh();
      debugPrint(
        '[GeminiLiveAsrService] 已连接云端模型: $_model '
        '(${DateTime.now().difference(connectStart).inMilliseconds}ms)',
      );
    } catch (e, st) {
      _lastError = e is StateError ? e.message : e.toString();
      _isReady = false;
      debugPrint('[GeminiLiveAsrService] 连接失败: $e\n$st');
      if (connectionId == _connectionId) {
        await _closeSocket();
      }
    } finally {
      if (identical(_setupCompleter, setupCompleter)) {
        _setupCompleter = null;
      }
    }
  }

  @override
  Future<String> transcribeSamples(
    Float32List samples, {
    int sampleRate = 16000,
    bool isStandbyWakeCheck = false,
    bool fromVad = false,
  }) {
    if (samples.isEmpty) return Future<String>.value('');
    if (!fromVad && isNearSilence(samples)) return Future<String>.value('');

    final normalized = sampleRate == 16000
        ? samples
        : _resample(samples, fromRate: sampleRate, toRate: 16000);

    return _enqueue(
      () => _transcribeNormalized(
        normalized,
        isStandbyWakeCheck,
        // 只对“已经唤醒后的 VAD 分段”回调中间结果：
        // - 待机态（isStandbyWakeCheck=true）不提前回调，避免半截唤醒词造成界面闪烁；
        // - 手动录音/文件识别（fromVad=false）不回调，避免与最终结果重复。
        emitPartial: fromVad && !isStandbyWakeCheck,
      ),
    );
  }

  Future<String> _enqueue(Future<String> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  // ---- 边说边传（Live 实时流） ----
  //
  // 分段的“存储转发”必须等 VAD 切完段才开始上传，说完到出字约 1.5s。
  // Live 模型本身支持边收边解码（RTF≈0.27），所以在 VAD 判定“正在说话”期间
  // 就按 1x 把音频推上去，说完时模型只差最后约 0.2s 的收尾。
  bool _liveRequested = false;
  bool _liveStarted = false;
  bool _liveWakeContext = false;
  int _liveTotalSamples = 0;
  final List<Float32List> _liveBuffer = <Float32List>[];
  Future<void>? _liveStartFuture;

  /// 上一段 turn 是否还在等最终文本；新的一段必须等它彻底收尾，
  /// 否则两段共用一条连接时 completer / 定时器会互相覆盖。
  Completer<void>? _turnIdle;

  Stopwatch? _turnStopwatch;

  @override
  bool get supportsLiveStreaming => true;

  @override
  void beginLiveUtterance(
    Float32List backfill, {
    bool isStandbyWakeCheck = false,
  }) {
    if (_disposed) return;
    _liveRequested = true;
    _liveStarted = false;
    _liveWakeContext = isStandbyWakeCheck;
    _liveTotalSamples = backfill.length;
    _liveBuffer
      ..clear()
      ..add(backfill);
    // fire-and-forget：无论成败都不能让异常变成未处理的异步错误。
    _liveStartFuture = _startLiveTurn().catchError((Object e, StackTrace st) {
      _lastError = e.toString();
      debugPrint('[GeminiLiveAsrService] 边说边传启动异常: $e\n$st');
    });
  }

  Future<void> _startLiveTurn() async {
    if (_disposed) return;

    final ok = await _beginTurn(
      wakeContext: _liveWakeContext,
      emitPartial: !_liveWakeContext,
      totalSamples: _liveTotalSamples,
    );
    if (!ok) return;

    try {
      // 补发积压音频时按 10x 节奏送：一次性灌入过快服务端会收不到尾。
      // 这段时间用户通常还在说话，不影响“说完到出字”。
      while (_liveBuffer.isNotEmpty) {
        await _sendPaced(_liveBuffer.removeAt(0));
      }
      _totalAudioSeconds = _liveTotalSamples / 16000.0;
      _liveStarted = true;
      debugPrint(
        '[GeminiLiveAsrService] 边说边传开流 (累计 ${_liveTotalSamples ~/ 16}ms)',
      );
    } catch (e, st) {
      _lastError = e.toString();
      debugPrint('[GeminiLiveAsrService] 边说边传启动失败: $e\n$st');
      _endTurn();
    }
  }

  @override
  void appendLiveAudio(Float32List samples) {
    if (_disposed || !_liveRequested || samples.isEmpty) return;
    _liveTotalSamples += samples.length;
    if (_liveStarted) {
      _totalAudioSeconds = _liveTotalSamples / 16000.0;
      _sendChunk(samples);
      return;
    }
    _liveBuffer.add(Float32List.fromList(samples));
    var total = 0;
    for (final chunk in _liveBuffer) {
      total += chunk.length;
    }
    while (total > 35 * 16000 && _liveBuffer.length > 1) {
      total -= _liveBuffer.removeAt(0).length;
    }
  }

  @override
  Future<String?> endLiveUtterance() async {
    if (_disposed) return null;
    final wakeContext = _liveWakeContext;
    _liveRequested = false;
    final start = _liveStartFuture;
    _liveStartFuture = null;
    if (start != null) {
      try {
        await start;
      } catch (_) {}
    }
    if (!_liveStarted) return null;
    _liveStarted = false;
    return _finishLiveTurn(wakeContext: wakeContext);
  }

  Future<String?> _finishLiveTurn({required bool wakeContext}) async {
    try {
      final raw = await _awaitFinal();
      return _finalizeText(raw, wakeContext: wakeContext);
    } catch (e, st) {
      _lastError = e.toString();
      debugPrint('[GeminiLiveAsrService] 边说边传收尾失败: $e\n$st');
      final partial = _combinedText();
      if (partial.isEmpty) return null;
      final cleaned = _finalizeText(partial, wakeContext: wakeContext);
      return cleaned.isEmpty ? null : cleaned;
    } finally {
      _endTurn();
    }
  }

  /// 开始一段 turn：等上一段收尾、确保连接就绪、重置状态。
  Future<bool> _beginTurn({
    required bool wakeContext,
    required bool emitPartial,
    required int totalSamples,
  }) async {
    if (_disposed) return false;

    // 一段开始就不再需要空闲保活，等本段收尾后由 _endTurn 重新计时。
    _idleRefreshTimer?.cancel();
    _idleRefreshTimer = null;

    final idle = _turnIdle;
    if (idle != null) {
      try {
        await idle.future.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        // 上一段迟迟收不了尾（服务端不吐收尾信号）：强制释放并换一条连接，
        // 否则本段音频会被塞进一条状态混乱的 socket，表现为超时/空结果。
        debugPrint('[GeminiLiveAsrService] 上一段收尾超时，强制重置换连接');
        _endTurn();
        _needsReconnect = true;
      }
    }
    if (_disposed) return false;

    // 上一段在 turnComplete 之前就被兜底收尾时，连接里可能残留未结束的 turn。
    // 直接复用会让下一段一直等不到 generationComplete，因此先主动重连。
    if (_needsReconnect) {
      _needsReconnect = false;
      await _closeSocket();
    }

    if (!_isReady || _socket == null) {
      await initialize();
    }
    if (!_isReady || _socket == null) return false;

    _turnIdle = Completer<void>();
    _audioEnded = false;
    _completedTurns.clear();
    _currentTurnFinalText = '';
    _interimText = '';
    _generationDone = false;
    _turnCompleteReceived = false;
    _gotAnyTurnMessage = false;
    _totalAudioSeconds = totalSamples / 16000.0;
    _emitPartial = emitPartial;
    _currentWakeContext = wakeContext;
    _lastEmittedPartial = '';
    _partialDebounceTimer?.cancel();
    _partialDebounceTimer = null;
    _finishTimer?.cancel();
    _finishTimer = null;
    _hardFinishTimer?.cancel();
    _hardFinishTimer = null;
    _turnStopwatch = Stopwatch()..start();
    _finalCompleter = Completer<String>();
    return true;
  }

  static const int _bytesPerChunk = 1600 * 2; // 100ms @ 16kHz PCM16

  static String _encodePcmChunkMessage(Uint8List pcm, int offset, int end) {
    return jsonEncode({
      'realtimeInput': {
        'audio': {
          'mimeType': 'audio/pcm;rate=16000',
          'data': base64Encode(Uint8List.sublistView(pcm, offset, end)),
        },
      },
    });
  }

  /// 发送一段 16k 音频（同步，供边说边传使用）。
  void _sendChunk(Float32List samples) {
    final socket = _socket;
    if (socket == null || !_isReady || samples.isEmpty) return;
    if (_finalCompleter == null) return;

    final pcm = _float32ToPcm16(samples);
    for (var offset = 0; offset < pcm.length; offset += _bytesPerChunk) {
      final end = math.min(offset + _bytesPerChunk, pcm.length);
      socket.add(_encodePcmChunkMessage(pcm, offset, end));
    }
  }

  /// 按约 10x 实时发送一段音频（补发积压时用）。
  Future<void> _sendPaced(Float32List samples) async {
    final pcm = _float32ToPcm16(samples);
    for (var offset = 0; offset < pcm.length; offset += _bytesPerChunk) {
      final socket = _socket;
      if (socket == null || !_isReady) return;
      final end = math.min(offset + _bytesPerChunk, pcm.length);
      socket.add(_encodePcmChunkMessage(pcm, offset, end));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// 发送 audioStreamEnd 并等待最终文本。
  Future<String> _awaitFinal() async {
    final socket = _socket;
    final completer = _finalCompleter;
    if (socket == null || completer == null) {
      throw StateError('Gemini WebSocket 已断开');
    }
    socket.add(jsonEncode({
      'realtimeInput': {'audioStreamEnd': true},
    }));
    _audioEnded = true;

    // 服务端偶尔会只给 interim、不给 generationComplete（实测连续第二段时出现过），
    // 此时不能傻等 15s 超时。用“静默 4s”兜底：只要还在收到 interim 就重置计时，
    // 真正没消息了才用累计文本返回。
    // 首个兜底窗用更短的 1.5s：环境噪音误触发 VAD 时，服务端根本不会开轮次、
    // 一个字节都不回，等满 4s 纯属浪费，还会把后面真正说话的那一轮挤住。
    _armHardFinishTimer(first: true);

    final timeout = Duration(
      milliseconds: math.max(
        15000,
        _totalAudioSeconds.round() * 1000 + 10000,
      ),
    );
    return completer.future.timeout(timeout);
  }

  String _finalizeText(String raw, {required bool wakeContext}) {
    _turnStopwatch?.stop();
    final cleaned = _normalizeChineseSpacing(
      postProcessAsrText(raw, wakeContext: wakeContext),
    );
    if (cleaned.isEmpty) return '';
    if (!isChineseLike(cleaned)) {
      debugPrint(
        '[GeminiLiveAsrService] 丢弃非中文识别结果 '
        '(${_totalAudioSeconds.toStringAsFixed(2)}s): "$cleaned"',
      );
      return '';
    }
    debugPrint(
      '[GeminiLiveAsrService] 识别完成 '
      '(${_totalAudioSeconds.toStringAsFixed(2)}s 音频, '
      '耗时 ${_turnStopwatch?.elapsedMilliseconds ?? 0}ms): "$cleaned"',
    );
    return cleaned;
  }

  void _endTurn() {
    _finalCompleter = null;
    _finishTimer?.cancel();
    _finishTimer = null;
    _hardFinishTimer?.cancel();
    _hardFinishTimer = null;
    _partialDebounceTimer?.cancel();
    _partialDebounceTimer = null;
    _emitPartial = false;
    _currentWakeContext = false;
    _lastEmittedPartial = '';
    _turnStopwatch?.stop();
    final idle = _turnIdle;
    _turnIdle = null;
    if (idle != null && !idle.isCompleted) idle.complete();
    if (_isReady && !_disposed) _armIdleRefresh();
  }

  /// 重新计时“空闲保活”：到点后主动重建连接，避免被服务端的 60s 空闲超时踢掉。
  void _armIdleRefresh() {
    _idleRefreshTimer?.cancel();
    _idleRefreshTimer = Timer(_idleRefreshAfter, () {
      _idleRefreshTimer = null;
      unawaited(_refreshIdleConnection());
    });
  }

  Future<void> _refreshIdleConnection() async {
    if (_disposed) return;
    // 正在处理语音或上一段还没收尾就跳过，等收尾后再重新计时。
    if (_finalCompleter != null || _liveRequested || _turnIdle != null) {
      if (_isReady) _armIdleRefresh();
      return;
    }
    debugPrint('[GeminiLiveAsrService] 空闲保活：主动重建连接');
    await _closeSocket();
    if (_disposed) return;
    _needsReconnect = false;
    await initialize();
    if (_isReady && !_disposed) _armIdleRefresh();
  }

  Future<String> _transcribeNormalized(
    Float32List samples,
    bool wakeContext, {
    required bool emitPartial,
  }) async {
    final ok = await _beginTurn(
      wakeContext: wakeContext,
      emitPartial: emitPartial,
      totalSamples: samples.length,
    );
    if (!ok) return '';

    final socket = _socket;
    try {
      if (socket == null) throw StateError('Gemini WebSocket 已断开');
      final pcm = _float32ToPcm16(samples);

      for (var offset = 0; offset < pcm.length; offset += _bytesPerChunk) {
        if (_disposed || _socket != socket) {
          throw StateError('Gemini WebSocket 已断开');
        }
        final end = math.min(offset + _bytesPerChunk, pcm.length);
        socket.add(_encodePcmChunkMessage(pcm, offset, end));

        // Gemini Live 内部有实时 VAD：把整段音频在零间隔内一次性灌进去时，
        // 实测只会返回 interim、不会收尾（generationComplete 迟迟不来）。
        // 因此必须按节奏发送。这里写 10ms/100ms，但 Windows 定时器粒度约
        // 15.6ms，实际约 6.4 倍实时（5.6s 音频约 0.88s 传完）。
        //
        // 实测（tool/probes/gemini_timing_probe.dart）再快也没有收益：20 倍实时时上传
        // 只要 0.44s，但模型要等音频到齐后才追上，从“首字节到最终文本”始终约
        // 1.5s；40 倍以上会直接收不到 generationComplete。真正的提速手段是
        // “边说边传”（VoiceListeningService 的 live 路径），而不是压这段节奏。
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      final raw = await _awaitFinal();
      return _finalizeText(raw, wakeContext: wakeContext);
    } catch (e, st) {
      _lastError = e.toString();
      debugPrint('[GeminiLiveAsrService] 识别失败: $e\n$st');
      // 超时/断线后不复用这条连接，避免上一段的迟到消息污染下一段。
      // 但已经拿到的部分文本仍然有价值（尤其是长录音收尾超时）。
      final partial = _combinedText();
      final completer = _finalCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(partial);
      }
      await _closeSocket();
      if (partial.isEmpty) return '';
      return _finalizeText(partial, wakeContext: wakeContext);
    } finally {
      _endTurn();
    }
  }

  void _handleMessage(dynamic raw, int connectionId) {
    if (_disposed || connectionId != _connectionId) return;

    // Gemini Live 的响应有时以二进制帧返回（dart:io 会给出 List<int>），
    // 需要先按 UTF-8 解码，不能只处理 String。
    String? text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int>) {
      try {
        text = utf8.decode(raw);
      } catch (_) {
        return;
      }
    }
    if (text == null || text.isEmpty) return;

    Map<String, dynamic> message;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return;
      message = decoded;
    } catch (_) {
      return;
    }

    // 每收到一条服务端消息就重置“静默兜底”计时：模型还在持续吐 interim 时
    // 不要提前截断；只有长时间完全没有消息才收尾。
    if (_finalCompleter != null) _gotAnyTurnMessage = true;
    _armHardFinishTimer();

    if (message.containsKey('setupComplete')) {
      _completeSetup();
      return;
    }

    // 转写模型单条会话上限约 10 分钟，到点前服务端会发 goAway 再关闭。
    // 空闲时主动收掉连接，避免下一段音频写进一条正在关闭的 socket 里。
    final goAway = message['goAway'];
    if (goAway is Map) {
      debugPrint('[GeminiLiveAsrService] 服务端即将断开: $goAway');
      _needsReconnect = true;
      if (_finalCompleter == null) {
        unawaited(_closeSocket());
      }
      return;
    }

    final error = message['error'];
    if (error != null) {
      final text = error is Map
          ? (error['message']?.toString() ?? error.toString())
          : error.toString();
      _lastError = text;
      debugPrint('[GeminiLiveAsrService] 服务端错误: $text');
      _completeSetup(Exception(text));
      _failPending(Exception(text));
      return;
    }

    final voiceActivity = message['voiceActivity'];
    if (voiceActivity is Map && voiceActivity['type'] == 'ACTIVITY_START') {
      // 新的一段语音开始：把上一段的最终文本归档，继续累积。
      if (_currentTurnFinalText.isNotEmpty) {
        _completedTurns.add(_currentTurnFinalText);
        _currentTurnFinalText = '';
      }
      _interimText = '';
      _generationDone = false;
      _turnCompleteReceived = false;
      _finishTimer?.cancel();
      _finishTimer = null;
    }

    final serverContent = message['serverContent'];
    if (serverContent is! Map) return;

    final interim = serverContent['interimInputTranscription'];
    if (interim is Map && interim['text'] is String) {
      // 若上一段子轮次已经收到过最终文本（inputTranscription），说明当前
      // interim 属于新的子轮次（即使服务端未先发 ACTIVITY_START），先归档上一段。
      if (_currentTurnFinalText.isNotEmpty) {
        _completedTurns.add(_currentTurnFinalText);
        _currentTurnFinalText = '';
      }
      _interimText = interim['text'] as String;
      _schedulePartialEmit();
    }

    final finalTranscription = serverContent['inputTranscription'];
    if (finalTranscription is Map && finalTranscription['text'] is String) {
      final text = finalTranscription['text'] as String;
      if (text.isNotEmpty) {
        // 同一个 turn 内如果收到修订版，用最新版本覆盖而不是重复追加。
        _currentTurnFinalText = text;
        _interimText = '';
        _schedulePartialEmit();
      }
    }

    if (serverContent['turnComplete'] == true) {
      _turnCompleteReceived = true;
      debugPrint('[GeminiLiveAsrService] 收到 turnComplete');
    }

    if (serverContent['generationComplete'] == true ||
        serverContent['turnComplete'] == true) {
      _generationDone = true;
      // 边说边传阶段（还没发 audioStreamEnd）服务端也可能给收尾信号——
      // 那是它内部 VAD 的一段结束，不是整句结束，不能提前收尾。
      if (!_audioEnded) return;
      if (_turnCompleteReceived || _hasFinalTranscript) {
        _finishNow();
      } else {
        // generationComplete 到了但最终转写还没到：给服务端 250ms 补发，
        // 避免下一段复用连接时卡住。
        _scheduleFinishGrace();
      }
    }
  }

  /// 最终转写是否已经到齐。
  ///
  /// 实测（`tool/probes/gemini_timing_probe.dart`）`inputTranscription` 与
  /// `generationComplete` 在同一批消息里到达，且 `turnComplete` 在转写模型上
  /// 根本不会出现。因此只要最终文本已经在手，就没必要再等 250ms 收尾宽限。
  bool get _hasFinalTranscript => _currentTurnFinalText.isNotEmpty;

  void _scheduleFinishGrace() {
    _finishTimer?.cancel();
    _finishTimer = Timer(const Duration(milliseconds: 250), _finishNow);
  }

  /// 中间结果防抖：等 40ms 没有新的 interim 再回调，兼顾结束词极速触发与
  /// 避免在同一微秒批次里重复触发控制器。
  void _schedulePartialEmit() {
    if (!_emitPartial || _currentWakeContext || onPartialText == null) return;

    _partialDebounceTimer?.cancel();
    _partialDebounceTimer = Timer(const Duration(milliseconds: 40), () {
      _partialDebounceTimer = null;
      _emitPartialNow();
    });
  }

  void _emitPartialNow() {
    final callback = onPartialText;
    if (!_emitPartial || _currentWakeContext || callback == null) return;

    final raw = combineSubTurns(
      completedTurns: _completedTurns,
      currentTurnFinalText: _currentTurnFinalText,
      interimText: _interimText,
    ).trim();
    if (raw.isEmpty) return;

    final cleaned = _normalizeChineseSpacing(
      postProcessAsrText(raw, wakeContext: false),
    );
    if (cleaned.isEmpty || cleaned == _lastEmittedPartial) return;
    if (!isChineseLike(cleaned)) {
      debugPrint('[GeminiLiveAsrService] 丢弃非中文中间结果: "$cleaned"');
      return;
    }

    _lastEmittedPartial = cleaned;
    debugPrint('[GeminiLiveAsrService] 中间结果: "$cleaned"');
    callback(cleaned);
  }

  String _combinedText() {
    return combineSubTurns(
      completedTurns: _completedTurns,
      currentTurnFinalText: _currentTurnFinalText,
      interimText: _interimText,
    );
  }

  /// 合并同一段语音内的多个服务端 VAD 子轮次文本。
  ///
  /// - 必须把 [_completedTurns]（已归档的前半句）与当前子轮次一并拼接，避免用户
  ///   在说“回答”前轻微换气时，中间结果或最终结果只剩“回答”而丢掉前半句提问；
  /// - 若整段里已经有中文子句，则保留穿插其中的短英文词（如 "Spotify"）或数字
  ///   子句（如 "123"），仅剔除假名/韩文或超过 3 个单词的纯外语背景串音。
  @visibleForTesting
  static String combineSubTurns({
    required List<String> completedTurns,
    required String currentTurnFinalText,
    required String interimText,
  }) {
    final candidates = <String>[
      for (final turn in completedTurns)
        if (turn.trim().isNotEmpty) turn,
      if (currentTurnFinalText.trim().isNotEmpty)
        currentTurnFinalText
      else if (interimText.trim().isNotEmpty)
        interimText,
    ];
    if (candidates.isEmpty) return '';

    final anyChinese = candidates.any(isChineseLike);
    if (!anyChinese) return '';

    final filtered = <String>[
      for (final seg in candidates)
        if (!_isForeignNoiseTurn(seg)) seg,
    ];
    return filtered.join();
  }

  static bool _isForeignNoiseTurn(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return true;
    if (isChineseLike(trimmed)) return false;
    if (_kanaRegExp.hasMatch(trimmed) || _hangulRegExp.hasMatch(trimmed)) {
      return true;
    }
    final latinWords = RegExp(r'[A-Za-zÀ-ÿ]+').allMatches(trimmed).length;
    return latinWords > 3;
  }

  static final RegExp _hanRegExp = RegExp(
    r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF]',
  );
  static final RegExp _kanaRegExp = RegExp(r'[\u3040-\u30FF]');
  static final RegExp _hangulRegExp = RegExp(r'[\uAC00-\uD7AF]');

  /// 判断识别结果是否“像中文”。
  ///
  /// Gemini 是自动语种检测的多语种模型（官方支持 85+ 语种与中英混说），
  /// `inputAudioTranscription.languageCodes` 只是偏置：实测它能稳定把粤语转成
  /// 普通话，但不会阻止模型把环境里的西语/日语/韩语原样转写出来。
  /// 语音助手只接受中文指令，因此这里做结果侧过滤：
  /// - 至少要有汉字；
  /// - 日文假名或韩文数量不能超过汉字数量（避免把日/韩语句子当成中文）；
  /// - 中英混说（如“打开 Spotify”）仍然保留，因为汉字存在且没有假名/韩文。
  @visibleForTesting
  static bool isChineseLike(String text) {
    if (text.trim().isEmpty) return false;
    final han = _hanRegExp.allMatches(text).length;
    if (han == 0) return false;
    final kana = _kanaRegExp.allMatches(text).length;
    final hangul = _hangulRegExp.allMatches(text).length;
    return kana <= han && hangul <= han;
  }

  static final RegExp _chineseSpacingRegExp = RegExp(
    r'([\u4E00-\u9FFF])\s+(?=[\u4E00-\u9FFF])',
  );

  /// 去掉汉字之间由 interim 带出的空格（“开放 时间” -> “开放时间”）。
  /// 中英混说时保留英文单词之间的空格。
  @visibleForTesting
  static String normalizeChineseSpacing(String text) {
    return text.replaceAllMapped(_chineseSpacingRegExp, (match) => match[1]!);
  }

  static String _normalizeChineseSpacing(String text) =>
      normalizeChineseSpacing(text);

  void _armHardFinishTimer({bool first = false}) {
    // 边说边传阶段（还没发 audioStreamEnd）不能武装收尾兜底：
    // 用户还没说完，中断在途的 turn 会把整句切成两半。
    if (!_audioEnded) return;
    if (_finalCompleter == null) return;
    _hardFinishTimer?.cancel();
    final wait = first && !_gotAnyTurnMessage
        ? const Duration(milliseconds: 1500)
        : const Duration(seconds: 4);
    _hardFinishTimer = Timer(wait, () {
      _hardFinishTimer = null;
      if (_finalCompleter == null) return;
      debugPrint('[GeminiLiveAsrService] 收尾静默超时兜底，使用已累计文本');
      _finishNow();
    });
  }

  void _finishNow() {
    _finishTimer?.cancel();
    _finishTimer = null;
    _hardFinishTimer?.cancel();
    _hardFinishTimer = null;
    _partialDebounceTimer?.cancel();
    _partialDebounceTimer = null;

    final completer = _finalCompleter;
    if (completer == null || completer.isCompleted) return;
    _finalCompleter = null;
    if (!_turnCompleteReceived && !_generationDone && _gotAnyTurnMessage) {
      // 服务端回过内容却没给出收尾（真的开过轮次）：连接里可能还有未结束的 turn，
      // 下一段必须换一条连接。若整段一个消息都没收到（多半是噪音误触发、服务端
      // 根本没开轮次），复用即可，不必白白付一次重连。
      _needsReconnect = true;
      debugPrint('[GeminiLiveAsrService] 未收到 generationComplete，下一段将重连');
    } else if (!_turnCompleteReceived && !_generationDone) {
      debugPrint('[GeminiLiveAsrService] 本段服务端无任何响应（疑似噪音误触发），保留连接');
    }
    completer.complete(_combinedText());
  }

  void _failPending(Object error) {
    _finishTimer?.cancel();
    _finishTimer = null;

    final completer = _finalCompleter;
    _finalCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  void _completeSetup([Object? error]) {
    final completer = _setupCompleter;
    if (completer == null || completer.isCompleted) return;
    if (error == null) {
      completer.complete();
    } else {
      completer.completeError(error);
    }
  }

  void _handleSocketError(Object error, int connectionId) {
    if (connectionId != _connectionId) return;
    _lastError = error is StateError ? error.message : error.toString();
    debugPrint('[GeminiLiveAsrService] WebSocket 错误: $error');
    _isReady = false;
    _socket = null;
    _socketSub = null;
    _completeSetup(error);
    _failPending(error);
  }

  void _handleSocketDone(int connectionId) {
    if (connectionId != _connectionId) return;
    debugPrint('[GeminiLiveAsrService] WebSocket 已关闭');
    final wasConnecting = _setupCompleter != null;
    final message =
        wasConnecting ? '连接被服务端关闭，请检查 API Key、模型名与网络' : 'Gemini WebSocket 已关闭';
    if (_lastError == null || wasConnecting) {
      _lastError = message;
    }
    _isReady = false;
    _socket = null;
    _socketSub = null;
    final error = StateError(message);
    _completeSetup(error);
    _failPending(error);
  }

  Future<void> _closeSocket() async {
    _isReady = false;
    _idleRefreshTimer?.cancel();
    _idleRefreshTimer = null;
    _finishTimer?.cancel();
    _finishTimer = null;
    _hardFinishTimer?.cancel();
    _hardFinishTimer = null;
    _partialDebounceTimer?.cancel();
    _partialDebounceTimer = null;
    _emitPartial = false;
    final sub = _socketSub;
    final socket = _socket;
    _socketSub = null;
    _socket = null;

    _failPending(StateError('Gemini WebSocket 已关闭'));
    _completeSetup(StateError('Gemini WebSocket 已关闭'));

    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      await socket?.close();
    } catch (_) {}
  }

  static Uint8List _float32ToPcm16(Float32List samples) {
    final bytes = Uint8List(samples.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0).toDouble();
      data.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
    }
    return bytes;
  }

  static Float32List _resample(
    Float32List input, {
    required int fromRate,
    required int toRate,
  }) {
    if (input.isEmpty || fromRate == toRate || fromRate <= 0 || toRate <= 0) {
      return input;
    }
    final outLength = (input.length * toRate / fromRate).round();
    final output = Float32List(outLength);
    final ratio = fromRate / toRate;
    for (var i = 0; i < outLength; i++) {
      final position = i * ratio;
      final index = position.floor();
      final next = math.min(index + 1, input.length - 1);
      final fraction = position - index;
      output[i] = input[index] * (1 - fraction) + input[next] * fraction;
    }
    return output;
  }

  @override
  void dispose() {
    _disposed = true;
    _connectionId++;
    _liveRequested = false;
    _liveStarted = false;
    _liveBuffer.clear();
    _idleRefreshTimer?.cancel();
    _idleRefreshTimer = null;
    _finishTimer?.cancel();
    _finishTimer = null;
    _hardFinishTimer?.cancel();
    _hardFinishTimer = null;
    _partialDebounceTimer?.cancel();
    _partialDebounceTimer = null;
    _emitPartial = false;
    _currentWakeContext = false;
    _failPending(StateError('Gemini ASR 已释放'));
    _completeSetup(StateError('Gemini ASR 已释放'));
    final idle = _turnIdle;
    _turnIdle = null;
    if (idle != null && !idle.isCompleted) idle.complete();

    final sub = _socketSub;
    final socket = _socket;
    _socketSub = null;
    _socket = null;
    _isReady = false;

    unawaited(sub?.cancel() ?? Future<void>.value());
    try {
      socket?.close();
    } catch (_) {}
  }
}
