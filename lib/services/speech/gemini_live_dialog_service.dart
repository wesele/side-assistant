import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/models/app_settings.dart';
import '../../core/models/camera_capture_result.dart';
import '../../core/models/chat_message.dart';
import '../../core/models/gemini_live_key_pool.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/pcm_stream_player_bridge.dart';
import '../../core/ports/gemini_live_session_port.dart';
import '../../core/ports/knowledge_port.dart';
import '../lightrag/lightrag_service.dart';
import '../llm/tools/custom_tool_manager.dart';
import 'support/gemini_live_capabilities.dart';
import 'support/gemini_live_dialog_preview.dart';
import 'support/gemini_live_dialog_protocol.dart';
import 'support/gemini_live_dialog_setup.dart';
import 'support/gemini_live_key_rotator.dart';
import 'support/gemini_live_pcm.dart';
import 'support/gemini_live_tool_executor.dart';

/// Gemini 3.8 Live 端到端全双工语音对话服务 (BidiGenerateContent)
///
/// 特性：16k/24k PCM 实时双向流、毫秒打断、双向字幕、内置工具链、长连接无感续期。
class GeminiLiveDialogService implements GeminiLiveSessionPort {
  AppSettings settings;
  final bool _isPreview;
  final PlatformPcmStreamPlayer _pcmPlayer;
  KnowledgePort? _lightRagService;
  final CustomToolManager _customToolManager;
  final Future<WebSocket> Function(String url)? _webSocketConnector;
  final GeminiLiveKeyRotator _keyRotator;

  @override
  void Function(String text, {required bool isFinal})? onInputTranscription;
  @override
  void Function(String deltaText, String fullText, {required bool isFinal})?
      onOutputTranscription;
  @override
  void Function(Uint8List pcm24kBytes)? onAudioOutputChunk;
  @override
  void Function()? onModelTurnStarted;
  @override
  void Function()? onTurnCompleted;
  @override
  void Function()? onInterrupted;
  @override
  void Function(String thought)? onThought;
  @override
  void Function(bool inProgress)? onInteractionStatus;
  @override
  void Function(List<String> ids)? onToolCallsCancelled;
  @override
  void Function(String statusHint)? onStatusHintChanged;
  @override
  Future<CameraCaptureResult?> Function()? onCapturePhoto;
  @override
  void Function(String toolName, String query)? onToolCall;
  @override
  void Function(String text, String reason)? onBackgroundSpeechDetected;

  /// 服务端协议错误通知回调
  void Function(String message)? onServerError;

  late final GeminiLiveDialogProtocol _protocol = GeminiLiveDialogProtocol(
    activeConnectionId: () => _connectionId,
    onSetupComplete: _handleSetupComplete,
    onServerError: _handleServerError,
    onGoAway: _handleGoAway,
    onSessionResumptionUpdate: (handle) => _sessionResumptionHandle = handle,
    onInterrupted: _handleInterrupted,
    onAudioChunk: _handleAudioOutputChunk,
    onInputTranscript: (text, {required isFinal}) =>
        _handleProtocolInputTranscript(text, isFinal: isFinal),
    onOutputTranscript: (delta, full, {required isFinal}) {
      if (_suppressCurrentTurnAudio) return;
      onOutputTranscription?.call(delta, full, isFinal: isFinal);
    },
    onModelTurnStarted: _handleModelTurnStarted,
    onTurnComplete: _handleProtocolTurnComplete,
    onToolCalls: (calls) => unawaited(_executeToolCalls(calls)),
    onThought: (thought) => onThought?.call(thought),
    onToolCallsCancelled: _handleToolCallsCancelled,
    onInteractionStatus: (status) =>
        onInteractionStatus?.call(status.toUpperCase() == 'IN_PROGRESS'),
    onUsageMetadata: _handleUsageMetadata,
  );

  late final GeminiLiveToolExecutor _toolExecutor = GeminiLiveToolExecutor(
    getSettings: () => settings,
    pcmPlayer: _pcmPlayer,
    getLightRagService: () => _lightRagService,
    refreshLightRagService: _refreshLightRagService,
    customToolManager: _customToolManager,
    getCapturePhoto: () => onCapturePhoto,
    getOnToolCall: () => onToolCall,
    getOnBackgroundSpeechDetected: () => onBackgroundSpeechDetected,
    onSuppressCurrentTurnAudio: (suppress) {
      if (suppress) {
        _activateBackgroundSuppression(_protocol.currentInputText);
      } else {
        _clearBackgroundSuppression();
      }
    },
  );

  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSub;
  Future<bool>? _connectFuture;
  Completer<void>? _setupCompleter;
  Timer? _reconnectTimer;
  Timer? _turnCompleteDrainTimer;

  bool _isReady = false;
  bool _active = false;
  bool _disposed = false;
  bool _suppressCurrentTurnAudio = false;
  bool _awaitingSuppressedPostToolTurn = false;
  bool _backgroundTurnCompletedEmitted = false;
  String _suppressedBackgroundText = '';
  DateTime? _suppressedBackgroundAt;
  bool _inModelTurn = false;
  bool _handshakeSucceeded = false;
  int _connectionId = 0;
  final Set<String> _pendingToolCallIds = <String>{};
  final Set<String> _cancelledToolCallIds = <String>{};
  int get _pendingToolCalls => _pendingToolCallIds.length;
  String? _lastError;
  String? _sessionResumptionHandle;
  List<ChatMessage> _pendingHistoryToSeed = const [];
  DateTime _playbackEchoTailUntil = DateTime(0);
  DateTime _bargeInSuppressPlaybackUntil = DateTime(0);
  bool get _isConnected => _isReady && _socket != null && !_disposed;

  // 16kHz PCM 微帧发送聚合缓冲（960 字节 = 480 采样 = 30ms）
  static const int _minSendBytes = 960;
  static const int _maxChunkBytes = 3200;
  final BytesBuilder _outgoingPcmBuffer = BytesBuilder(copy: false);

  GeminiLiveDialogService({
    required this.settings,
    bool isPreview = false,
    PlatformPcmStreamPlayer? pcmPlayer,
    KnowledgePort? lightRagService,
    CustomToolManager? customToolManager,
    Future<WebSocket> Function(String url)? webSocketConnector,
    GeminiLiveKeyPool? keyPool,
  })  : _isPreview = isPreview,
        _pcmPlayer = pcmPlayer ?? PlatformPcmStreamPlayer(),
        _lightRagService = lightRagService,
        _customToolManager = customToolManager ?? CustomToolManager.instance,
        _webSocketConnector = webSocketConnector,
        _keyRotator = GeminiLiveKeyRotator(keyPool: keyPool) {
    _refreshLightRagService();
  }

  /// 注册为全系统默认的 GeminiLiveSessionPort 工厂
  static void registerDefault() =>
      GeminiLiveSessionFactoryRegistry.defaultFactory =
          (settings) => GeminiLiveDialogService(settings: settings);

  void _refreshLightRagService() {
    if (settings.enableLightRag && settings.lightRagBaseUrl.trim().isNotEmpty) {
      _lightRagService ??= LightRagService(baseUrl: settings.lightRagBaseUrl);
    }
  }

  @override
  bool get isReady => _isReady;
  @override
  bool get isActive => _active;
  @override
  bool get isSpeakingOutput => _pcmPlayer.isPlaying;
  @override
  bool get isAdvancedMode => GeminiLiveCapabilities.resolveAdvanced(
        mode: settings.geminiLiveAdvancedMode,
        model: GeminiLiveDialogSetup.model(settings),
      );
  @override
  String? get lastError => _lastError;
  String? get activeApiKey => _keyRotator.currentApiKey;

  @override
  Future<bool> connect() {
    if (_disposed) return Future<bool>.value(false);
    _active = true;
    if (_isReady && _socket != null) return Future<bool>.value(true);
    final existing = _connectFuture;
    if (existing != null) return existing;

    final future = _doConnect().catchError((Object e, StackTrace st) {
      _onConnectFailure(e, st);
      return false;
    });
    _connectFuture = future;
    return future.whenComplete(() {
      if (identical(_connectFuture, future)) _connectFuture = null;
    });
  }

  void _onConnectFailure(Object e, StackTrace st) {
    _lastError = e is StateError ? e.message : e.toString();
    _isReady = false;
    debugPrint('[GeminiLiveDialogService] 握手失败: $e\n$st');
    if (_active &&
        !_disposed &&
        _reconnectTimer == null &&
        !_keyRotator.switchingKey) {
      _scheduleReconnect();
    }
  }

  Future<bool> _doConnect() async {
    if (_disposed) return false;
    final pool = _keyRotator.resolvePool(settings);
    if (pool.isEmpty) {
      _lastError = 'Gemini API Key 为空，请在设置中填写';
      onStatusHintChanged?.call(_lastError!);
      return false;
    }
    final selection = _keyRotator.selectForConnect(settings);
    if (selection.exhausted || selection.entry == null) {
      final waitMsg =
          GeminiLiveKeyPool.formatQuotaWaitMessage(selection.waitMs);
      _lastError = waitMsg;
      onServerError?.call(waitMsg);
      onStatusHintChanged?.call(waitMsg);
      return false;
    }
    final apiKey = selection.entry!.apiKey;

    _cancelReconnect();
    _lastError = null;
    _handshakeSucceeded = false;
    final connectionId = ++_connectionId;
    Completer<void>? setupCompleter;
    final connectStart = DateTime.now();

    try {
      await _closeSocketInternal();
      if (_disposed) return false;

      final socket = await GeminiLiveDialogPreview.openWebSocket(
        apiKey: apiKey,
        connector: _webSocketConnector,
        isStale: () => _disposed || connectionId != _connectionId,
      );
      if (socket == null) return false;

      _socket = socket;
      _inModelTurn = false;
      _protocol.resetTurnState();
      GeminiLivePcm.resetConditioner();
      _playbackEchoTailUntil = DateTime(0);
      _bargeInSuppressPlaybackUntil = DateTime(0);
      _socketSub = socket.listen(
        (data) => _protocol.handleRawFrame(data, connectionId),
        onError: (Object error, StackTrace st) =>
            _handleSocketError(error, connectionId),
        onDone: () => _handleSocketDone(connectionId),
        cancelOnError: false,
      );

      setupCompleter = Completer<void>();
      _setupCompleter = setupCompleter;
      final setupMessage =
          await GeminiLiveDialogPreview.buildConnectSetupPayload(
        settings: settings,
        isPreview: _isPreview,
        isAdvanced: isAdvancedMode,
        sessionResumptionHandle: _sessionResumptionHandle,
        allowCapturePhoto: onCapturePhoto != null,
        customToolManager: _customToolManager,
      );
      socket.add(jsonEncode(setupMessage));

      await setupCompleter.future.timeout(const Duration(seconds: 15));
      if (_disposed || connectionId != _connectionId) return false;

      _isReady = true;
      _lastError = null;

      if ((_sessionResumptionHandle?.isEmpty ?? true) &&
          _pendingHistoryToSeed.isNotEmpty) {
        final seed = GeminiLiveDialogSetup.buildHistorySeedMessage(
            _pendingHistoryToSeed);
        if (seed != null) socket.add(jsonEncode(seed));
        _pendingHistoryToSeed = const [];
      }

      debugPrint('[GeminiLiveDialogService] 已建立全双工会话: '
          '${GeminiLiveDialogSetup.model(settings)} '
          '(${DateTime.now().difference(connectStart).inMilliseconds}ms)');
      onStatusHintChanged?.call('Gemini 3.8 Live 全双工通话中，请直接说话');
      return true;
    } catch (e, st) {
      final errMsg = e is StateError ? e.message : e.toString();
      if (connectionId == _connectionId) await _closeSocketInternal();
      if (setupCompleter == null &&
          !_isPreview &&
          GeminiLiveKeyPool.isRateLimitError(errMsg)) {
        _handleRateLimitFailure(errMsg);
      } else {
        _onConnectFailure(e, st);
      }
      return false;
    } finally {
      if (identical(_setupCompleter, setupCompleter)) {
        _setupCompleter = null;
      }
    }
  }

  void _activateBackgroundSuppression(String text) {
    _suppressCurrentTurnAudio = true;
    _backgroundTurnCompletedEmitted = false;
    _suppressedBackgroundAt = DateTime.now();
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) {
      _suppressedBackgroundText = trimmed;
    }
  }

  void _clearBackgroundSuppression() {
    _suppressCurrentTurnAudio = false;
    _awaitingSuppressedPostToolTurn = false;
    _backgroundTurnCompletedEmitted = false;
    _suppressedBackgroundText = '';
    _suppressedBackgroundAt = null;
  }

  bool _isSameOrStaleBackgroundTranscript(String text) {
    final at = _suppressedBackgroundAt;
    if (at == null) return false;
    if (DateTime.now().difference(at) >= const Duration(milliseconds: 1200)) {
      return false;
    }
    final clean = text.trim();
    if (clean.isEmpty || _suppressedBackgroundText.isEmpty) return true;
    return clean == _suppressedBackgroundText ||
        _suppressedBackgroundText.contains(clean);
  }

  void _handleProtocolInputTranscript(String text, {required bool isFinal}) {
    if (_suppressCurrentTurnAudio &&
        !_inModelTurn &&
        _pendingToolCalls == 0 &&
        !_isSameOrStaleBackgroundTranscript(text)) {
      _clearBackgroundSuppression();
    }
    onInputTranscription?.call(text, isFinal: isFinal);
  }

  void _resetTeardownState() {
    _clearBackgroundSuppression();
    _cancelTurnCompleteDrain();
    _cancelReconnect();
    _outgoingPcmBuffer.clear();
    GeminiLivePcm.resetConditioner();
    _playbackEchoTailUntil = DateTime(0);
    _bargeInSuppressPlaybackUntil = DateTime(0);
  }

  @override
  Future<void> disconnect() async {
    _active = false;
    _resetTeardownState();
    await _pcmPlayer.stopImmediate();
    await _closeSocketInternal();
  }

  @override
  void feedAudioSamples(Float32List samples, {int sampleRate = 16000}) {
    if (_disposed || !_active || samples.isEmpty) return;

    if (!_isReady || _socket == null) {
      if (_reconnectTimer == null &&
          _connectFuture == null &&
          !_keyRotator.switchingKey) {
        _scheduleReconnect();
      }
      return;
    }

    final normalized = sampleRate == 16000
        ? samples
        : GeminiLivePcm.resample(samples, fromRate: sampleRate, toRate: 16000);

    final now = DateTime.now();
    if (_pcmPlayer.isPlaying) {
      // 蓝牙 HFP 链路回放延迟大，回声尾巴比有线外放长得多。
      _playbackEchoTailUntil = now.add(const Duration(milliseconds: 1500));
    }
    final isInPlaybackEchoZone =
        _pcmPlayer.isPlaying || now.isBefore(_playbackEchoTailUntil);

    final pcm16Bytes = GeminiLivePcm.processUplinkSamples(
      normalized,
      isInPlaybackEchoZone: isInPlaybackEchoZone,
      onLocalBargeInTriggered: _handleLocalBargeIn,
    );
    if (pcm16Bytes.isNotEmpty) {
      if (_suppressCurrentTurnAudio &&
          !_inModelTurn &&
          _pendingToolCalls == 0 &&
          !_awaitingSuppressedPostToolTurn &&
          _suppressedBackgroundAt != null &&
          DateTime.now().difference(_suppressedBackgroundAt!) >=
              const Duration(milliseconds: 1200) &&
          GeminiLivePcm.isInSpeechHangover) {
        _clearBackgroundSuppression();
      }
      _outgoingPcmBuffer.add(pcm16Bytes);
    }
    if (_outgoingPcmBuffer.length >= _minSendBytes) {
      GeminiLivePcm.flushBuffer(
        socket: _socket,
        canSend: _isReady,
        buffer: _outgoingPcmBuffer,
        maxChunkBytes: _maxChunkBytes,
      );
    }
  }

  void _handleLocalBargeIn() {
    _clearBackgroundSuppression();
    if (GeminiLivePcm.requiresServerConfirmedBargeIn) {
      debugPrint('[GeminiLiveDialogService] 检测到近讲候选，开启上行闸门并等待服务端确认打断');
      return;
    }
    _bargeInSuppressPlaybackUntil =
        DateTime.now().add(const Duration(milliseconds: 1200));
    _playbackEchoTailUntil = DateTime(0);
    debugPrint('[GeminiLiveDialogService] 检测到用户开口插话 (本地快速打断)，立即停止本地播报');
    unawaited(_pcmPlayer.stopImmediate());
  }

  @override
  Future<void> sendAudioFile(String filePath) async {
    if (_disposed) return;
    _clearBackgroundSuppression();
    final pcm16 = await GeminiLiveDialogPreview.readWavPcm16(filePath);
    if (pcm16 == null || !await connect()) return;
    await GeminiLivePcm.sendPcmPaced(
      pcmBytes: pcm16,
      socketGetter: () => _socket,
      canSend: () => _isReady,
      maxChunkBytes: _maxChunkBytes,
    );
    _socket?.add(jsonEncode(<String, dynamic>{
      'realtimeInput': <String, dynamic>{'audioStreamEnd': true},
    }));
  }

  @override
  Future<void> sendClientText(
    String text, {
    Uint8List? imageBytes,
    String? imagePath,
  }) async {
    final trimmed = text.trim();
    if (_disposed || trimmed.isEmpty) return;
    _clearBackgroundSuppression();
    await _pcmPlayer.stopImmediate();
    if (!await connect()) return;

    final socket = _socket;
    if (socket == null || !_isReady) return;
    final resolvedBytes =
        await GeminiLiveDialogPreview.resolveImageBytes(imageBytes, imagePath);
    _keyRotator.recordTurnPair(trimmed, '');
    socket.add(
      jsonEncode(GeminiLiveDialogSetup.buildClientTextMessage(
        trimmed,
        imageBytes: resolvedBytes,
      )),
    );
  }

  @override
  Future<void> sendRealtimeImage(Uint8List jpegBytes) async {
    if (_disposed || jpegBytes.isEmpty) return;
    final ok = await connect();
    if (!ok) return;
    _socket?.add(GeminiLiveDialogSetup.encodeRealtimeImageMessage(jpegBytes));
  }

  @override
  Future<void> stopSpeaking() => _pcmPlayer.stopImmediate();

  @override
  Future<void> previewVoice({
    required String voice,
    String? text,
    String? apiKey,
    String? model,
  }) async {
    await stopSpeaking();
    return GeminiLiveDialogPreview.run(
      settings: settings,
      voice: voice,
      text: text,
      apiKey: apiKey,
      model: model,
      createProbe: (previewSettings, onDone, onErr) {
        final probe = GeminiLiveDialogService(
          settings: previewSettings,
          isPreview: true,
          webSocketConnector: _webSocketConnector,
          keyPool: _keyRotator.keyPool,
        )
          ..onTurnCompleted = onDone
          ..onServerError = onErr;
        return (session: probe, lastError: () => probe.lastError);
      },
    );
  }

  Future<void> _reconnectSession({bool keepResumption = false}) async {
    if (!keepResumption) _sessionResumptionHandle = null;
    _connectionId++;
    await _closeSocketInternal();
    _cancelReconnect();
    _connectFuture = null;
    _keyRotator.switchingKey = false;
    if (_active && !_disposed) await connect();
  }

  @override
  Future<void> syncSessionContext(
    List<ChatMessage> history, {
    bool resetSession = false,
  }) async {
    await _pcmPlayer.stopImmediate();
    _pendingHistoryToSeed = resetSession ? const [] : List.of(history);
    _keyRotator.resetSessionHistory(history, clear: resetSession);
    if (_isReady || _socket != null) {
      await _reconnectSession();
    } else {
      _sessionResumptionHandle = null;
    }
  }

  @override
  void applySettings(AppSettings newSettings) {
    final old = settings;
    settings = newSettings;
    _refreshLightRagService();
    _keyRotator.resolvePool(newSettings);
    if (GeminiLiveDialogSetup.requiresReconnect(old, newSettings) &&
        (_isReady || _active)) {
      unawaited(_reconnectSession());
    }
  }

  void _handleSetupComplete() {
    _handshakeSucceeded = true;
    if (_setupCompleter?.isCompleted == false) _setupCompleter!.complete();
  }

  void _handleUsageMetadata(Map<String, dynamic> usage) {
    final res = _keyRotator.recordUsage(settings, usage);
    if (_isPreview) return;
    if (res != null && res.overThreshold) {
      debugPrint(
        '[GeminiLiveDialogService] Key 60s TPM 达 ${res.tpm} (>=80%)，轮次结束后切换备用 Key',
      );
      _maybePerformPendingKeySwitch();
    }
  }

  void _maybePerformPendingKeySwitch() {
    if (_isPreview ||
        !_keyRotator.pendingKeySwitch ||
        _keyRotator.switchingKey ||
        _disposed ||
        !_active ||
        !_isReady ||
        _inModelTurn ||
        _pcmPlayer.isPlaying ||
        _pendingToolCalls > 0) {
      return;
    }
    if (!_keyRotator.hasAlternativeKey(settings)) return;
    unawaited(_performKeySwitch(immediate: false));
  }

  Future<void> _performKeySwitch({required bool immediate}) async {
    if (_keyRotator.switchingKey || _disposed || !_active) return;
    _keyRotator.switchingKey = true;
    _connectionId++;
    _cancelReconnect();
    if (immediate) {
      _inModelTurn = false;
      await stopSpeaking();
    }
    _keyRotator.prepareExcludeCurrentKey();
    if (_pendingHistoryToSeed.isEmpty) {
      _pendingHistoryToSeed = _keyRotator.snapshotHistory();
    }
    onStatusHintChanged?.call(immediate
        ? 'Gemini Key 触发限流，正在切换备用 Key...'
        : '当前 Key 用量接近上限，正在切换备用 Key...');
    await _reconnectSession();
  }

  void _failSetupCompleter(Object error) {
    final completer = _setupCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }

  void _handleRateLimitFailure(String reason) {
    debugPrint('[GeminiLiveDialogService] 检测到限流/配额错误: $reason');
    final info = _keyRotator.markCurrentRateLimited(settings);
    if (info.hasAlternative && _active && !_disposed) {
      _lastError = reason;
      if (!_keyRotator.switchingKey) {
        unawaited(_performKeySwitch(immediate: true));
      }
      _failSetupCompleter(StateError(reason));
      return;
    }
    _active = false;
    _cancelReconnect();
    final waitMsg = _keyRotator.buildExhaustedErrorMessage(
      settings,
      reason,
      info.waitMs,
      duringSetup: !_handshakeSucceeded,
    );
    _lastError = waitMsg;
    _failSetupCompleter(StateError(waitMsg));
    onServerError?.call(waitMsg);
    onStatusHintChanged?.call(waitMsg);
    unawaited(_closeSocketInternal());
  }

  void _handleServerError(String message) {
    if (!_isPreview && GeminiLiveKeyPool.isRateLimitError(message)) {
      _handleRateLimitFailure(message);
      return;
    }
    _lastError = message;
    debugPrint('[GeminiLiveDialogService] 服务端错误: $message');
    _failSetupCompleter(Exception(message));
    onServerError?.call(message);
    onStatusHintChanged?.call('Gemini Live 错误: $message');
  }

  void _handleGoAway(Map<dynamic, dynamic> info) {
    debugPrint('[GeminiLiveDialogService] 收到 goAway，准备无感续期重连: $info');
    if (_active && !_disposed) {
      _scheduleReconnect(delay: const Duration(milliseconds: 200));
    }
  }

  void _handleModelTurnStarted() {
    _inModelTurn = true;
    if (_suppressCurrentTurnAudio) return;
    _cancelTurnCompleteDrain();
    _bargeInSuppressPlaybackUntil = DateTime(0);
    GeminiLivePcm.notifyPlaybackStarted();
    onModelTurnStarted?.call();
  }

  void _handleProtocolTurnComplete(String finalIn, String finalOut) {
    _inModelTurn = false;
    if (_pendingToolCalls > 0) return;
    if (_suppressCurrentTurnAudio) {
      final alreadyNotified = _backgroundTurnCompletedEmitted;
      _clearBackgroundSuppression();
      _backgroundTurnCompletedEmitted = true;
      _cancelTurnCompleteDrain();
      if (alreadyNotified) {
        _maybePerformPendingKeySwitch();
        return;
      }
    }
    _keyRotator.recordTurnPair(finalIn, finalOut);
    _cancelTurnCompleteDrain();
    if (!_pcmPlayer.isPlaying) {
      onTurnCompleted?.call();
      _maybePerformPendingKeySwitch();
      return;
    }
    _turnCompleteDrainTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (timer) {
        if (!_isConnected || _pendingToolCalls > 0) {
          _cancelTurnCompleteDrain();
          return;
        }
        if (!_pcmPlayer.isPlaying) {
          _cancelTurnCompleteDrain();
          onTurnCompleted?.call();
          _maybePerformPendingKeySwitch();
        }
      },
    );
  }

  void _cancelTurnCompleteDrain() {
    _turnCompleteDrainTimer?.cancel();
    _turnCompleteDrainTimer = null;
  }

  void _handleInterrupted() {
    _inModelTurn = false;
    _clearBackgroundSuppression();
    debugPrint('[GeminiLiveDialogService] 用户开口打断 (interrupted)，立即清空音频缓冲');
    _cancelTurnCompleteDrain();
    _playbackEchoTailUntil = DateTime(0);
    unawaited(_pcmPlayer.stopImmediate());
    onInterrupted?.call();
  }

  void _handleAudioOutputChunk(Uint8List pcmBytes, int sampleRate) {
    if (_suppressCurrentTurnAudio) return;
    onAudioOutputChunk?.call(pcmBytes);
    if (!settings.enableTtsPlayback) return;
    if (DateTime.now().isBefore(_bargeInSuppressPlaybackUntil)) return;
    _cancelTurnCompleteDrain();
    if (!_pcmPlayer.isPlaying) {
      GeminiLivePcm.notifyPlaybackStarted();
    }
    GeminiLivePcm.feedOutputPcm16(pcmBytes);
    unawaited(
      _pcmPlayer.feedPcm(
        pcmBytes,
        sampleRate: sampleRate,
        volumePercent: settings.playbackVolume,
        outputDeviceId: settings.audioOutputDeviceId,
      ),
    );
    _playbackEchoTailUntil =
        DateTime.now().add(const Duration(milliseconds: 900));
  }

  void _handleToolCallsCancelled(List<String> ids) {
    if (ids.isEmpty) return;
    debugPrint('[GeminiLiveDialogService] 收到工具调用取消请求: $ids');
    _cancelledToolCallIds.addAll(ids);
    _pendingToolCallIds.removeAll(ids);
    onToolCallsCancelled?.call(ids);
  }

  Future<void> _executeToolCalls(List<GeminiLiveToolCall> calls) async {
    final hasNonBgTool = calls.any((c) => c.name != 'record_background_speech');
    if (hasNonBgTool) {
      _clearBackgroundSuppression();
    } else {
      for (final call in calls) {
        final argText = (call.args['text']?.toString() ?? '').trim();
        if (argText.isNotEmpty) {
          _suppressedBackgroundText = argText;
          break;
        }
      }
    }
    for (final call in calls) {
      _pendingToolCallIds.add(call.id);
    }
    try {
      final result = await _toolExecutor.executeCalls(
        calls: calls,
        isAdvanced: isAdvancedMode,
        cancelledIds: _cancelledToolCallIds,
      );

      final hasBgResponse =
          result.responses.any((r) => r['name'] == 'record_background_speech');
      if (hasBgResponse && !isAdvancedMode) {
        _awaitingSuppressedPostToolTurn = true;
      }

      if (result.responses.isNotEmpty && _isReady && _socket != null) {
        final frames = GeminiLiveDialogPreview.buildToolFollowupPayloads(
          responses: result.responses,
          capturedPhotoBytes: result.capturedPhotoBytes,
          isAdvanced: isAdvancedMode,
        );
        for (final frame in frames) {
          _socket!.add(frame);
        }
      }
    } finally {
      for (final call in calls) {
        _pendingToolCallIds.remove(call.id);
      }
      _maybePerformPendingKeySwitch();
    }
  }

  void _cleanupSocket() {
    _pendingToolCallIds.clear();
    _cancelledToolCallIds.clear();
    _isReady = false;
    _socket = null;
    _socketSub = null;
  }

  void _handleSocketError(Object error, int connectionId) {
    if (connectionId != _connectionId) return;
    final msg = error.toString();
    _lastError = msg;
    debugPrint('Gemini Live socket error (connection $connectionId): $error');
    _onTransportInterrupted(error, msg, notifyMessage: false);
  }

  void _handleSocketDone(int connectionId) {
    if (connectionId != _connectionId) return;
    final wasConnecting = _setupCompleter != null;
    final hasReason = (_socket?.closeReason?.trim().isNotEmpty ?? false);
    final msg = GeminiLiveDialogPreview.formatCloseReason(
      _socket,
      wasConnecting: wasConnecting,
    );
    _lastError = msg;
    debugPrint('Gemini Live socket closed ($connectionId): $msg');
    _onTransportInterrupted(
      StateError(msg),
      msg,
      notifyMessage: hasReason || wasConnecting,
    );
  }

  void _onTransportInterrupted(
    Object error,
    String msg, {
    required bool notifyMessage,
  }) {
    _cleanupSocket();
    if (!_isPreview && GeminiLiveKeyPool.isRateLimitError(msg)) {
      _handleRateLimitFailure(msg);
      return;
    }
    _failSetupCompleter(error);
    if (_active && !_disposed && !_keyRotator.switchingKey) {
      if (notifyMessage) {
        onServerError?.call(msg);
        onStatusHintChanged?.call(msg);
      }
      _scheduleReconnect();
    }
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _scheduleReconnect({Duration delay = const Duration(seconds: 2)}) {
    if (_disposed || !_active) return;
    _cancelReconnect();
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!_disposed && _active && !_isReady) unawaited(connect());
    });
  }

  Future<void> _closeSocketInternal() async {
    _cancelTurnCompleteDrain();
    final sub = _socketSub;
    final socket = _socket;
    _cleanupSocket();
    final completer = _setupCompleter;
    _setupCompleter = null;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError('WebSocket 已关闭'));
    }
    try {
      await sub?.cancel();
      await socket?.close();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _connectionId++;
    _resetTeardownState();
    _pcmPlayer.dispose();
    unawaited(_closeSocketInternal());
  }
}
