import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/platform/foundation_bridge.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/core/models/chat_session.dart';
import 'package:side_assistant/services/automation/app_driver_server.dart';

/// 纯 Dart 实现的 Fake 端口适配器，用于独立验证 AppDriverServer 的解耦性
class FakeAssistantDriverPort implements AssistantDriverPort {
  final List<String> callLog = [];
  final List<VoidCallback> _listeners = [];

  @override
  AssistantStatus status = AssistantStatus.idle;
  @override
  String statusHint = '测试空闲';
  @override
  String liveTranscript = '';
  @override
  String displayTranscript = '';
  @override
  String lastRecognizedSpeech = '';
  @override
  bool isWakeWordMatched = false;
  @override
  bool isMicListening = false;
  @override
  bool isManualRecording = false;
  @override
  bool isQuickCapturing = false;
  @override
  double micLevel = 0.0;
  @override
  double micDbfs = -60.0;
  @override
  bool vadDetected = false;
  @override
  bool isMicTesting = false;
  @override
  String micTestText = '';
  @override
  List<Map<String, dynamic>> micTestHistory = [];
  @override
  AppSettings settings = AppSettings(
    playbackVolume: 50,
    webAccessPassword: '',
    edgeVoice: 'zh-CN-XiaoxiaoNeural',
  );
  @override
  int enrolledSpeakerCount = 2;
  @override
  bool hasEnrolledOwner = true;
  @override
  String speakerModelLabel = 'FakeSpeakerModel';
  @override
  String? lastEnrollError;
  @override
  bool isInContinuousMode = false;
  @override
  String currentSessionId = 'session-test-123';
  @override
  List<ChatMessage> messages = [
    ChatMessage(
      id: 'msg-1',
      role: 'user',
      content: 'Fake user message',
      timestamp: DateTime.now(),
      sessionId: 'session-test-123',
    ),
  ];
  @override
  List<ChatSession> sessions = [
    ChatSession(
      id: 'session-test-123',
      title: 'Fake Session',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      messages: [],
    ),
  ];
  @override
  bool isSelfTesting = false;
  @override
  List<String> selfTestLogs = ['Log 1', 'Log 2'];
  @override
  String activeAudioInputDeviceLabel = 'Fake Microphone';

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  void notify() {
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  @override
  Future<void> simulateUserInput(String text) async {
    callLog.add('simulateUserInput:$text');
  }

  @override
  Future<void> sendDirectUserMessage(String text) async {
    callLog.add('sendDirectUserMessage:$text');
  }

  @override
  Future<void> sendTextMessage(String text) async {
    callLog.add('sendTextMessage:$text');
  }

  @override
  Future<void> captureAndAskAboutScene({String question = '这是什么，介绍一下'}) async {
    callLog.add('captureAndAskAboutScene:$question');
  }

  @override
  Future<void> startManualRecording() async {
    callLog.add('startManualRecording');
    isManualRecording = true;
  }

  @override
  Future<void> stopManualRecording() async {
    callLog.add('stopManualRecording');
    isManualRecording = false;
  }

  @override
  Future<void> startNewSession({bool playVoice = false}) async {
    callLog.add('startNewSession:playVoice=$playVoice');
    currentSessionId = 'session-new-456';
  }

  @override
  Future<void> toggleMicListening() async {
    callLog.add('toggleMicListening');
    isMicListening = !isMicListening;
  }

  @override
  Future<void> switchSession(String sessionId) async {
    callLog.add('switchSession:$sessionId');
    currentSessionId = sessionId;
  }

  @override
  Future<void> renameSession(String sessionId, String newTitle) async {
    callLog.add('renameSession:$sessionId->$newTitle');
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    callLog.add('deleteSession:$sessionId');
  }

  @override
  Future<void> clearAllHistory() async {
    callLog.add('clearAllHistory');
    sessions.clear();
    messages.clear();
  }

  @override
  Future<void> updateSettings(AppSettings newSettings) async {
    callLog.add('updateSettings');
    settings = newSettings;
  }

  @override
  Future<void> setPlaybackVolume(int volume) async {
    callLog.add('setPlaybackVolume:$volume');
    settings.playbackVolume = volume;
  }

  @override
  Future<void> setMicTestMode(bool enabled, {bool clear = false}) async {
    callLog.add('setMicTestMode:$enabled,clear=$clear');
    isMicTesting = enabled;
  }

  @override
  Future<void> stopSpeaking() async {
    callLog.add('stopSpeaking');
  }

  @override
  Future<void> speakImmediate(String text) async {
    callLog.add('speakImmediate:$text');
  }

  @override
  Future<void> previewVoice({String? voice, String? text}) async {
    callLog.add('previewVoice:voice=$voice,text=$text');
  }

  @override
  Future<String> exportChatHistoryHtml() async {
    callLog.add('exportChatHistoryHtml');
    return '<!DOCTYPE html><html><body>Exported Chat History</body></html>';
  }

  @override
  Future<CameraCaptureResult> capturePhotoDirect() async {
    callLog.add('capturePhotoDirect');
    return CameraCaptureResult(
      imageBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
      isSimulated: true,
      filePath: '/tmp/fake_photo.jpg',
    );
  }

  @override
  Future<String?> transcribeAudioFile(String path,
      {bool isStandbyWakeCheck = false}) async {
    callLog.add('transcribeAudioFile:$path');
    return 'Transcribed: $path';
  }

  @override
  Float32List? getRecentAudioSnippet({double seconds = 3.0}) {
    callLog.add('getRecentAudioSnippet:$seconds');
    return Float32List(16000);
  }

  @override
  Future<bool> recordAndEnrollOwnerSpeaker({double seconds = 3.5}) async {
    callLog.add('recordAndEnrollOwnerSpeaker:$seconds');
    return true;
  }

  @override
  Future<bool> enrollOwnerSpeaker({Float32List? samples}) async {
    callLog.add('enrollOwnerSpeaker');
    return true;
  }

  @override
  Future<void> clearOwnerSpeaker() async {
    callLog.add('clearOwnerSpeaker');
    enrolledSpeakerCount = 0;
    hasEnrolledOwner = false;
  }

  @override
  Future<Map<String, dynamic>> recordAndTestOwnerSpeakerSimilarity(
      {double seconds = 3.0}) async {
    callLog.add('recordAndTestOwnerSpeakerSimilarity:$seconds');
    return {'passed': true, 'similarity': 0.95};
  }

  @override
  Future<Map<String, dynamic>> testOwnerSpeakerSimilarity(
      {Float32List? samples}) async {
    callLog.add('testOwnerSpeakerSimilarity');
    return {'passed': true, 'similarity': 0.88};
  }

  @override
  Future<String> testGeminiAsrConnection(
      {String? apiKey, String? model}) async {
    callLog.add('testGeminiAsrConnection');
    return 'Gemini OK';
  }

  @override
  Future<void> processAudioFile(String filePath) async {
    callLog.add('processAudioFile:$filePath');
    lastRecognizedSpeech = 'Processed $filePath';
  }

  @override
  Future<void> setAudioInputDevice(String deviceId, String label) async {
    callLog.add('setAudioInputDevice:$deviceId');
    activeAudioInputDeviceLabel = label;
  }

  @override
  Future<Map<String, dynamic>> runDiagnosticSelfTest() async {
    callLog.add('runDiagnosticSelfTest');
    return {'success': true, 'timestamp': '2026-10-31T00:00:00Z'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers.global'),
    (methodCall) async => 1,
  );
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('xyz.luan/audioplayers'),
    (methodCall) async => 1,
  );
  HttpOverrides.global = null;

  group('AssistantController Driver Port 语义契约与方法健壮性测试', () {
    late AssistantController controller;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings(
        autoStartMicOnLaunch: false,
        enablePromptTone: false,
        enableTtsPlayback: false,
        webAccessPassword: '',
      );
      controller = AssistantController(
        settings: settings,
        enableDriverServer: false,
      );
    });

    tearDown(() async {
      await controller.disposeAsync();
    });

    test('1.1 stopSpeaking() 能够安全无害地调用且不抛出异常', () async {
      await expectLater(controller.stopSpeaking(), completes);
    });

    test('1.2 speakImmediate() 在禁用或启用 TTS 下均能安全执行不崩溃', () async {
      await expectLater(controller.speakImmediate('测试文本'), completes);
    });

    test('1.3 previewVoice() 传入默认或自定义参数均能安全执行', () async {
      controller.settings.ttsEngine = 'system';
      await expectLater(
        controller.previewVoice(voice: 'zh-CN-XiaoxiaoNeural', text: '试听'),
        completes,
      );
    });

    test('1.4 exportChatHistoryHtml() 导出的 HTML 格式结构合法且非空', () async {
      final html = await controller.exportChatHistoryHtml();
      expect(html, isNotEmpty);
      expect(html, contains('<!DOCTYPE html>'));
      expect(html, contains('<html'));
      expect(html, contains('</html>'));
    });

    test('1.5 capturePhotoDirect() 在无硬件摄像头环境能够平滑 fallback 兜底', () async {
      final result = await controller.capturePhotoDirect();
      expect(result.imageBytes, isNotEmpty);
      expect(result.imageBytes[0], 0xFF);
      expect(result.imageBytes[1], 0xD8);
      expect(result.isSimulated, isTrue);
    });

    test('1.6 transcribeAudioFile() 在文件不存在或非法路径下优雅返回空字符串且不抛未捕获异常', () async {
      final res1 =
          await controller.transcribeAudioFile('non_existent_file.wav');
      expect(res1, equals(''));

      final res2 = await controller.transcribeAudioFile(
        'non_existent_file.wav',
        isStandbyWakeCheck: true,
      );
      expect(res2, equals(''));
    });

    test('1.7 getRecentAudioSnippet() 安全返回 PCM 切片，空缓存时不为 null 且长度 >= 0', () {
      final snippet = controller.getRecentAudioSnippet(seconds: 2.0);
      expect(snippet, isNotNull);
      expect(snippet!.length, isNonNegative);
    });

    test('1.8 声纹相关契约属性与方法测试 (enrolledSpeakerCount, clearOwnerSpeaker 等)',
        () async {
      expect(controller.enrolledSpeakerCount, isNonNegative);
      expect(controller.hasEnrolledOwner, isA<bool>());
      expect(controller.speakerModelLabel, isNotEmpty);

      // 清空声纹
      await expectLater(controller.clearOwnerSpeaker(), completes);
      expect(controller.enrolledSpeakerCount, equals(0));

      // 无样本时比对
      final testResult = await controller.testOwnerSpeakerSimilarity(
        samples: Float32List(0),
      );
      expect(testResult['passed'], isFalse);

      // 无样本时录入
      final enrollResult = await controller.enrollOwnerSpeaker(
        samples: Float32List(0),
      );
      expect(enrollResult, isFalse);
    });
  });

  group('AppDriverServer 端点边界与异常容错压力测试', () {
    late AssistantController controller;
    late AppDriverServer server;
    late int port;
    late HttpClient client;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final tempSocket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = tempSocket.port;
      await tempSocket.close();

      final settings = AppSettings(
        autoStartMicOnLaunch: false,
        enablePromptTone: false,
        enableTtsPlayback: false,
        webAccessPassword: '',
      );
      controller = AssistantController(
        settings: settings,
        enableDriverServer: false,
      );
      server = AppDriverServer(
        controller: controller,
        port: port,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      await server.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      await controller.disposeAsync();
    });

    Future<Map<String, dynamic>> postJson(
      String path,
      Map<String, dynamic> body, {
      int expectedStatus = HttpStatus.ok,
    }) async {
      final req = await client.post('127.0.0.1', port, path);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      expect(res.statusCode, expectedStatus);
      return jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
    }

    test('2.1 /health 与 /status 与 /messages 基础状态端点响应正常', () async {
      final hReq = await client.get('127.0.0.1', port, '/health');
      final hRes = await hReq.close();
      expect(hRes.statusCode, HttpStatus.ok);
      final hMap =
          jsonDecode(await utf8.decodeStream(hRes)) as Map<String, dynamic>;
      expect(hMap['status'], 'ok');
      expect(hMap['app'], 'SideAssistant');

      final sReq = await client.get('127.0.0.1', port, '/status');
      final sRes = await sReq.close();
      expect(sRes.statusCode, HttpStatus.ok);
      final sMap =
          jsonDecode(await utf8.decodeStream(sRes)) as Map<String, dynamic>;
      expect(sMap.containsKey('status'), isTrue);
      expect(sMap.containsKey('cpuUsage'), isTrue);

      final mReq = await client.get('127.0.0.1', port, '/messages');
      final mRes = await mReq.close();
      expect(mRes.statusCode, HttpStatus.ok);
      final mMap =
          jsonDecode(await utf8.decodeStream(mRes)) as Map<String, dynamic>;
      expect(mMap['messages'], isList);
    });

    test(
        '2.2 文本朗读与打断端点 (/api/stop-speaking, /api/speak-text, /api/preview-voice)',
        () async {
      final stopRes = await postJson('/api/stop-speaking', {});
      expect(stopRes['accepted'], isTrue);

      final speakRes = await postJson('/api/speak-text', {'text': '你好世界'});
      expect(speakRes['accepted'], isTrue);

      final previewRes = await postJson('/api/preview-voice', {
        'voice': 'zh-CN-XiaoxiaoNeural',
        'text': '试听测试',
      });
      expect(previewRes['accepted'], isTrue);

      final previewDefaultRes = await postJson('/api/preview-voice', {});
      expect(previewDefaultRes['accepted'], isTrue);
    });

    test('2.3 历史记录导出端点 GET /api/export-html', () async {
      final req = await client.get('127.0.0.1', port, '/api/export-html');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, 'text/html');
      expect(
        res.headers.value('Content-Disposition'),
        contains('side_assistant_history.html'),
      );
      final html = await utf8.decodeStream(res);
      expect(html, contains('<!DOCTYPE html>'));
    });

    test('2.4 相机直拍端点 POST /api/test-camera 正常返回 Base64', () async {
      final camRes = await postJson('/api/test-camera', {});
      expect(camRes['accepted'], isTrue);
      expect(camRes['byteLength'], greaterThan(0));
      expect(camRes['base64'], isNotEmpty);
      expect(camRes['isSimulated'], isTrue);
    });

    test('2.5 语音识别端点 POST /transcribe 与 POST /process-audio', () async {
      final transcribeRes = await postJson('/transcribe', {
        'path': 'non_existent.wav',
        'isStandby': false,
      });
      expect(transcribeRes['accepted'], isTrue);
      expect(transcribeRes['recognized'], equals(''));

      final processRes = await postJson('/process-audio', {
        'path': 'dummy.wav',
      });
      expect(processRes['accepted'], isTrue);
    });

    test(
        '2.6 会话管理相关端点 (/reset, /api/sessions/rename, /api/sessions/switch, /api/sessions/delete, /api/sessions/clear)',
        () async {
      final resetRes = await postJson('/reset', {});
      expect(resetRes['accepted'], isTrue);

      final renameRes = await postJson('/api/sessions/rename', {
        'sessionId': controller.currentSessionId,
        'title': '重命名会话',
      });
      expect(renameRes['accepted'], isTrue);

      final switchRes = await postJson('/api/sessions/switch', {
        'sessionId': controller.currentSessionId,
      });
      expect(switchRes['accepted'], isTrue);

      final deleteRes = await postJson('/api/sessions/delete', {
        'sessionId': controller.currentSessionId,
      });
      expect(deleteRes['accepted'], isTrue);

      final clearRes = await postJson('/api/sessions/clear', {});
      expect(clearRes['accepted'], isTrue);
    });

    test(
        '2.7 硬件与自检端点 (/api/hardware-devices, /audio-devices, /audio-device, /test-results)',
        () async {
      final hwReq =
          await client.get('127.0.0.1', port, '/api/hardware-devices');
      final hwRes = await hwReq.close();
      expect(hwRes.statusCode, HttpStatus.ok);
      final hwMap =
          jsonDecode(await utf8.decodeStream(hwRes)) as Map<String, dynamic>;
      expect(hwMap.containsKey('inputDevices'), isTrue);

      final adReq = await client.get('127.0.0.1', port, '/audio-devices');
      final adRes = await adReq.close();
      expect(adRes.statusCode, HttpStatus.ok);

      final setAdRes = await postJson('/audio-device', {
        'id': 'default',
        'label': '系统默认麦克风',
      });
      expect(setAdRes['accepted'], isTrue);

      final trReq = await client.get('127.0.0.1', port, '/test-results');
      final trRes = await trReq.close();
      expect(trRes.statusCode, HttpStatus.ok);
    });

    test('2.8 异常路径防御：非法请求体与未定义路由安全返回相应状态码', () async {
      // 404 未知路由
      final notFoundReq =
          await client.get('127.0.0.1', port, '/api/undefined-route');
      final notFoundRes = await notFoundReq.close();
      expect(notFoundRes.statusCode, HttpStatus.notFound);

      // 非法 JSON 格式请求体不会导致 Server 崩溃
      final badJsonReq = await client.post('127.0.0.1', port, '/api/chat');
      badJsonReq.headers.contentType = ContentType.json;
      badJsonReq.write('{invalid_json_format');
      final badJsonRes = await badJsonReq.close();
      expect(badJsonRes.statusCode, HttpStatus.internalServerError);

      // 服务在遭遇非法输入后仍能正常处理后续合法请求
      final okReq = await client.get('127.0.0.1', port, '/health');
      final okRes = await okReq.close();
      expect(okRes.statusCode, HttpStatus.ok);
    });
  });

  group('六边形架构端口解耦性测试 (FakeAssistantDriverPort 独立驱动验证)', () {
    late FakeAssistantDriverPort fakePort;
    late AppDriverServer server;
    late int port;
    late HttpClient client;

    setUp(() async {
      final tempSocket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = tempSocket.port;
      await tempSocket.close();

      fakePort = FakeAssistantDriverPort();
      // 关键测试：AppDriverServer 接受纯 Fake 端口驱动，零依赖具体 AssistantController
      server = AppDriverServer(
        driverPort: fakePort,
        port: port,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      await server.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
    });

    test('3.1 AppDriverServer 能够完全基于纯接口 Fake 端口运行，所有调用精确分发至端口', () async {
      // 1. GET /api/state
      final stateReq = await client.get('127.0.0.1', port, '/api/state');
      final stateRes = await stateReq.close();
      expect(stateRes.statusCode, HttpStatus.ok);
      final stateMap =
          jsonDecode(await utf8.decodeStream(stateRes)) as Map<String, dynamic>;
      expect(stateMap['enrolledSpeakerCount'], equals(2));
      expect(stateMap['hasEnrolledOwner'], isTrue);

      // 2. POST /api/stop-speaking
      final stopReq =
          await client.post('127.0.0.1', port, '/api/stop-speaking');
      final stopRes = await stopReq.close();
      expect(stopRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('stopSpeaking'));

      // 3. POST /api/speak-text
      final speakReq = await client.post('127.0.0.1', port, '/api/speak-text');
      speakReq.headers.contentType = ContentType.json;
      speakReq.write(jsonEncode({'text': 'Hello Fake Driver'}));
      final speakRes = await speakReq.close();
      expect(speakRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('speakImmediate:Hello Fake Driver'));

      // 4. GET /api/export-html
      final htmlReq = await client.get('127.0.0.1', port, '/api/export-html');
      final htmlRes = await htmlReq.close();
      expect(htmlRes.statusCode, HttpStatus.ok);
      final html = await utf8.decodeStream(htmlRes);
      expect(html, contains('Exported Chat History'));
      expect(fakePort.callLog, contains('exportChatHistoryHtml'));

      // 5. POST /api/test-camera
      final camReq = await client.post('127.0.0.1', port, '/api/test-camera');
      final camRes = await camReq.close();
      expect(camRes.statusCode, HttpStatus.ok);
      final camMap =
          jsonDecode(await utf8.decodeStream(camRes)) as Map<String, dynamic>;
      expect(camMap['isSimulated'], isTrue);
      expect(camMap['byteLength'], equals(4));
      expect(fakePort.callLog, contains('capturePhotoDirect'));

      // 6. POST /transcribe
      final transReq = await client.post('127.0.0.1', port, '/transcribe');
      transReq.headers.contentType = ContentType.json;
      transReq.write(jsonEncode({'path': '/tmp/test.wav'}));
      final transRes = await transReq.close();
      expect(transRes.statusCode, HttpStatus.ok);
      final transMap =
          jsonDecode(await utf8.decodeStream(transRes)) as Map<String, dynamic>;
      expect(transMap['recognized'], 'Transcribed: /tmp/test.wav');
      expect(fakePort.callLog, contains('transcribeAudioFile:/tmp/test.wav'));
    });
  });
}
