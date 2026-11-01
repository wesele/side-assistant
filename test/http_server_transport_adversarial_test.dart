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
import 'package:side_assistant/services/automation/http_router.dart';
import 'package:side_assistant/services/automation/sse_client_manager.dart';

/// 专用于对抗性与高并发压力测试的 Fake Driver Port
class AdversarialFakeDriverPort implements AssistantDriverPort {
  final List<String> callLog = [];
  final List<VoidCallback> _listeners = [];

  @override
  AssistantStatus status = AssistantStatus.idle;
  @override
  String statusHint = '空闲中';
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
  double micLevel = 0.5;
  @override
  double micDbfs = -18.0;
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
    playbackVolume: 80,
    webAccessPassword: '',
    edgeVoice: 'zh-CN-XiaoxiaoNeural',
  );
  @override
  int enrolledSpeakerCount = 1;
  @override
  bool hasEnrolledOwner = true;
  @override
  String speakerModelLabel = 'AdvSpeakerModel';
  @override
  String? lastEnrollError;
  @override
  bool isInContinuousMode = false;
  @override
  String currentSessionId = 'session-adv-1';
  @override
  List<ChatMessage> messages = [
    ChatMessage(
      id: 'adv-msg-1',
      role: 'user',
      content: 'Adversarial Hello',
      timestamp: DateTime.now(),
      sessionId: 'session-adv-1',
    ),
  ];
  @override
  List<ChatSession> sessions = [
    ChatSession(
      id: 'session-adv-1',
      title: 'Adversarial Session',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      messages: [],
    ),
  ];
  @override
  bool isSelfTesting = false;
  @override
  List<String> selfTestLogs = ['Ready'];
  @override
  String activeAudioInputDeviceLabel = 'Test Virtual Mic';

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
  }

  @override
  Future<String?> transcribeAudioFile(String path, {bool isStandbyWakeCheck = false}) async {
    callLog.add('transcribeAudioFile:$path');
    return 'Transcribed: $path';
  }

  @override
  Future<void> setAudioInputDevice(String id, String label) async {
    callLog.add('setAudioInputDevice:$id,$label');
  }

  @override
  Future<void> setPlaybackVolume(int volume) async {
    callLog.add('setPlaybackVolume:$volume');
    settings.playbackVolume = volume;
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
    callLog.add('previewVoice:$voice,$text');
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
  }

  @override
  Future<Map<String, dynamic>> recordAndTestOwnerSpeakerSimilarity({double seconds = 3.0}) async {
    return {'score': 0.99, 'accepted': true};
  }

  @override
  Future<Map<String, dynamic>> testOwnerSpeakerSimilarity({Float32List? samples}) async {
    return {'score': 0.99, 'accepted': true};
  }

  @override
  Float32List? getRecentAudioSnippet({double seconds = 3.0}) {
    return Float32List(16000);
  }

  @override
  Future<void> updateSettings(AppSettings newSettings) async {
    callLog.add('updateSettings');
    settings = newSettings;
  }

  @override
  Future<String> testGeminiAsrConnection({String? apiKey, String? model}) async {
    return 'Gemini OK';
  }

  @override
  Future<void> startNewSession({bool playVoice = false}) async {
    currentSessionId = 'session-adv-new';
  }

  @override
  Future<void> switchSession(String sessionId) async {
    currentSessionId = sessionId;
  }

  @override
  Future<void> renameSession(String sessionId, String newTitle) async {}

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  Future<void> clearAllHistory() async {
    messages.clear();
    sessions.clear();
  }

  @override
  Future<String> exportChatHistoryHtml() async {
    return '<html><body>Adv HTML</body></html>';
  }

  @override
  Future<CameraCaptureResult> capturePhotoDirect() async {
    return CameraCaptureResult(
      imageBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0]),
      filePath: '/tmp/adv_shot.jpg',
      isSimulated: true,
    );
  }

  @override
  Future<Map<String, dynamic>> runDiagnosticSelfTest() async {
    return {'status': 'healthy'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late AdversarialFakeDriverPort fakePort;
  late AppDriverServer server;
  late int port;
  late HttpClient client;

  setUp(() async {
    final tempSocket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    port = tempSocket.port;
    await tempSocket.close();

    fakePort = AdversarialFakeDriverPort();
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

  group('Adversarial 1: HttpRouter 路径匹配、通配符与异常边缘测试', () {
    test('1.1 尾随斜杠 (Trailing Slash) 请求安全处理为 404 而不引起崩溃', () async {
      // 访问带尾随斜杠的静态路径 /health/ vs /health
      final req = await client.get('127.0.0.1', port, '/health/');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.notFound);
      final body = jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      expect(body['error'], 'Not found');
    });

    test('1.2 非法 HTTP 请求方法 (PUT, DELETE, PATCH, PURGE) 安全返回 404', () async {
      final verbs = ['PUT', 'DELETE', 'PATCH', 'PURGE', 'HEAD'];
      for (final verb in verbs) {
        final req = await client.open(verb, '127.0.0.1', port, '/health');
        final res = await req.close();
        expect(res.statusCode, HttpStatus.notFound, reason: 'Verb $verb on GET route should return 404');
        expect(res.headers.value('Access-Control-Allow-Origin'), '*');
      }
    });

    test('1.3 深度嵌套与超长路径 (Path Length > 2000 字符) 健壮处理', () async {
      final longPath = '/api/sessions/${'a' * 2500}';
      final req = await client.get('127.0.0.1', port, longPath);
      final res = await req.close();
      expect(res.statusCode, HttpStatus.notFound);
      expect(server.isRunning, isTrue);
    });

    test('1.4 特殊与编码字符路径 (URL-encoded traversal, unicode, null byte) 防御', () async {
      // URL-encoded 路径尝试
      final req1 = await client.get('127.0.0.1', port, '/api/sessions/%2e%2e/%2e%2e/test');
      final res1 = await req1.close();
      expect(res1.statusCode, anyOf(HttpStatus.notFound, HttpStatus.ok));

      // Unicode 特殊字符路径
      final req2 = await client.get('127.0.0.1', port, '/api/测%20试');
      final res2 = await req2.close();
      expect(res2.statusCode, HttpStatus.notFound);

      // 查询参数注入 XSS 探针
      final req3 = await client.get('127.0.0.1', port, '/health?q=<script>alert("xss")</script>&b=%00');
      final res3 = await req3.close();
      expect(res3.statusCode, HttpStatus.ok);
    });

    test('1.5 单元级 HttpRoute 正则编译与多参数/通配符严密性验证', () {
      final router = HttpRouter(driverPort: fakePort);

      // 1. 单参数路由
      router.get('/api/users/:userId', (_) {}, requiresAuth: false);
      // 2. 多参数路由
      router.get('/api/orgs/:orgId/repos/:repoId', (_) {}, requiresAuth: false);
      // 3. 通配符路由
      router.get('/static/*', (_) {}, requiresAuth: false);

      // 验证未编译正则的普通路由
      final staticRoute = HttpRoute(
        method: 'GET',
        pathPattern: '/exact/path',
        handler: (_) {},
      );
      expect(staticRoute.match('GET', '/exact/path'), equals({}));
      expect(staticRoute.match('GET', '/exact/path/extra'), isNull);
      expect(staticRoute.match('POST', '/exact/path'), isNull);

      // 验证参数提取
      final paramRoute = HttpRoute(
        method: 'GET',
        pathPattern: '/api/v1/:resource/:id',
        handler: (_) {},
      );
      final matchResult = paramRoute.match('GET', '/api/v1/devices/dev-99');
      expect(matchResult, isNotNull);
      expect(matchResult!['resource'], 'devices');
      expect(matchResult['id'], 'dev-99');

      // 验证通配符提取
      final wildcardRoute = HttpRoute(
        method: 'GET',
        pathPattern: '/files/*',
        handler: (_) {},
      );
      final wildMatch = wildcardRoute.match('GET', '/files/nested/dir/asset.png');
      expect(wildMatch, isNotNull);
    });
  });

  group('Adversarial 2: CORS 预检与全场景响应头渗透测试', () {
    test('2.1 OPTIONS 请求预检对任何路径均立即返回 200 并携带完整 CORS 头', () async {
      final testPaths = ['/', '/health', '/api/chat', '/non-existent-anywhere', '/api/sessions/foo/bar'];
      for (final p in testPaths) {
        final req = await client.open('OPTIONS', '127.0.0.1', port, p);
        req.headers.set('Origin', 'https://malicious-origin.attacker.com');
        req.headers.set('Access-Control-Request-Method', 'POST');
        final res = await req.close();
        expect(res.statusCode, HttpStatus.ok, reason: 'OPTIONS on $p must succeed');
        expect(res.headers.value('Access-Control-Allow-Origin'), '*');
        expect(res.headers.value('Access-Control-Allow-Methods'), contains('GET, POST, OPTIONS'));
        expect(res.headers.value('Access-Control-Allow-Headers'), contains('X-Access-Password'));
      }
    });

    test('2.2 401 Unauthorized 与 404 Not Found 响应亦严格包含 CORS 头', () async {
      fakePort.settings.webAccessPassword = 'strict_password';

      // 401 响应
      final unauthReq = await client.get('127.0.0.1', port, '/status');
      final unauthRes = await unauthReq.close();
      expect(unauthRes.statusCode, HttpStatus.unauthorized);
      expect(unauthRes.headers.value('Access-Control-Allow-Origin'), '*');

      // 404 响应
      final notFoundReq = await client.get('127.0.0.1', port, '/unknown-path');
      final notFoundRes = await notFoundReq.close();
      expect(notFoundRes.statusCode, HttpStatus.notFound);
      expect(notFoundRes.headers.value('Access-Control-Allow-Origin'), '*');
    });

    test('2.3 500 异常捕获响应同样注入 CORS 头，防止控制台跨域伪报错', () async {
      final req = await client.post('127.0.0.1', port, '/api/chat');
      req.headers.contentType = ContentType.json;
      req.write('{"invalid json: truncated');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.internalServerError);
      expect(res.headers.value('Access-Control-Allow-Origin'), '*');
    });
  });

  group('Adversarial 3: Web 鉴权绕过攻防测试 (Auth Bypass & Timing Attacks)', () {
    const validPassword = 'Target#P@ssw0rd!2026';

    setUp(() {
      fakePort.settings.webAccessPassword = validPassword;
    });

    test('3.1 鉴权大小写绕过攻击 (Case sensitivity attack)', () async {
      // 密码大小写微调
      final lowerReq = await client.get('127.0.0.1', port, '/status');
      lowerReq.headers.set('X-Access-Password', validPassword.toLowerCase());
      final lowerRes = await lowerReq.close();
      expect(lowerRes.statusCode, HttpStatus.unauthorized);

      // Bearer 头小写攻击 ('bearer ' vs 'Bearer ')
      final lowerBearerReq = await client.get('127.0.0.1', port, '/status');
      lowerBearerReq.headers.set('Authorization', 'bearer $validPassword');
      final lowerBearerRes = await lowerBearerReq.close();
      expect(lowerBearerRes.statusCode, HttpStatus.unauthorized);
    });

    test('3.2 截断与空字节注入攻击 (Null Byte / Prefix / Substring attack)', () async {
      // 前缀匹配尝试: validPassword + suffix
      final prefixReq = await client.get('127.0.0.1', port, '/status');
      prefixReq.headers.set('X-Access-Password', '$validPassword.extra');
      final prefixRes = await prefixReq.close();
      expect(prefixRes.statusCode, HttpStatus.unauthorized);

      // 子串截断尝试: validPassword 部分字符
      final subReq = await client.get('127.0.0.1', port, '/status');
      subReq.headers.set('X-Access-Password', validPassword.substring(0, 5));
      final subRes = await subReq.close();
      expect(subRes.statusCode, HttpStatus.unauthorized);
    });

    test('3.3 畸形 Authorization 头格式攻击', () async {
      final maliciousAuthHeaders = [
        'Bearer',
        'Bearer ',
        'Bearer   ',
        'Basic dXNlcjpwYXNz',
        'Token $validPassword',
        'Bearer $validPassword extra_token',
        'Bearer\t$validPassword',
      ];

      for (final header in maliciousAuthHeaders) {
        final req = await client.get('127.0.0.1', port, '/status');
        req.headers.set('Authorization', header);
        final res = await req.close();
        if (header == 'Bearer ' || header == 'Bearer   ') {
          // 纯空 token 绝不能通过
          expect(res.statusCode, HttpStatus.unauthorized, reason: 'Header "$header" should be rejected');
        } else if (!header.startsWith('Bearer ') || header.substring(7).trim() != validPassword) {
          expect(res.statusCode, HttpStatus.unauthorized, reason: 'Header "$header" should be rejected');
        }
      }
    });

    test('3.4 Query Token 参数篡改与大小写混淆攻击', () async {
      // 参数名为 Token（大写 T）
      final capReq = await client.get('127.0.0.1', port, '/status?Token=${Uri.encodeQueryComponent(validPassword)}');
      final capRes = await capReq.close();
      expect(capRes.statusCode, HttpStatus.unauthorized);

      // 参数为空
      final emptyReq = await client.get('127.0.0.1', port, '/status?token=');
      final emptyRes = await emptyReq.close();
      expect(emptyRes.statusCode, HttpStatus.unauthorized);

      // 未做 URL 编码的 # 导致截断为 Fragment (参数被截断为 Target) 严格拒绝 401
      final unencodedReq = await client.get('127.0.0.1', port, '/status?token=$validPassword');
      final unencodedRes = await unencodedReq.close();
      expect(unencodedRes.statusCode, HttpStatus.unauthorized);

      // 正确 URL-encoded 参数成功 200
      final okReq = await client.get('127.0.0.1', port, '/status?token=${Uri.encodeQueryComponent(validPassword)}');
      final okRes = await okReq.close();
      expect(okRes.statusCode, HttpStatus.ok);
    });

    test('3.5 鉴权状态下白名单免鉴权路径边界校验', () async {
      // 白名单开放路径
      for (final p in ['/', '/index.html', '/health']) {
        final req = await client.get('127.0.0.1', port, p);
        final res = await req.close();
        expect(res.statusCode, HttpStatus.ok, reason: 'Path $p must be whitelisted');
      }

      // 非白名单路径均严格拦截
      for (final p in ['/status', '/api/state', '/api/sessions', '/messages', '/test-results']) {
        final req = await client.get('127.0.0.1', port, p);
        final res = await req.close();
        expect(res.statusCode, HttpStatus.unauthorized, reason: 'Path $p must require auth');
      }
    });
  });

  group('Adversarial 4: SSE 实时事件流高并发与断连压力测试', () {
    test('4.1 多客户端 (20 并发) 连接并发接收全量初始状态', () async {
      const clientCount = 20;
      final clients = <HttpClient>[];
      final responses = <HttpClientResponse>[];
      final initialPayloadCompleters = List.generate(clientCount, (_) => Completer<String>());

      for (var i = 0; i < clientCount; i++) {
        final cl = HttpClient();
        clients.add(cl);
        final req = await cl.get('127.0.0.1', port, '/api/events');
        final res = await req.close();
        responses.add(res);

        expect(res.statusCode, HttpStatus.ok);
        expect(res.headers.contentType?.mimeType, 'text/event-stream');

        final comp = initialPayloadCompleters[i];
        late StreamSubscription sub;
        sub = res.transform(utf8.decoder).listen((chunk) {
          if (!comp.isCompleted && chunk.startsWith('data: ')) {
            comp.complete(chunk);
            sub.cancel();
          }
        });
      }

      // 等待所有 20 个客户端都收到初始全量 Payload
      final results = await Future.wait(
        initialPayloadCompleters.map((c) => c.future.timeout(const Duration(seconds: 5))),
      );
      expect(results.length, equals(clientCount));
      for (final r in results) {
        expect(r, contains('"status":"idle"'));
        expect(r, contains('"enrolledSpeakerCount":1'));
      }

      // 清理客户端连接
      for (final cl in clients) {
        cl.close(force: true);
      }
    });

    test('4.2 突发高频广播风暴压力测试 (Burst Broadcast Stress)', () async {
      final sseClient = HttpClient();
      final req = await sseClient.get('127.0.0.1', port, '/api/events');
      final res = await req.close();

      final receivedChunks = <String>[];
      final sub = res.transform(utf8.decoder).listen((chunk) {
        receivedChunks.add(chunk);
      });

      // 快速触发 25 次高频状态变更广播
      for (var i = 0; i < 25; i++) {
        fakePort.status = (i % 2 == 0) ? AssistantStatus.thinking : AssistantStatus.playing;
        fakePort.notify();
      }

      // 稍作等待以接收所有广播
      await Future.delayed(const Duration(milliseconds: 300));
      await sub.cancel();
      sseClient.close(force: true);

      // 应当收到初始状态 + 多次广播更新
      expect(receivedChunks.length, greaterThan(10));
      expect(server.isRunning, isTrue);
    });

    test('4.3 客户端猝死/断连套接字泄漏防御与自愈 (Abrupt Socket Destruction & Leakage Protection)', () async {
      // 建立 10 个客户端
      final sseClients = <HttpClient>[];
      final sockets = <Socket>[];

      for (var i = 0; i < 10; i++) {
        final cl = HttpClient();
        sseClients.add(cl);
        final req = await cl.get('127.0.0.1', port, '/api/events');
        final res = await req.close();
        final sock = await res.detachSocket();
        sockets.add(sock);
      }

      // 突然断开前 6 个客户端的底层 TCP Socket（模拟突发断网/崩溃）
      for (var i = 0; i < 6; i++) {
        sockets[i].destroy();
      }

      // 触发广播，驱动 SseClientManager 执行失联客户端清理与死链接踢出
      fakePort.status = AssistantStatus.listeningContent;
      fakePort.notify();
      await Future.delayed(const Duration(milliseconds: 100));

      // 剩余客户端及后续新客户端应能完全不受影响
      final survivorClient = HttpClient();
      final newReq = await survivorClient.get('127.0.0.1', port, '/api/events');
      final newRes = await newReq.close();
      expect(newRes.statusCode, HttpStatus.ok);

      final comp = Completer<String>();
      late StreamSubscription sub;
      sub = newRes.transform(utf8.decoder).listen((chunk) {
        if (!comp.isCompleted && chunk.startsWith('data: ')) {
          comp.complete(chunk);
          sub.cancel();
        }
      });

      final newPayload = await comp.future.timeout(const Duration(seconds: 3));
      expect(newPayload, contains('"status":"listeningContent"'));

      // 清理全部测试资源
      for (var i = 6; i < 10; i++) {
        sockets[i].destroy();
      }
      for (final cl in sseClients) {
        cl.close(force: true);
      }
      survivorClient.close(force: true);
    });

    test('4.4 纯内存 SseClientManager 单元级极限操作验证', () async {
      final manager = SseClientManager();
      expect(manager.hasClients, isFalse);
      expect(manager.clientCount, equals(0));

      // closeAll 空安全
      await expectLater(manager.closeAll(), completes);

      // broadcast 空安全
      expect(() => manager.broadcast({'test': 'empty'}), returnsNormally);
    });
  });

  group('Adversarial 5: 负载与大请求体边界压力测试 (Payload & Concurrency)', () {
    test('5.1 大体积 JSON 字符串请求体 (> 500KB) 正常解析且无内存溢出', () async {
      final largeText = 'A' * (500 * 1024); // 500KB
      final req = await client.post('127.0.0.1', port, '/simulate');
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode({'text': largeText}));
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      expect(fakePort.callLog.last, startsWith('simulateUserInput:AAAAA'));
    });

    test('5.2 混合端点高并发并发请求无锁死无死锁 (50 并发请求混合)', () async {
      final futures = <Future<int>>[];
      for (var i = 0; i < 50; i++) {
        if (i % 3 == 0) {
          futures.add(() async {
            final req = await client.get('127.0.0.1', port, '/health');
            final res = await req.close();
            await res.drain();
            return res.statusCode;
          }());
        } else if (i % 3 == 1) {
          futures.add(() async {
            final req = await client.get('127.0.0.1', port, '/status');
            final res = await req.close();
            await res.drain();
            return res.statusCode;
          }());
        } else {
          futures.add(() async {
            final req = await client.post('127.0.0.1', port, '/simulate');
            req.headers.contentType = ContentType.json;
            req.write(jsonEncode({'text': 'Concurrent test $i'}));
            final res = await req.close();
            await res.drain();
            return res.statusCode;
          }());
        }
      }

      final statusCodes = await Future.wait(futures);
      expect(statusCodes.length, equals(50));
      for (final code in statusCodes) {
        expect(code, HttpStatus.ok);
      }
    });

    test('5.3 RequestContext 异常与空体容错防御', () async {
      // POST 请求发送纯空体
      final emptyReq = await client.post('127.0.0.1', port, '/simulate');
      emptyReq.headers.contentType = ContentType.json;
      emptyReq.write('');
      final emptyRes = await emptyReq.close();
      // 空文本被 ChatHandler 校验拦截返回 400
      expect(emptyRes.statusCode, HttpStatus.badRequest);

      // POST 请求发送纯空白字符体
      final wsReq = await client.post('127.0.0.1', port, '/simulate');
      wsReq.headers.contentType = ContentType.json;
      wsReq.write('   \n  \t ');
      final wsRes = await wsReq.close();
      expect(wsRes.statusCode, HttpStatus.badRequest);
    });
  });
}
