import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../core/constants/app_constants.dart';
import '../../core/models/app_settings.dart';
import '../../core/models/camera_capture_result.dart';
import '../../core/models/chat_message.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/location_bridge.dart';
import '../../core/platform/pcm_stream_player_bridge.dart';
import '../../core/ports/gemini_live_session_port.dart';
import '../../core/ports/knowledge_port.dart';
import '../lightrag/lightrag_service.dart';
import '../llm/tools/custom_tool_manager.dart';
import 'support/gemini_live_capabilities.dart';
import 'support/gemini_live_dialog_protocol.dart';
import 'support/gemini_live_dialog_setup.dart';
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
        onInputTranscription?.call(text, isFinal: isFinal),
    onOutputTranscript: (delta, full, {required isFinal}) =>
        onOutputTranscription?.call(delta, full, isFinal: isFinal),
    onModelTurnStarted: _handleModelTurnStarted,
    onTurnComplete: (finalIn, finalOut) => _handleProtocolTurnComplete(),
    onToolCalls: (calls) => unawaited(_executeToolCalls(calls)),
    onThought: (thought) => onThought?.call(thought),
    onToolCallsCancelled: _handleToolCallsCancelled,
    onInteractionStatus: (status) =>
        onInteractionStatus?.call(status.toUpperCase() == 'IN_PROGRESS'),
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
    onSuppressCurrentTurnAudio: (suppress) =>
        _suppressCurrentTurnAudio = suppress,
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
  })  : _isPreview = isPreview,
        _pcmPlayer = pcmPlayer ?? PlatformPcmStreamPlayer(),
        _lightRagService = lightRagService,
        _customToolManager = customToolManager ?? CustomToolManager.instance,
        _webSocketConnector = webSocketConnector {
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

  @override
  Future<bool> connect() {
    if (_disposed) return Future<bool>.value(false);
    _active = true;
    if (_isReady && _socket != null) return Future<bool>.value(true);
    final existing = _connectFuture;
    if (existing != null) return existing;

    final future = _doConnect().catchError((Object e, StackTrace st) {
      _lastError = e.toString();
      _isReady = false;
      debugPrint('[GeminiLiveDialogService] 连接异常: $e\n$st');
      if (_active && !_disposed && _reconnectTimer == null) {
        _scheduleReconnect();
      }
      return false;
    });
    _connectFuture = future;
    return future.whenComplete(() {
      if (identical(_connectFuture, future)) _connectFuture = null;
    });
  }

  Future<bool> _doConnect() async {
    if (_disposed) return false;
    final apiKey = GeminiLiveDialogSetup.apiKey(settings);
    if (apiKey.isEmpty) {
      _lastError = 'Gemini API Key 为空，请在设置中填写';
      onStatusHintChanged?.call(_lastError!);
      return false;
    }

    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _lastError = null;
    final connectionId = ++_connectionId;
    Completer<void>? setupCompleter;
    final connectStart = DateTime.now();

    try {
      await _closeSocketInternal();
      if (_disposed) return false;

      final uri =
          '${AppConstants.geminiLiveWsUrl}?key=${Uri.encodeQueryComponent(apiKey)}';
      final connectFut = (_webSocketConnector ?? WebSocket.connect)(uri);
      unawaited(connectFut.then<void>((_) {}, onError: (Object _) {}));

      final socket = await connectFut.timeout(const Duration(seconds: 15));
      if (_disposed || connectionId != _connectionId) {
        await socket.close();
        return false;
      }

      _socket = socket;
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

      String? address;
      try {
        address = await LocationBridge.getCurrentAddress()
            .timeout(const Duration(milliseconds: 500), onTimeout: () => null);
      } catch (_) {}

      final sysInstruction = GeminiLiveDialogSetup.buildSystemInstruction(
        settings,
        currentAddress: address,
        customToolManager: _customToolManager,
      );
      final isAdvanced = isAdvancedMode;
      final thinkingLevel = GeminiLiveCapabilities.normalizeThinkingLevel(
        settings.geminiLiveThinkingLevel,
      );
      final includeThoughts = settings.geminiLiveIncludeThoughts;

      final setupMessage = _isPreview
          ? GeminiLiveDialogSetup.buildPreviewSetupMessage(
              settings: settings,
              systemInstructionOverride: sysInstruction,
              sessionResumptionHandle: _sessionResumptionHandle,
              allowCapturePhoto: onCapturePhoto != null,
              customToolManager: _customToolManager,
              advanced: isAdvanced,
              thinkingLevel: thinkingLevel,
              includeThoughts: includeThoughts,
            )
          : GeminiLiveDialogSetup.buildSetupMessage(
              settings: settings,
              systemInstructionOverride: sysInstruction,
              sessionResumptionHandle: _sessionResumptionHandle,
              allowCapturePhoto: onCapturePhoto != null,
              customToolManager: _customToolManager,
              advanced: isAdvanced,
              thinkingLevel: thinkingLevel,
              includeThoughts: includeThoughts,
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
      _lastError = e is StateError ? e.message : e.toString();
      _isReady = false;
      debugPrint('[GeminiLiveDialogService] 握手失败: $e\n$st');
      if (connectionId == _connectionId) await _closeSocketInternal();
      if (_active && !_disposed && _reconnectTimer == null) {
        _scheduleReconnect();
      }
      return false;
    } finally {
      if (identical(_setupCompleter, setupCompleter)) {
        _setupCompleter = null;
      }
    }
  }

  void _resetTeardownState() {
    _suppressCurrentTurnAudio = false;
    _cancelTurnCompleteDrain();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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
      if (_reconnectTimer == null && _connectFuture == null) {
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
      onLocalBargeInTriggered: () {
        _suppressCurrentTurnAudio = false;
        if (GeminiLivePcm.isMobileEchoProfile) {
          debugPrint(
            '[GeminiLiveDialogService] 移动端检测到用户开口，开启本地上行闸门',
          );
        } else {
          _bargeInSuppressPlaybackUntil =
              DateTime.now().add(const Duration(milliseconds: 1200));
          _playbackEchoTailUntil = DateTime(0);
          debugPrint('[GeminiLiveDialogService] 检测到用户开口插话 (本地快速打断)，立即停止本地播报');
          unawaited(_pcmPlayer.stopImmediate());
        }
      },
    );
    if (pcm16Bytes.isNotEmpty) {
      _suppressCurrentTurnAudio = false;
      _outgoingPcmBuffer.add(pcm16Bytes);
    }
    if (_outgoingPcmBuffer.length >= _minSendBytes) {
      _flushOutgoingPcm();
    }
  }

  void _flushOutgoingPcm() {
    final socket = _socket;
    if (socket == null || !_isReady || _outgoingPcmBuffer.isEmpty) return;
    final bytes = _outgoingPcmBuffer.takeBytes();
    try {
      for (var offset = 0; offset < bytes.length; offset += _maxChunkBytes) {
        final end = math.min(offset + _maxChunkBytes, bytes.length);
        socket.add(GeminiLivePcm.encodeChunkMessage(bytes, offset, end));
      }
    } catch (_) {}
  }

  @override
  Future<void> sendAudioFile(String filePath) async {
    if (_disposed) return;
    final file = File(filePath);
    if (!file.existsSync()) return;
    final rawBytes = await file.readAsBytes();
    if (rawBytes.length <= 44) return;
    final pcm16 = Uint8List.sublistView(rawBytes, 44);
    final ok = await connect();
    if (!ok) return;
    for (var offset = 0; offset < pcm16.length; offset += _maxChunkBytes) {
      final socket = _socket;
      if (socket == null || !_isReady) break;
      final end = math.min(offset + _maxChunkBytes, pcm16.length);
      socket.add(GeminiLivePcm.encodeChunkMessage(pcm16, offset, end));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
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
    await _pcmPlayer.stopImmediate();
    final ok = await connect();
    if (!ok) return;

    final socket = _socket;
    if (socket == null || !_isReady) return;

    Uint8List? resolvedBytes = imageBytes;
    if ((resolvedBytes?.isEmpty ?? true) && imagePath?.isNotEmpty == true) {
      try {
        final file = File(imagePath!);
        if (file.existsSync()) resolvedBytes = await file.readAsBytes();
      } catch (_) {}
    }

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

    final previewSettings = GeminiLiveDialogSetup.buildPreviewSettings(
      settings,
      voice: voice,
      apiKey: apiKey,
      model: model,
    );

    if (GeminiLiveDialogSetup.apiKey(previewSettings).isEmpty) {
      throw StateError('Gemini API Key 为空，请先在设置中填写');
    }

    final isAdvanced = GeminiLiveCapabilities.resolveAdvanced(
      mode: previewSettings.geminiLiveAdvancedMode,
      model: GeminiLiveDialogSetup.model(previewSettings),
    );
    final timeoutSeconds = isAdvanced ? 25 : 12;

    final turnCompleter = Completer<void>();
    final probe = GeminiLiveDialogService(
      settings: previewSettings,
      isPreview: true,
      webSocketConnector: _webSocketConnector,
    );

    probe.onTurnCompleted = () {
      if (!turnCompleter.isCompleted) {
        turnCompleter.complete();
      }
    };
    probe.onServerError = (msg) {
      if (!turnCompleter.isCompleted) {
        turnCompleter.completeError(StateError(msg));
      }
    };

    try {
      final ok = await probe.connect();
      if (!ok) {
        throw StateError(probe.lastError ?? '连接 Gemini Live 失败');
      }

      final promptText = (text == null || text.trim().isEmpty)
          ? '你好，我是晓漫，这是 Gemini Live $voice 原生音色的试听效果。'
          : text.trim();

      await probe.sendClientText('请直接用自然亲切的语气朗读这句话，不要添加任何多余解释：$promptText');

      // 等待单轮生成完成（超时 basic 12 秒，advanced 25 秒）
      await turnCompleter.future.timeout(Duration(seconds: timeoutSeconds));

      // 等待底层 PCM 播放缓冲在扬声器播放完毕（每 100ms 轮询，上限 10 秒）
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (probe.isSpeakingOutput && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    } finally {
      probe.dispose();
    }
  }

  @override
  Future<void> syncSessionContext(
    List<ChatMessage> history, {
    bool resetSession = false,
  }) async {
    await _pcmPlayer.stopImmediate();
    _sessionResumptionHandle = null;
    _pendingHistoryToSeed = resetSession ? const [] : List.of(history);
    if (_isReady || _socket != null) {
      await _closeSocketInternal();
      if (_active && !_disposed) await connect();
    }
  }

  @override
  void applySettings(AppSettings newSettings) {
    final old = settings;
    settings = newSettings;
    _refreshLightRagService();

    final advancedChanged = old.geminiLiveAdvancedMode !=
            newSettings.geminiLiveAdvancedMode ||
        old.geminiLiveThinkingLevel != newSettings.geminiLiveThinkingLevel ||
        old.geminiLiveIncludeThoughts != newSettings.geminiLiveIncludeThoughts;

    if ((advancedChanged ||
            GeminiLiveDialogSetup.requiresReconnect(old, newSettings)) &&
        (_isReady || _active)) {
      _sessionResumptionHandle = null;
      _connectionId++;
      _connectFuture = null;
      unawaited(() async {
        await _closeSocketInternal();
        if (_active && !_disposed) await connect();
      }());
    }
  }

  void _handleSetupComplete() {
    if (_setupCompleter?.isCompleted == false) _setupCompleter!.complete();
  }

  void _handleServerError(String message) {
    _lastError = message;
    debugPrint('[GeminiLiveDialogService] 服务端错误: $message');
    if (_setupCompleter?.isCompleted == false) {
      _setupCompleter!.completeError(Exception(message));
    }
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
    _cancelTurnCompleteDrain();
    _bargeInSuppressPlaybackUntil = DateTime(0);
    GeminiLivePcm.notifyPlaybackStarted();
    onModelTurnStarted?.call();
  }

  void _handleProtocolTurnComplete() {
    _suppressCurrentTurnAudio = false;
    _cancelTurnCompleteDrain();
    if (_pendingToolCalls > 0) return;
    if (!_pcmPlayer.isPlaying) {
      onTurnCompleted?.call();
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
        }
      },
    );
  }

  void _cancelTurnCompleteDrain() {
    _turnCompleteDrainTimer?.cancel();
    _turnCompleteDrainTimer = null;
  }

  void _handleInterrupted() {
    _suppressCurrentTurnAudio = false;
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
    for (final call in calls) {
      _pendingToolCallIds.add(call.id);
    }
    try {
      final result = await _toolExecutor.executeCalls(
        calls: calls,
        isAdvanced: isAdvancedMode,
        cancelledIds: _cancelledToolCallIds,
      );

      if (result.responses.isNotEmpty && _isReady && _socket != null) {
        _socket!.add(
          jsonEncode(GeminiLiveDialogSetup.buildToolResponseMessage(
            result.responses,
          )),
        );
        if (result.capturedPhotoBytes != null &&
            result.capturedPhotoBytes!.isNotEmpty) {
          _socket!.add(
            jsonEncode(GeminiLiveDialogSetup.buildClientTextMessage(
              '这是刚刚拍下的现场照片，请结合画面内容直接回答。',
              imageBytes: result.capturedPhotoBytes,
              turnComplete: !isAdvancedMode,
            )),
          );
        }
      }
    } finally {
      for (final call in calls) {
        _pendingToolCallIds.remove(call.id);
      }
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
    _lastError = error.toString();
    debugPrint('Gemini Live socket error (connection $connectionId): $error');
    _cleanupSocket();
    final completer = _setupCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
    if (_active && !_disposed) {
      _scheduleReconnect();
    }
  }

  void _handleSocketDone(int connectionId) {
    if (connectionId != _connectionId) return;
    final wasConnecting = _setupCompleter != null;
    final closeCode = _socket?.closeCode;
    final closeReason = _socket?.closeReason;
    final hasReason = closeReason != null && closeReason.trim().isNotEmpty;
    final codePart = closeCode != null ? '$closeCode: ' : '';
    final msg = hasReason
        ? '连接被服务端关闭 ($codePart${closeReason.trim()})'
        : (wasConnecting ? '连接被服务端关闭，请检查 API Key、模型名与网络' : 'Gemini Live 连接已断开');
    _lastError = msg;
    debugPrint('Gemini Live socket closed ($connectionId, '
        'code: $closeCode, reason: $closeReason): $msg');
    _cleanupSocket();
    final completer = _setupCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(StateError(msg));
    }
    if (_active && !_disposed) {
      if (hasReason || wasConnecting) {
        onServerError?.call(msg);
        onStatusHintChanged?.call(msg);
      }
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect({Duration delay = const Duration(seconds: 2)}) {
    if (_disposed || !_active) return;
    _reconnectTimer?.cancel();
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
      await socket?.close();
      await sub?.cancel();
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
