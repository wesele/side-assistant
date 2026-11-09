import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/camera_capture_result.dart';
import 'package:side_assistant/core/platform/pcm_stream_player_bridge.dart';
import 'package:side_assistant/services/speech/gemini_live_dialog_service.dart';

class _FakeLiveWebSocket extends Stream<dynamic> implements WebSocket {
  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  final List<dynamic> sentMessages = <dynamic>[];
  int? _closeCode;
  String? _closeReason;

  _FakeLiveWebSocket();

  @override
  int? get closeCode => _closeCode;
  @override
  String? get closeReason => _closeReason;

  void emit(dynamic data) {
    if (!_controller.isClosed) _controller.add(data);
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) =>
      _controller.stream.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );

  @override
  void add(dynamic data) {
    sentMessages.add(data);
    if (data is String && data.contains('"setup"')) {
      scheduleMicrotask(() => emit('{"setupComplete":{}}'));
    }
  }

  @override
  Future<dynamic> close([int? code, String? reason]) {
    _closeCode ??= code;
    _closeReason ??= reason;
    return _controller.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePcmPlayer extends PlatformPcmStreamPlayer {
  @override
  bool get isPlaying => false;

  @override
  Future<void> feedPcm(
    Uint8List pcmBytes, {
    int sampleRate = 24000,
    int volumePercent = 100,
    String outputDeviceId = '',
  }) async {}

  @override
  Future<void> stopImmediate() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GeminiLiveDialogService Dual-Mode & Advanced Wiring Tests', () {
    test('1. Setup 载荷：Advanced 模式包含 thinkingConfig，Basic 模式缺省', () async {
      // 1.1 Advanced 模式
      final advSocket = _FakeLiveWebSocket();
      final advService = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
          geminiLiveModel: 'gemini-3.8-live',
          geminiLiveAdvancedMode: 'advanced',
          geminiLiveThinkingLevel: 'high',
          geminiLiveIncludeThoughts: true,
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => advSocket,
      );
      addTearDown(() => advService.dispose());

      expect(advService.isAdvancedMode, isTrue);
      expect(await advService.connect(), isTrue);

      final advSetupMsg = jsonDecode(advSocket.sentMessages.first as String)
          as Map<String, dynamic>;
      final advGenCfg =
          advSetupMsg['setup']['generationConfig'] as Map<String, dynamic>;
      expect(advGenCfg.containsKey('thinkingConfig'), isTrue);
      expect(advGenCfg['thinkingConfig']['thinkingLevel'], equals('high'));
      expect(advGenCfg['thinkingConfig']['includeThoughts'], isTrue);

      // 1.2 Basic 模式
      final basicSocket = _FakeLiveWebSocket();
      final basicService = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
          geminiLiveModel: 'gemini-3.8-live',
          geminiLiveAdvancedMode: 'basic',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => basicSocket,
      );
      addTearDown(() => basicService.dispose());

      expect(basicService.isAdvancedMode, isFalse);
      expect(await basicService.connect(), isTrue);

      final basicSetupMsg = jsonDecode(basicSocket.sentMessages.first as String)
          as Map<String, dynamic>;
      final basicGenCfg =
          basicSetupMsg['setup']['generationConfig'] as Map<String, dynamic>;
      expect(basicGenCfg.containsKey('thinkingConfig'), isFalse);
    });

    test('2. 工具响应载荷：scheduling 仅在 Advanced 模式出现，Basic 模式缺省', () async {
      // 2.1 Advanced 模式下测试 capture_photo 与 record_background_speech
      final advSocket = _FakeLiveWebSocket();
      final advService = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
          geminiLiveAdvancedMode: 'advanced',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => advSocket,
      );
      addTearDown(() => advService.dispose());

      advService.onCapturePhoto = () async => CameraCaptureResult(
            imageBytes: Uint8List.fromList([0xFF, 0xD8, 0x01]),
            filePath: 'test.jpg',
          );
      expect(await advService.connect(), isTrue);

      // 下发 capture_photo
      advSocket.emit(
        '{"toolCall":{"functionCalls":[{"id":"call_photo_1","name":"capture_photo","args":{}}]}}',
      );
      await pumpEventQueue();

      final advMessages = advSocket.sentMessages
          .map((m) => jsonDecode(m.toString()) as Map<String, dynamic>)
          .toList();
      final photoRespMsg =
          advMessages.firstWhere((m) => m.containsKey('toolResponse'));
      final photoResponses =
          photoRespMsg['toolResponse']['functionResponses'] as List;
      expect(photoResponses.single['id'], equals('call_photo_1'));
      expect(photoResponses.single['scheduling'], equals('WHEN_IDLE'));

      // 下发 record_background_speech
      advSocket.emit(
        '{"toolCall":{"functionCalls":[{"id":"call_bg_1","name":"record_background_speech","args":{"text":"旁白内容","reason":"与旁人聊天"}}]}}',
      );
      await pumpEventQueue();

      final advMessagesAfterBg = advSocket.sentMessages
          .map((m) => jsonDecode(m.toString()) as Map<String, dynamic>)
          .toList();
      final bgRespMsg =
          advMessagesAfterBg.lastWhere((m) => m.containsKey('toolResponse'));
      final bgResponses =
          bgRespMsg['toolResponse']['functionResponses'] as List;
      expect(bgResponses.single['id'], equals('call_bg_1'));
      expect(bgResponses.single['scheduling'], equals('SILENT'));

      // 2.2 Basic 模式下 scheduling 字段缺省
      final basicSocket = _FakeLiveWebSocket();
      final basicService = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
          geminiLiveAdvancedMode: 'basic',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => basicSocket,
      );
      addTearDown(() => basicService.dispose());

      expect(await basicService.connect(), isTrue);
      basicSocket.emit(
        '{"toolCall":{"functionCalls":[{"id":"call_bg_basic","name":"record_background_speech","args":{"text":"旁白","reason":"无意图"}}]}}',
      );
      await pumpEventQueue();

      final basicMessages = basicSocket.sentMessages
          .map((m) => jsonDecode(m.toString()) as Map<String, dynamic>)
          .toList();
      final basicBgResp =
          basicMessages.firstWhere((m) => m.containsKey('toolResponse'));
      final basicResponses =
          basicBgResp['toolResponse']['functionResponses'] as List;
      expect(basicResponses.single['id'], equals('call_bg_basic'));
      expect(basicResponses.single.containsKey('scheduling'), isFalse);
    });

    test('3. 工具取消机制：被取消的工具 ID 不发送 functionResponse，并在 Port 上广播', () async {
      final socket = _FakeLiveWebSocket();
      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
          geminiLiveAdvancedMode: 'advanced',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => socket,
      );
      addTearDown(() => service.dispose());

      final cancelledFromPort = <List<String>>[];
      service.onToolCallsCancelled = cancelledFromPort.add;

      final photoCompleter = Completer<CameraCaptureResult?>();
      service.onCapturePhoto = () => photoCompleter.future;

      expect(await service.connect(), isTrue);

      // 下发两个工具调用：call_1 (capture_photo) 与 call_2 (record_background_speech)
      socket.emit(
        '{"toolCall":{"functionCalls":['
        '{"id":"call_1","name":"capture_photo","args":{}},'
        '{"id":"call_2","name":"record_background_speech","args":{"text":"背景音","reason":"闲聊"}}'
        ']}}',
      );
      await pumpEventQueue();

      // 在 photoCompleter 未完成时，服务端下发 toolCallCancellation 取消 call_1
      socket.emit('{"toolCallCancellation":{"ids":["call_1"]}}');
      await pumpEventQueue();

      // 验证端口收到取消广播
      expect(cancelledFromPort.single, equals(['call_1']));

      // 让拍照完成
      photoCompleter.complete(CameraCaptureResult(
        imageBytes: Uint8List.fromList([0xFF, 0xD8, 0xAA]),
        filePath: 'test.jpg',
      ));
      await pumpEventQueue();

      final messages = socket.sentMessages
          .map((m) => jsonDecode(m.toString()) as Map<String, dynamic>)
          .toList();
      final toolResponseMsg =
          messages.firstWhere((m) => m.containsKey('toolResponse'));
      final fnResponses =
          toolResponseMsg['toolResponse']['functionResponses'] as List;

      // 验证：call_1 被取消，响应列表中仅有 call_2，绝不包含 call_1
      expect(fnResponses.map((r) => r['id']).toList(), equals(['call_2']));
      // 验证：call_1 的拍照附图 clientContent 也不应发送
      expect(messages.any((m) => m.containsKey('clientContent')), isFalse);
    });

    test(
        '4. 拍照后附图 clientContent：Advanced 模式下 turnComplete=false，Basic 模式下 turnComplete=true',
        () async {
      // 4.1 Advanced 模式
      final advSocket = _FakeLiveWebSocket();
      final advService = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
          geminiLiveAdvancedMode: 'advanced',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => advSocket,
      );
      addTearDown(() => advService.dispose());

      advService.onCapturePhoto = () async => CameraCaptureResult(
            imageBytes: Uint8List.fromList([0xFF, 0xD8, 0x12]),
            filePath: 'adv.jpg',
          );
      expect(await advService.connect(), isTrue);

      advSocket.emit(
        '{"toolCall":{"functionCalls":[{"id":"call_adv_photo","name":"capture_photo","args":{}}]}}',
      );
      await pumpEventQueue();

      final advMessages = advSocket.sentMessages
          .map((m) => jsonDecode(m.toString()) as Map<String, dynamic>)
          .toList();
      final advPhotoContent =
          advMessages.firstWhere((m) => m.containsKey('clientContent'));
      expect(advPhotoContent['clientContent']['turnComplete'], isFalse);

      // 4.2 Basic 模式
      final basicSocket = _FakeLiveWebSocket();
      final basicService = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
          geminiLiveAdvancedMode: 'basic',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => basicSocket,
      );
      addTearDown(() => basicService.dispose());

      basicService.onCapturePhoto = () async => CameraCaptureResult(
            imageBytes: Uint8List.fromList([0xFF, 0xD8, 0x34]),
            filePath: 'basic.jpg',
          );
      expect(await basicService.connect(), isTrue);

      basicSocket.emit(
        '{"toolCall":{"functionCalls":[{"id":"call_basic_photo","name":"capture_photo","args":{}}]}}',
      );
      await pumpEventQueue();

      final basicMessages = basicSocket.sentMessages
          .map((m) => jsonDecode(m.toString()) as Map<String, dynamic>)
          .toList();
      final basicPhotoContent =
          basicMessages.firstWhere((m) => m.containsKey('clientContent'));
      expect(basicPhotoContent['clientContent']['turnComplete'], isTrue);
    });

    test('5. 端口事件转发：onThought 与 onInteractionStatus 透传', () async {
      final socket = _FakeLiveWebSocket();
      final service = GeminiLiveDialogService(
        settings: AppSettings(
          pipelineMode: AppConstants.pipelineModeGeminiLive,
          geminiApiKey: 'test_key',
          geminiLiveAdvancedMode: 'advanced',
        ),
        pcmPlayer: _FakePcmPlayer(),
        webSocketConnector: (_) async => socket,
      );
      addTearDown(() => service.dispose());

      final thoughts = <String>[];
      final interactionStatuses = <bool>[];
      service.onThought = thoughts.add;
      service.onInteractionStatus = interactionStatuses.add;

      expect(await service.connect(), isTrue);

      // 模拟收到 thought 帧
      socket.emit(
        '{"serverContent":{"modelTurn":{"parts":[{"thought":true,"text":"正在深度思考..."}]}}}',
      );
      await pumpEventQueue();
      expect(thoughts, equals(['正在深度思考...']));

      // 模拟收到 interactionStatus: IN_PROGRESS
      socket.emit('{"interactionStatus":"IN_PROGRESS"}');
      await pumpEventQueue();
      expect(interactionStatuses.last, isTrue);

      // 模拟收到 interactionStatus: IDLE
      socket.emit('{"interactionStatus":"IDLE"}');
      await pumpEventQueue();
      expect(interactionStatuses.last, isFalse);
    });
  });
}
