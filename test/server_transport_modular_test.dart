import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/core/models/chat_session.dart';
import 'package:side_assistant/core/platform/foundation_bridge.dart';
import 'package:side_assistant/services/automation/app_driver_server.dart';
import 'package:side_assistant/core/ports/assistant_driver_port.dart';

class ModularTestFakeDriverPort implements AssistantDriverPort {
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
  bool isMicListening = true;
  @override
  bool isManualRecording = false;
  @override
  bool isQuickCapturing = false;
  @override
  double micLevel = 0.25;
  @override
  double micDbfs = -24.0;
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
    playbackVolume: 75,
    webAccessPassword: '',
    edgeVoice: 'zh-CN-XiaoxiaoNeural',
  );
  @override
  int enrolledSpeakerCount = 3;
  @override
  bool hasEnrolledOwner = true;
  @override
  String speakerModelLabel = 'ModularSpeakerModel';
  @override
  String? lastEnrollError;
  @override
  bool isInContinuousMode = false;
  @override
  String currentSessionId = 'session-mod-1';
  @override
  List<ChatMessage> messages = [];
  @override
  List<ChatSession> sessions = [];
  @override
  bool isSelfTesting = false;
  @override
  List<String> selfTestLogs = ['Init OK', 'Driver Ready'];
  @override
  String activeAudioInputDeviceLabel = 'Virtual Mic';

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
  Future<void> simulateUserInput(String text) async =>
      callLog.add('simulateUserInput:$text');
  @override
  Future<void> sendDirectUserMessage(String text) async =>
      callLog.add('sendDirectUserMessage:$text');
  @override
  Future<void> sendTextMessage(String text) async =>
      callLog.add('sendTextMessage:$text');
  @override
  Future<void> captureAndAskAboutScene({String question = '这是什么，介绍一下'}) async =>
      callLog.add('captureAndAskAboutScene:$question');
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
  Future<void> toggleMicListening() async {
    callLog.add('toggleMicListening');
    isMicListening = !isMicListening;
  }

  @override
  Future<void> setMicTestMode(bool enabled, {bool clear = false}) async {
    callLog.add('setMicTestMode:$enabled,clear:$clear');
    isMicTesting = enabled;
  }

  @override
  Future<void> processAudioFile(String filePath) async {
    callLog.add('processAudioFile:$filePath');
    lastRecognizedSpeech = 'Processed audio';
  }

  @override
  Future<String?> transcribeAudioFile(String path,
      {bool isStandbyWakeCheck = false}) async {
    callLog.add('transcribeAudioFile:$path,standby:$isStandbyWakeCheck');
    return 'Transcribed: $path';
  }

  @override
  Future<void> setAudioInputDevice(String id, String label) async {
    callLog.add('setAudioInputDevice:$id,$label');
    settings.audioInputDeviceId = id;
    settings.audioInputDeviceLabel = label;
    activeAudioInputDeviceLabel = label;
  }

  @override
  Future<void> setPlaybackVolume(int volume) async {
    callLog.add('setPlaybackVolume:$volume');
    settings.playbackVolume = volume;
  }

  @override
  Future<void> stopSpeaking() async => callLog.add('stopSpeaking');
  @override
  Future<void> speakImmediate(String text) async =>
      callLog.add('speakImmediate:$text');
  @override
  Future<void> previewVoice({String? voice, String? text}) async =>
      callLog.add('previewVoice:$voice,$text');
  @override
  Future<bool> recordAndEnrollOwnerSpeaker({double seconds = 3.5}) async {
    callLog.add('recordAndEnrollOwnerSpeaker:$seconds');
    enrolledSpeakerCount++;
    return true;
  }

  @override
  Future<bool> enrollOwnerSpeaker({Float32List? samples}) async {
    callLog.add('enrollOwnerSpeaker');
    enrolledSpeakerCount++;
    return true;
  }

  @override
  Future<void> clearOwnerSpeaker() async {
    callLog.add('clearOwnerSpeaker');
    enrolledSpeakerCount = 0;
  }

  @override
  Future<Map<String, dynamic>> recordAndTestOwnerSpeakerSimilarity(
      {double seconds = 3.0}) async {
    callLog.add('recordAndTestOwnerSpeakerSimilarity:$seconds');
    return {'score': 0.88, 'accepted': true};
  }

  @override
  Future<Map<String, dynamic>> testOwnerSpeakerSimilarity(
      {Float32List? samples}) async {
    callLog.add('testOwnerSpeakerSimilarity');
    return {'score': 0.92, 'accepted': true};
  }

  @override
  Float32List? getRecentAudioSnippet({double seconds = 3.0}) {
    callLog.add('getRecentAudioSnippet:$seconds');
    return Float32List(16000 * 3);
  }

  @override
  Future<void> updateSettings(AppSettings newSettings) async {
    callLog.add('updateSettings');
    settings = newSettings;
  }

  @override
  Future<String> testGeminiAsrConnection(
      {String? apiKey, String? model}) async {
    callLog.add('testGeminiAsrConnection:$model');
    return 'Gemini connection successful';
  }

  @override
  Future<void> startNewSession({bool playVoice = false}) async {
    callLog.add('startNewSession:$playVoice');
    currentSessionId = 'session-mod-new';
  }

  @override
  Future<void> switchSession(String sessionId) async {
    callLog.add('switchSession:$sessionId');
    currentSessionId = sessionId;
  }

  @override
  Future<void> renameSession(String sessionId, String newTitle) async =>
      callLog.add('renameSession:$sessionId,$newTitle');

  @override
  Future<void> deleteSession(String sessionId) async =>
      callLog.add('deleteSession:$sessionId');

  @override
  Future<void> clearAllHistory() async {
    callLog.add('clearAllHistory');
    messages.clear();
    sessions.clear();
  }

  @override
  Future<String> exportChatHistoryHtml() async =>
      '<!DOCTYPE html><html><body>Modular Export History</body></html>';

  @override
  Future<CameraCaptureResult> capturePhotoDirect() async {
    callLog.add('capturePhotoDirect');
    return CameraCaptureResult(
      imageBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
      filePath: '/tmp/modular_shot.jpg',
      isSimulated: true,
    );
  }

  @override
  Future<Map<String, dynamic>> runDiagnosticSelfTest() async => {
        'overall': 'pass',
        'checks': {'audio': 'ok', 'network': 'ok'}
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late ModularTestFakeDriverPort fakePort;
  late AppDriverServer server;
  late int port;
  late HttpClient client;

  setUp(() async {
    final tempSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = tempSocket.port;
    await tempSocket.close();

    fakePort = ModularTestFakeDriverPort();
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

  group('Group 1: Middleware & Routing Infrastructure', () {
    test('1.1 OPTIONS 预检请求返回 200 并携带标准 CORS 响应头', () async {
      final req = await client.open('OPTIONS', '127.0.0.1', port, '/api/chat');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.value('Access-Control-Allow-Origin'), '*');
      expect(res.headers.value('Access-Control-Allow-Methods'),
          contains('GET, POST, OPTIONS'));
      expect(res.headers.value('Access-Control-Allow-Headers'),
          contains('Content-Type, Authorization, X-Access-Password'));
    });

    test('1.2 所有常规端点响应均自动注入 Access-Control-Allow-Origin: *', () async {
      final req = await client.get('127.0.0.1', port, '/health');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.value('Access-Control-Allow-Origin'), '*');
    });

    test('1.3 未配置密码时所有端点免鉴权正常访问', () async {
      fakePort.settings.webAccessPassword = '';
      final req = await client.get('127.0.0.1', port, '/status');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
    });

    test('1.4 配置密码后白名单路由 (/, /index.html, /health) 仍免鉴权访问', () async {
      fakePort.settings.webAccessPassword = 'secret_password_123';
      final hReq = await client.get('127.0.0.1', port, '/health');
      final hRes = await hReq.close();
      expect(hRes.statusCode, HttpStatus.ok);

      final idxReq = await client.get('127.0.0.1', port, '/index.html');
      final idxRes = await idxReq.close();
      expect(idxRes.statusCode, HttpStatus.ok);
    });

    test('1.5 配置密码后三类鉴权凭证均能成功鉴权 (Header, Bearer, Query ?token=)', () async {
      fakePort.settings.webAccessPassword = 'my_secure_token';

      // Header 凭证
      final hReq = await client.get('127.0.0.1', port, '/status');
      hReq.headers.set('X-Access-Password', 'my_secure_token');
      final hRes = await hReq.close();
      expect(hRes.statusCode, HttpStatus.ok);

      // Bearer 凭证
      final bReq = await client.get('127.0.0.1', port, '/status');
      bReq.headers.set('Authorization', 'Bearer my_secure_token');
      final bRes = await bReq.close();
      expect(bRes.statusCode, HttpStatus.ok);

      // Query token 凭证
      final qReq =
          await client.get('127.0.0.1', port, '/status?token=my_secure_token');
      final qRes = await qReq.close();
      expect(qRes.statusCode, HttpStatus.ok);
    });

    test('1.6 携带错误密码或缺失密码统一返回 401 Unauthorized', () async {
      fakePort.settings.webAccessPassword = 'correct_password';

      // 缺失密码
      final noPwdReq = await client.get('127.0.0.1', port, '/status');
      final noPwdRes = await noPwdReq.close();
      expect(noPwdRes.statusCode, HttpStatus.unauthorized);

      // 错误密码
      final badPwdReq = await client.get('127.0.0.1', port, '/status');
      badPwdReq.headers.set('X-Access-Password', 'wrong_pwd');
      final badPwdRes = await badPwdReq.close();
      expect(badPwdRes.statusCode, HttpStatus.unauthorized);
    });

    test('1.7 未定义路径及 HTTP 方法不匹配安全返回 404 Not Found', () async {
      // 路径未定义
      final unkReq =
          await client.get('127.0.0.1', port, '/non-existent-endpoint');
      final unkRes = await unkReq.close();
      expect(unkRes.statusCode, HttpStatus.notFound);

      // 方法不匹配 (POST /health)
      final badMethodReq = await client.post('127.0.0.1', port, '/health');
      final badMethodRes = await badMethodReq.close();
      expect(badMethodRes.statusCode, HttpStatus.notFound);
    });

    test('1.8 处理器抛出未捕获异常被全局 Error Boundary 拦截并返回 500', () async {
      final req = await client.post('127.0.0.1', port, '/api/chat');
      req.headers.contentType = ContentType.json;
      req.write('{malformed_json_here');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.internalServerError);
    });
  });

  group('Group 2: SSE 实时事件流与生命周期 (GET /api/events)', () {
    test('2.1 连接 SSE 端点立即返回 text/event-stream 并下发初始状态 payload', () async {
      final req = await client.get('127.0.0.1', port, '/api/events');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, 'text/event-stream');

      final completer = Completer<String>();
      late StreamSubscription sub;
      sub = res.transform(utf8.decoder).listen((chunk) {
        if (!completer.isCompleted && chunk.startsWith('data: ')) {
          completer.complete(chunk);
          sub.cancel();
        }
      });

      final initialChunk =
          await completer.future.timeout(const Duration(seconds: 3));
      expect(initialChunk, contains('"status":"idle"'));
      expect(initialChunk, contains('"enrolledSpeakerCount":3'));
    });

    test('2.2 DriverPort 触发状态通知时，活跃 SSE 客户端收到广播', () async {
      final req = await client.get('127.0.0.1', port, '/api/events');
      final res = await req.close();

      final chunks = <String>[];
      final completer = Completer<void>();

      final sub = res.transform(utf8.decoder).listen((chunk) {
        chunks.add(chunk);
        if (chunks.length >= 2 && !completer.isCompleted) {
          completer.complete();
        }
      });

      // 等待初始连接建立后触发状态变更
      await Future.delayed(const Duration(milliseconds: 50));
      fakePort.status = AssistantStatus.thinking;
      fakePort.notify();

      await completer.future.timeout(const Duration(seconds: 3));
      await sub.cancel();

      final secondChunk = chunks[1];
      expect(secondChunk, contains('"status":"thinking"'));
    });

    test('2.3 SSE 客户端断开连接后不引发服务端异常', () async {
      final req = await client.get('127.0.0.1', port, '/api/events');
      final res = await req.close();
      // 快速主动断开客户端连接
      await res.detachSocket().then((s) => s.destroy());

      // 触发一次广播，确保服务端无抛错无泄漏
      fakePort.notify();
      await Future.delayed(const Duration(milliseconds: 50));
      expect(server.isRunning, isTrue);
    });

    test('2.4 AppDriverServer.stop() 优雅关闭所有存量 SSE 客户端并停止服务', () async {
      final req = await client.get('127.0.0.1', port, '/api/events');
      final res = await req.close();

      final doneCompleter = Completer<void>();
      res.listen(
        (_) {},
        onDone: () => doneCompleter.complete(),
      );

      await server.stop();
      await doneCompleter.future.timeout(const Duration(seconds: 2));
      expect(server.isRunning, isFalse);
    });
  });

  group('Group 3: 文件服务与导出端点', () {
    test('3.1 GET /api/export-html 返回 HTML 附件头及完整内容', () async {
      final req = await client.get('127.0.0.1', port, '/api/export-html');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.value('Content-Disposition'),
          contains('attachment; filename="side_assistant_history.html"'));
      final html = await utf8.decodeStream(res);
      expect(html, contains('Modular Export History'));
    });

    test('3.2 GET /api/image 通过 path 参数返回图片二进制与 image/jpeg 类型', () async {
      final tempDir = Directory.systemTemp.createTempSync('modular_img_test_');
      final imgFile = File('${tempDir.path}/sample.jpg');
      await imgFile.writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0, 0x01, 0x02]);

      final req = await client.get('127.0.0.1', port,
          '/api/image?path=${Uri.encodeComponent(imgFile.path)}');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, 'image/jpeg');
      final bytes = await res.fold<List<int>>([], (p, e) => p..addAll(e));
      expect(bytes.length, equals(6));

      tempDir.deleteSync(recursive: true);
    });

    test('3.3 GET /api/image 通过 msgId 参数检索消息图片并成功返回', () async {
      final tempDir = Directory.systemTemp.createTempSync('modular_msg_img_');
      final imgFile = File('${tempDir.path}/msg_shot.jpg');
      await imgFile.writeAsBytes([0xFF, 0xD8, 0xFF, 0xE0]);

      fakePort.messages.add(ChatMessage(
        id: 'msg-with-image',
        role: 'assistant',
        content: 'Photo',
        imagePath: imgFile.path,
        timestamp: DateTime.now(),
      ));

      final req = await client.get(
          '127.0.0.1', port, '/api/image?msgId=msg-with-image');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(res.headers.contentType?.mimeType, 'image/jpeg');

      tempDir.deleteSync(recursive: true);
    });

    test('3.4 GET /api/image 图片不存在或 msgId 非法时返回 404', () async {
      final req = await client.get(
          '127.0.0.1', port, '/api/image?msgId=non-existent-msg');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.notFound);
    });
  });

  group('Group 4: 10 大领域处理器功能与边界验证', () {
    test('4.1 ChatHandler: /simulate 与 /api/chat 支持正常会话与空文本 400 校验', () async {
      // 空文本校验
      final badSim = await client.post('127.0.0.1', port, '/simulate');
      badSim.headers.contentType = ContentType.json;
      badSim.write(jsonEncode({'text': ''}));
      final badSimRes = await badSim.close();
      expect(badSimRes.statusCode, HttpStatus.badRequest);

      // 正常模拟
      final sim = await client.post('127.0.0.1', port, '/simulate');
      sim.headers.contentType = ContentType.json;
      sim.write(jsonEncode({'text': '你好助手'}));
      final simRes = await sim.close();
      expect(simRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('simulateUserInput:你好助手'));

      // /api/chat speak=true
      final chat = await client.post('127.0.0.1', port, '/api/chat');
      chat.headers.contentType = ContentType.json;
      chat.write(jsonEncode({'text': '播报测试', 'speak': true}));
      final chatRes = await chat.close();
      expect(chatRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('sendDirectUserMessage:播报测试'));
    });

    test('4.2 ChatHandler: /api/capture-and-ask 支持传入自定义问题或默认问题', () async {
      final req = await client.post('127.0.0.1', port, '/api/capture-and-ask');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'question': '这是什么植物？'}));
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('captureAndAskAboutScene:这是什么植物？'));
    });

    test('4.3 AudioHandler: /toggle-mic 与 /api/manual-record 状态切换', () async {
      final togReq = await client.post('127.0.0.1', port, '/toggle-mic');
      final togRes = await togReq.close();
      expect(togRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('toggleMicListening'));

      final startRec =
          await client.post('127.0.0.1', port, '/api/manual-record/start');
      final startRes = await startRec.close();
      expect(startRes.statusCode, HttpStatus.ok);
      expect(fakePort.isManualRecording, isTrue);

      final stopRec =
          await client.post('127.0.0.1', port, '/api/manual-record/stop');
      final stopRes = await stopRec.close();
      expect(stopRes.statusCode, HttpStatus.ok);
      expect(fakePort.isManualRecording, isFalse);
    });

    test('4.4 AudioHandler: /process-audio 与 /transcribe 音频转录处理', () async {
      final proc = await client.post('127.0.0.1', port, '/process-audio');
      proc.headers.contentType = ContentType.json;
      proc.write(jsonEncode({'path': '/tmp/test.wav'}));
      final procRes = await proc.close();
      expect(procRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('processAudioFile:/tmp/test.wav'));

      final trans = await client.post('127.0.0.1', port, '/transcribe');
      trans.headers.contentType = ContentType.json;
      trans.write(jsonEncode({'path': '/tmp/test2.wav', 'isStandby': true}));
      final transRes = await trans.close();
      expect(transRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog,
          contains('transcribeAudioFile:/tmp/test2.wav,standby:true'));
    });

    test('4.5 DeviceHandler: /audio-device 与 /api/volume 调节', () async {
      final devReq = await client.post('127.0.0.1', port, '/audio-device');
      devReq.headers.contentType = ContentType.json;
      devReq.write(jsonEncode({'id': 'mic_usb_1', 'label': 'USB Microphone'}));
      final devRes = await devReq.close();
      expect(devRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog,
          contains('setAudioInputDevice:mic_usb_1,USB Microphone'));

      final volReq = await client.post('127.0.0.1', port, '/api/volume');
      volReq.headers.contentType = ContentType.json;
      volReq.write(jsonEncode({'volume': 90}));
      final volRes = await volReq.close();
      expect(volRes.statusCode, HttpStatus.ok);
      expect(fakePort.settings.playbackVolume, equals(90));
    });

    test(
        '4.6 TtsHandler: /api/stop-speaking, /api/speak-text, /api/preview-voice',
        () async {
      final stopReq =
          await client.post('127.0.0.1', port, '/api/stop-speaking');
      final stopRes = await stopReq.close();
      expect(stopRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('stopSpeaking'));

      final speakReq = await client.post('127.0.0.1', port, '/api/speak-text');
      speakReq.headers.contentType = ContentType.json;
      speakReq.write(jsonEncode({'text': '即时朗读'}));
      final speakRes = await speakReq.close();
      expect(speakRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('speakImmediate:即时朗读'));

      final prevReq =
          await client.post('127.0.0.1', port, '/api/preview-voice');
      prevReq.headers.contentType = ContentType.json;
      prevReq
          .write(jsonEncode({'voice': 'zh-CN-YunxiNeural', 'text': '试听样例文本'}));
      final prevRes = await prevReq.close();
      expect(prevRes.statusCode, HttpStatus.ok);
      expect(
          fakePort.callLog, contains('previewVoice:zh-CN-YunxiNeural,试听样例文本'));
    });

    test('4.7 SpeakerHandler: /api/speaker/enroll, clear, test 声纹处理流程',
        () async {
      final enrollReq =
          await client.post('127.0.0.1', port, '/api/speaker/enroll');
      enrollReq.headers.contentType = ContentType.json;
      enrollReq.write(jsonEncode({'record': true, 'seconds': 4.0}));
      final enrollRes = await enrollReq.close();
      expect(enrollRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('recordAndEnrollOwnerSpeaker:4.0'));

      final testReq = await client.post('127.0.0.1', port, '/api/speaker/test');
      testReq.headers.contentType = ContentType.json;
      testReq.write(jsonEncode({'record': true, 'seconds': 3.0}));
      final testRes = await testReq.close();
      expect(testRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog,
          contains('recordAndTestOwnerSpeakerSimilarity:3.0'));

      final clearReq =
          await client.post('127.0.0.1', port, '/api/speaker/clear');
      final clearRes = await clearReq.close();
      expect(clearRes.statusCode, HttpStatus.ok);
      expect(fakePort.enrolledSpeakerCount, equals(0));
    });

    test('4.8 SettingsHandler: /api/settings 与 /api/test-gemini', () async {
      final getSet = await client.get('127.0.0.1', port, '/api/settings');
      final getSetRes = await getSet.close();
      expect(getSetRes.statusCode, HttpStatus.ok);

      final updateSet = await client.post('127.0.0.1', port, '/api/settings');
      updateSet.headers.contentType = ContentType.json;
      updateSet.write(jsonEncode({'edgeVoice': 'zh-CN-YunjianNeural'}));
      final updateSetRes = await updateSet.close();
      expect(updateSetRes.statusCode, HttpStatus.ok);
      expect(fakePort.settings.edgeVoice, 'zh-CN-YunjianNeural');

      final testGem = await client.post('127.0.0.1', port, '/api/test-gemini');
      testGem.headers.contentType = ContentType.json;
      testGem.write(jsonEncode({'model': 'gemini-1.5-flash'}));
      final testGemRes = await testGem.close();
      expect(testGemRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog,
          contains('testGeminiAsrConnection:gemini-1.5-flash'));
    });

    test('4.9 SessionHandler: /api/sessions 列表、切换、重命名、删除与清空', () async {
      final listReq = await client.get('127.0.0.1', port, '/api/sessions');
      final listRes = await listReq.close();
      expect(listRes.statusCode, HttpStatus.ok);

      final swReq =
          await client.post('127.0.0.1', port, '/api/sessions/switch');
      swReq.headers.contentType = ContentType.json;
      swReq.write(jsonEncode({'sessionId': 'session-target'}));
      final swRes = await swReq.close();
      expect(swRes.statusCode, HttpStatus.ok);
      expect(fakePort.currentSessionId, 'session-target');

      final renReq =
          await client.post('127.0.0.1', port, '/api/sessions/rename');
      renReq.headers.contentType = ContentType.json;
      renReq
          .write(jsonEncode({'sessionId': 'session-target', 'title': '新会话名'}));
      final renRes = await renReq.close();
      expect(renRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('renameSession:session-target,新会话名'));

      final delReq =
          await client.post('127.0.0.1', port, '/api/sessions/delete');
      delReq.headers.contentType = ContentType.json;
      delReq.write(jsonEncode({'sessionId': 'session-target'}));
      final delRes = await delReq.close();
      expect(delRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('deleteSession:session-target'));

      final clrReq =
          await client.post('127.0.0.1', port, '/api/sessions/clear');
      final clrRes = await clrReq.close();
      expect(clrRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('clearAllHistory'));
    });

    test(
        '4.10 DiagnosticsHandler: /run-self-test 与 /test-results, /api/test-camera 诊断自检',
        () async {
      final testCam = await client.post('127.0.0.1', port, '/api/test-camera');
      testCam.headers.contentType = ContentType.json;
      testCam.write(jsonEncode({'device': '/dev/video1'}));
      final testCamRes = await testCam.close();
      expect(testCamRes.statusCode, HttpStatus.ok);
      expect(fakePort.callLog, contains('capturePhotoDirect'));

      final runDiag = await client.post('127.0.0.1', port, '/run-self-test');
      final runDiagRes = await runDiag.close();
      expect(runDiagRes.statusCode, HttpStatus.ok);
      final diagMap = jsonDecode(await utf8.decodeStream(runDiagRes))
          as Map<String, dynamic>;
      expect(diagMap['overall'], 'pass');

      final getResults = await client.get('127.0.0.1', port, '/test-results');
      final getResultsRes = await getResults.close();
      expect(getResultsRes.statusCode, HttpStatus.ok);
      final resMap = jsonDecode(await utf8.decodeStream(getResultsRes))
          as Map<String, dynamic>;
      expect(resMap['isSelfTesting'], isFalse);
    });

    test(
        '4.11 CustomToolsHandler: /api/custom-tools 与 /api/custom-tools/delete, DELETE 端点',
        () async {
      // 1. GET /api/custom-tools
      final getReq = await client.get('127.0.0.1', port, '/api/custom-tools');
      final getRes = await getReq.close();
      expect(getRes.statusCode, HttpStatus.ok);
      final getData =
          jsonDecode(await utf8.decodeStream(getRes)) as Map<String, dynamic>;
      expect(getData.containsKey('tools'), isTrue);
      expect(getData['tools'], isA<List>());

      // 2. POST /api/custom-tools/delete 空 name 校验返回 400
      final badDel =
          await client.post('127.0.0.1', port, '/api/custom-tools/delete');
      badDel.headers.contentType = ContentType.json;
      badDel.write(jsonEncode({'name': ''}));
      final badDelRes = await badDel.close();
      expect(badDelRes.statusCode, HttpStatus.badRequest);

      // 3. POST /api/custom-tools/delete 正常删除调用 (不存在的工具返回 deleted: false)
      final delReq =
          await client.post('127.0.0.1', port, '/api/custom-tools/delete');
      delReq.headers.contentType = ContentType.json;
      delReq.write(jsonEncode({'name': 'non_existent_tool_123'}));
      final delRes = await delReq.close();
      expect(delRes.statusCode, HttpStatus.ok);
      final delData =
          jsonDecode(await utf8.decodeStream(delRes)) as Map<String, dynamic>;
      expect(delData['deleted'], isFalse);
      expect(delData['name'], 'non_existent_tool_123');
      expect(delData.containsKey('tools'), isTrue);

      // 4. DELETE /api/custom-tools/:name 端点校验
      final delParamReq = await client.delete(
          '127.0.0.1', port, '/api/custom-tools/non_existent_tool_123');
      final delParamRes = await delParamReq.close();
      expect(delParamRes.statusCode, HttpStatus.ok);
      final delParamData = jsonDecode(await utf8.decodeStream(delParamRes))
          as Map<String, dynamic>;
      expect(delParamData['deleted'], isFalse);
      expect(delParamData['name'], 'non_existent_tool_123');
    });
  });
}
