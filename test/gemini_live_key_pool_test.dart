import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/core/models/chat_message.dart';
import 'package:side_assistant/core/models/chat_session.dart';
import 'package:side_assistant/core/models/gemini_live_key_pool.dart';
import 'package:side_assistant/core/platform/foundation_bridge.dart';
import 'package:side_assistant/core/platform/pcm_stream_player_bridge.dart';
import 'package:side_assistant/core/ports/assistant_driver_port.dart';
import 'package:side_assistant/services/automation/app_driver_server.dart';
import 'package:side_assistant/services/automation/handlers/settings_handler.dart';
import 'package:side_assistant/services/automation/http_router.dart';
import 'package:side_assistant/services/speech/gemini_live_asr_service.dart';
import 'package:side_assistant/services/speech/gemini_live_dialog_service.dart';

class _FakeSocket extends Stream<dynamic> implements WebSocket {
  final StreamController<dynamic> _controller =
      StreamController<dynamic>.broadcast();
  final List<Map<String, dynamic>> sentJson = <Map<String, dynamic>>[];
  final bool autoSetupComplete;
  final void Function(_FakeSocket sock)? onSetup;
  int? _closeCode;
  String? _closeReason;

  _FakeSocket({this.autoSetupComplete = true, this.onSetup});

  @override
  int? get closeCode => _closeCode;
  @override
  String? get closeReason => _closeReason;

  void emitJson(Map<String, dynamic> data) {
    if (!_controller.isClosed) {
      _controller.add(jsonEncode(data));
    }
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
    if (data is String) {
      final decoded = jsonDecode(data) as Map<String, dynamic>;
      sentJson.add(decoded);
      if (decoded.containsKey('setup')) {
        if (autoSetupComplete) {
          scheduleMicrotask(() => emitJson({'setupComplete': {}}));
        }
        if (onSetup != null) {
          scheduleMicrotask(() => onSetup!(this));
        }
      }
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

class _ControllablePcmPlayer extends PlatformPcmStreamPlayer {
  bool playing = false;

  @override
  bool get isPlaying => playing;

  @override
  Future<void> feedPcm(
    Uint8List pcmBytes, {
    int sampleRate = 24000,
    int volumePercent = 100,
    String outputDeviceId = '',
  }) async {}

  @override
  Future<void> stopImmediate() async {
    playing = false;
  }
}

class _FakeDriver extends Fake implements AssistantDriverPort {
  @override
  AppSettings settings = AppSettings();
  @override
  AssistantStatus status = AssistantStatus.idle;
  @override
  String statusHint = 'idle';
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
  double micLevel = 0;
  @override
  double micDbfs = -60;
  @override
  bool vadDetected = false;
  @override
  bool isMicTesting = false;
  @override
  String micTestText = '';
  @override
  List<Map<String, dynamic>> micTestHistory = const [];
  @override
  int enrolledSpeakerCount = 0;
  @override
  bool hasEnrolledOwner = false;
  @override
  String speakerModelLabel = 'test-speaker';
  @override
  bool isInContinuousMode = false;
  @override
  String currentSessionId = 's-1';
  @override
  List<ChatMessage> messages = const [];
  @override
  List<ChatSession> sessions = const [];
  @override
  bool isSelfTesting = false;
  @override
  List<String> selfTestLogs = const [];
  @override
  String activeAudioInputDeviceLabel = '';

  String? lastTestedApiKey;

  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  Future<void> updateSettings(AppSettings newSettings) async {
    settings = newSettings;
  }

  @override
  Future<String> testGeminiAsrConnection(
      {String? apiKey, String? model}) async {
    lastTestedApiKey = apiKey;
    return '连接成功：$apiKey';
  }
}

void main() {
  group('GeminiLiveKeyPool 核心算法单元测试', () {
    test('Key 标准化去重、TPM 限幅与旧版 geminiApiKey 回退', () {
      var now = 1000000;
      final pool = GeminiLiveKeyPool(
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );

      final entries = GeminiApiKeyEntry.normalizeList([
        {'id': '1', 'label': 'Proj A', 'apiKey': ' key-a ', 'tpmLimit': -1},
        {'id': '2', 'label': 'Dup A', 'apiKey': 'key-a', 'tpmLimit': 90000},
        {'id': '3', 'label': '', 'apiKey': '   '},
        {'id': '4', 'label': 'Proj B', 'apiKey': 'key-b', 'tpmLimit': 80000},
      ]);
      expect(entries.length, 2);
      expect(entries[0].apiKey, 'key-a');
      expect(entries[0].tpmLimit, 65000);
      expect(entries[1].apiKey, 'key-b');
      expect(entries[1].tpmLimit, 80000);

      final legacyOnly = AppSettings(geminiApiKey: 'legacy-key');
      final resolved = pool.resolvePool(legacyOnly);
      expect(resolved.length, 1);
      expect(resolved.first.apiKey, 'legacy-key');
      expect(resolved.first.tpmLimit, 65000);
    });

    test('usageMetadata Token 提取与 429 错误特征识别', () {
      expect(
        GeminiLiveKeyPool.extractUsageTokens({'totalTokenCount': 1234}),
        1234,
      );
      expect(
        GeminiLiveKeyPool.extractUsageTokens({
          'promptTokenCount': 100,
          'responseTokenCount': 250,
          'thoughtsTokenCount': 50,
          'toolUsePromptTokenCount': 25,
        }),
        425,
      );
      expect(GeminiLiveKeyPool.isRateLimitError('HTTP 429 Too Many Requests'),
          isTrue);
      expect(GeminiLiveKeyPool.isRateLimitError('RESOURCE_EXHAUSTED quota'),
          isTrue);
      expect(GeminiLiveKeyPool.isRateLimitError('port 4290 connection reset'),
          isFalse);
      expect(GeminiLiveKeyPool.isRateLimitError('invalid argument'), isFalse);
      expect(
        GeminiLiveKeyPool.isZeroQuotaError(
          'Quota exceeded for metric: search_grounding, limit: 0',
        ),
        isTrue,
      );
      expect(
        GeminiLiveKeyPool.isZeroQuotaError('429 RESOURCE_EXHAUSTED'),
        isFalse,
      );
    });

    test('60s 滑动窗口 TPM 计数、80% 阈值选路、冷却与全部耗尽 waitMs', () {
      var now = 1000000;
      final pool = GeminiLiveKeyPool(
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );
      const keys = [
        GeminiApiKeyEntry(
            id: 'k1', label: 'K1', apiKey: 'key-1', tpmLimit: 10000),
        GeminiApiKeyEntry(
            id: 'k2', label: 'K2', apiKey: 'key-2', tpmLimit: 10000),
      ];

      // 初始均未用：选 K1
      var sel = pool.selectKey(keys);
      expect(sel.exhausted, isFalse);
      expect(sel.entry!.apiKey, 'key-1');

      // K1 记录 8000 tokens (>= 80% * 10000)
      pool.normalizeKeys(keys);
      final usageRes = pool.recordUsage('key-1', {'totalTokenCount': 8000});
      expect(usageRes.overThreshold, isTrue);

      // 再选时避开 K1，选 K2
      sel = pool.selectKey(keys);
      expect(sel.exhausted, isFalse);
      expect(sel.entry!.apiKey, 'key-2');

      // 推进 30s 并把 K2 打入 429 冷却
      now += 30000;
      pool.markRateLimited('key-2');

      // 此时 K1 超阈值还剩 30s 才会滑出窗口，K2 冷却还剩 60s -> 全部耗尽且 waitMs = 30000
      sel = pool.selectKey(keys);
      expect(sel.exhausted, isTrue);
      expect(sel.waitMs, 30000);
      expect(GeminiLiveKeyPool.formatQuotaWaitMessage(sel.waitMs),
          contains('30 秒'));

      // 再推进 30001ms 后 K1 滑出 60s 窗口恢复可用
      now += 30001;
      sel = pool.selectKey(keys);
      expect(sel.exhausted, isFalse);
      expect(sel.entry!.apiKey, 'key-1');
    });
  });

  group('GeminiLiveDialogService 多 Key 优雅切换与 429 故障转移', () {
    test('当前 Key 达 80% TPM 时等待回复与播音结束再切换，并清除旧 resumptionHandle 注入上下文',
        () async {
      var now = 2000000;
      final pool = GeminiLiveKeyPool(
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );
      final settings = AppSettings(
        geminiApiKeys: const [
          GeminiApiKeyEntry(
              id: '1', label: 'P1', apiKey: 'dlg-key-1', tpmLimit: 10000),
          GeminiApiKeyEntry(
              id: '2', label: 'P2', apiKey: 'dlg-key-2', tpmLimit: 10000),
        ],
      );
      final pcm = _ControllablePcmPlayer();
      final sockets = <_FakeSocket>[];
      final connectedUrls = <String>[];

      final service = GeminiLiveDialogService(
        settings: settings,
        pcmPlayer: pcm,
        keyPool: pool,
        webSocketConnector: (url) async {
          connectedUrls.add(url);
          final sock = _FakeSocket();
          sockets.add(sock);
          return sock;
        },
      );
      addTearDown(service.dispose);

      expect(await service.connect(), isTrue);
      expect(connectedUrls.length, 1);
      expect(connectedUrls.first, contains('key=dlg-key-1'));
      expect(service.activeApiKey, 'dlg-key-1');

      // 模拟服务端下发 sessionResumptionHandle，且当前正处于模型生成与播音中
      sockets[0].emitJson({
        'sessionResumptionUpdate': {'newHandle': 'handle-from-k1'},
      });
      pcm.playing = true;
      sockets[0].emitJson({
        'serverContent': {
          'inputTranscription': {'text': '你好', 'finished': true},
          'modelTurn': {
            'parts': [
              {'text': '你好呀，我是晓漫'}
            ],
          },
          'outputTranscription': {'text': '你好呀，我是晓漫', 'finished': true},
        },
        'usageMetadata': {'totalTokenCount': 8500},
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // 因模型轮次尚未 turnComplete 且还在播音，绝不提前中断当前对话切换
      expect(connectedUrls.length, 1);
      expect(service.activeApiKey, 'dlg-key-1');

      // 模型 turnComplete 来了但扬声器仍在播音 -> 仍应等待播音结束
      sockets[0].emitJson({
        'serverContent': {'turnComplete': true},
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(connectedUrls.length, 1);

      // 播音结束 -> drain timer 触发 turnCompleted 与无感切换 Key 2
      pcm.playing = false;
      await Future<void>.delayed(const Duration(milliseconds: 220));
      expect(connectedUrls.length, 2);
      expect(connectedUrls[1], contains('key=dlg-key-2'));
      expect(service.activeApiKey, 'dlg-key-2');

      // 新连接的 setup 不能携带旧 Key 的 sessionResumptionHandle，且应种子注入历史对话
      final secondSetup = sockets[1].sentJson.first['setup'] as Map;
      final secondResumption = secondSetup['sessionResumption'] as Map?;
      expect(secondResumption?.containsKey('handle') ?? false, isFalse);
      final seeded = sockets[1]
          .sentJson
          .where((m) => m.containsKey('clientContent'))
          .toList();
      expect(seeded, isNotEmpty);
      expect(jsonEncode(seeded.first), contains('你好呀，我是晓漫'));
    });

    test('对话运行期遇 429 错误立即停播冷却并切到备用 Key；全部耗尽则友好停止', () async {
      var now = 3000000;
      final pool = GeminiLiveKeyPool(
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );
      final settings = AppSettings(
        geminiApiKeys: const [
          GeminiApiKeyEntry(
              id: '1', label: 'P1', apiKey: 'k-rate-1', tpmLimit: 65000),
          GeminiApiKeyEntry(
              id: '2', label: 'P2', apiKey: 'k-rate-2', tpmLimit: 65000),
        ],
      );
      final pcm = _ControllablePcmPlayer()..playing = true;
      final sockets = <_FakeSocket>[];
      final urls = <String>[];
      final surfacedErrors = <String>[];

      final service = GeminiLiveDialogService(
        settings: settings,
        pcmPlayer: pcm,
        keyPool: pool,
        webSocketConnector: (url) async {
          urls.add(url);
          final sock = _FakeSocket();
          sockets.add(sock);
          return sock;
        },
      )..onServerError = surfacedErrors.add;
      addTearDown(service.dispose);

      expect(await service.connect(), isTrue);
      expect(service.activeApiKey, 'k-rate-1');

      // Key 1 触发 429 限流 -> 立即停播、冷却 K1、切到 K2 且不上报错误给 UI
      sockets[0].emitJson({
        'error': {'message': '429 RESOURCE_EXHAUSTED: quota exceeded'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(pcm.playing, isFalse);
      expect(pool.isKeyCoolingDown('k-rate-1'), isTrue);
      expect(urls.length, 2);
      expect(service.activeApiKey, 'k-rate-2');
      expect(surfacedErrors, isEmpty);

      // Key 2 也触发 429 -> 池全部耗尽，应停止重试并给出含等待秒数的友好提示与原始原因
      sockets[1].emitJson({
        'error': {'message': 'Too many requests (429)'},
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(urls.length, 2);
      expect(service.isActive, isFalse);
      expect(surfacedErrors.length, 1);
      expect(surfacedErrors.first, contains('所有 Gemini Live API Key 均已达到'));
      expect(surfacedErrors.first, contains('Too many requests (429)'));
    });

    test('握手阶段 WebSocket HTTP 429 与 limit: 0 零配额报错保留真实原因且不锁死试听', () async {
      final pool = GeminiLiveKeyPool();
      final settings = AppSettings(
        enableWebSearch: true,
        geminiApiKeys: const [
          GeminiApiKeyEntry(id: '1', label: 'K1', apiKey: 'hs-k1'),
          GeminiApiKeyEntry(id: '2', label: 'K2', apiKey: 'hs-k2'),
        ],
      );
      final pcm = _ControllablePcmPlayer();
      final urls = <String>[];
      final surfacedErrors = <String>[];

      // 场景 1：HTTP 升级阶段抛 429，应冷却 K1 并自动切到 K2 成功连接
      final http429Service = GeminiLiveDialogService(
        settings: settings,
        pcmPlayer: pcm,
        keyPool: pool,
        webSocketConnector: (url) async {
          urls.add(url);
          if (url.contains('key=hs-k1')) {
            throw const WebSocketException(
              'Connection was not upgraded to websocket, HTTP status code: 429',
            );
          }
          return _FakeSocket();
        },
      )..onServerError = surfacedErrors.add;
      addTearDown(http429Service.dispose);

      expect(await http429Service.connect(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(pool.isKeyCoolingDown('hs-k1'), isTrue);
      expect(urls.any((u) => u.contains('key=hs-k2')), isTrue);
      expect(http429Service.isReady, isTrue);
      expect(surfacedErrors, isEmpty);

      // 场景 2：所有 Key 均因 limit: 0 零配额（如免费层禁用联网搜索工具）握手失败时，
      // 必须清理误冷却（不锁死后续试听），并直接透传真实 limit: 0 错误而非只报 80% TPM
      pool.reset();
      surfacedErrors.clear();
      final zeroQuotaService = GeminiLiveDialogService(
        settings: settings,
        pcmPlayer: pcm,
        keyPool: pool,
        webSocketConnector: (url) async {
          return _FakeSocket(
            autoSetupComplete: false,
            onSetup: (sock) => sock.emitJson({
              'error': {
                'message':
                    'Quota exceeded for metric: search_grounding, limit: 0',
              },
            }),
          );
        },
      )..onServerError = surfacedErrors.add;
      addTearDown(zeroQuotaService.dispose);

      expect(await zeroQuotaService.connect(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(zeroQuotaService.isActive, isFalse);
      expect(pool.isKeyCoolingDown('hs-k1'), isFalse);
      expect(pool.isKeyCoolingDown('hs-k2'), isFalse);
      expect(surfacedErrors.length, 1);
      expect(surfacedErrors.first, contains('limit: 0'));
      expect(surfacedErrors.first, contains('Quota exceeded'));
    });

    test('握手阶段所有 Key 遇非 zero-limit 限流时保留服务端原始详情与握手排查提示', () async {
      final pool = GeminiLiveKeyPool();
      final settings = AppSettings(
        enableWebSearch: true,
        geminiApiKeys: const [
          GeminiApiKeyEntry(id: '1', label: 'A1', apiKey: 'ws-k1'),
          GeminiApiKeyEntry(id: '2', label: 'A2', apiKey: 'ws-k2'),
        ],
      );
      final pcm = _ControllablePcmPlayer();
      final surfacedErrors = <String>[];

      final service = GeminiLiveDialogService(
        settings: settings,
        pcmPlayer: pcm,
        keyPool: pool,
        webSocketConnector: (url) async {
          return _FakeSocket(
            autoSetupComplete: false,
            onSetup: (sock) => sock.close(
              1011,
              'RESOURCE_EXHAUSTED: Live API concurrent limit',
            ),
          );
        },
      )..onServerError = surfacedErrors.add;
      addTearDown(service.dispose);

      await service.connect();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(service.isActive, isFalse);
      expect(surfacedErrors.length, 1);
      expect(surfacedErrors.first, contains('所有 Gemini Live API Key 均已达到'));
      expect(surfacedErrors.first, contains('Live API concurrent limit'));
      expect(surfacedErrors.first, contains('握手阶段触发'));
    });
  });

  group('GeminiLiveAsrService 多 Key 轮询与 429 切换', () {
    test('ASR usageMetadata 达 80% 下一轮切换 Key；遇 429 自动故障转移重试并成功转写', () async {
      var now = 4000000;
      final pool = GeminiLiveKeyPool(
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );
      final settings = AppSettings(
        geminiApiKeys: const [
          GeminiApiKeyEntry(
              id: '1', label: 'A1', apiKey: 'asr-k1', tpmLimit: 10000),
          GeminiApiKeyEntry(
              id: '2', label: 'A2', apiKey: 'asr-k2', tpmLimit: 10000),
        ],
      );
      final urls = <String>[];
      var callIdx = 0;

      final asr = GeminiLiveAsrService(
        settings: settings,
        keyPool: pool,
        webSocketConnector: (url) async {
          urls.add(url);
          final idx = callIdx++;
          final sock = _FakeSocket();
          sock.sentJson; // 保持引用
          // 监听到 audioStreamEnd 时自动回传测试结果
          Timer.periodic(const Duration(milliseconds: 5), (t) {
            if (sock.sentJson.any((m) =>
                (m['realtimeInput'] as Map?)?['audioStreamEnd'] == true)) {
              t.cancel();
              if (idx == 0) {
                // 第一轮：消耗 8500 tokens（触发 80% 阈值）并正常返回转写
                sock.emitJson({
                  'usageMetadata': {'totalTokenCount': 8500},
                  'serverContent': {
                    'inputTranscription': {'text': '第一句', 'finished': true},
                    'generationComplete': true,
                    'turnComplete': true,
                  },
                });
              } else if (idx == 1) {
                // 第二轮使用的 asr-k2：模拟遇 429 限流失败，应自动回退并冷却 k2
                sock.emitJson({
                  'error': {'message': '429 quota exceeded'},
                });
              } else {
                // 自动重试：此时 k2 在冷却中，回到 k1（若窗口未满）或其它可用 Key
                sock.emitJson({
                  'serverContent': {
                    'inputTranscription': {'text': '重试成功', 'finished': true},
                    'generationComplete': true,
                    'turnComplete': true,
                  },
                });
              }
            }
          });
          return sock;
        },
      );
      addTearDown(asr.dispose);

      // 构造 0.2s 非静音语音样本
      final speech = Float32List.fromList(
        List<double>.generate(3200, (i) => (i.isEven ? 0.2 : -0.2)),
      );

      final text1 = await asr.transcribeSamples(speech, fromVad: true);
      expect(text1, '第一句');
      expect(urls.first, contains('key=asr-k1'));

      // 推进时间使 k1 的 8500 稍后可用于 k2 限流后接管；注意第 2 次刚启动时 k1 仍在 80% 上，因此选 k2！
      final text2 = await asr.transcribeSamples(speech, fromVad: true);
      expect(urls.length, greaterThanOrEqualTo(2));
      expect(urls[1], contains('key=asr-k2'));
      // 第 2 次遭遇 429 时，因为 k1 也超过 80%，没有未超阈值的可用 Key -> 优雅结束不崩溃
      expect(pool.isKeyCoolingDown('asr-k2'), isTrue);
      expect(text2, isEmpty);

      // 推进 61s，全部恢复后下一次识别可正常返回
      now += 61000;
      final text3 = await asr.transcribeSamples(speech, fromVad: true);
      expect(text3, '重试成功');
    });

    test('ASR 单次识别中首个 Key 返回 429 时立即无缝故障转移到第二个可用 Key 并返回转写', () async {
      var now = 5000000;
      final pool = GeminiLiveKeyPool(
        clock: () => DateTime.fromMillisecondsSinceEpoch(now),
      );
      final settings = AppSettings(
        geminiApiKeys: const [
          GeminiApiKeyEntry(
              id: '1', label: 'A1', apiKey: 'retry-k1', tpmLimit: 10000),
          GeminiApiKeyEntry(
              id: '2', label: 'A2', apiKey: 'retry-k2', tpmLimit: 10000),
        ],
      );
      final urls = <String>[];
      var callIdx = 0;

      final asr = GeminiLiveAsrService(
        settings: settings,
        keyPool: pool,
        webSocketConnector: (url) async {
          urls.add(url);
          final idx = callIdx++;
          final sock = _FakeSocket();
          Timer.periodic(const Duration(milliseconds: 5), (t) {
            if (sock.sentJson.any((m) =>
                (m['realtimeInput'] as Map?)?['audioStreamEnd'] == true)) {
              t.cancel();
              if (idx == 0) {
                sock.emitJson({
                  'error': {'message': '429 RESOURCE_EXHAUSTED'},
                });
              } else {
                sock.emitJson({
                  'serverContent': {
                    'inputTranscription': {
                      'text': '无缝切Key成功',
                      'finished': true
                    },
                    'generationComplete': true,
                    'turnComplete': true,
                  },
                });
              }
            }
          });
          return sock;
        },
      );
      addTearDown(asr.dispose);

      final speech = Float32List.fromList(
        List<double>.generate(3200, (i) => (i.isEven ? 0.25 : -0.25)),
      );
      final text = await asr.transcribeSamples(speech, fromVad: true);
      expect(text, '无缝切Key成功');
      expect(urls.length, 2);
      expect(urls[0], contains('key=retry-k1'));
      expect(urls[1], contains('key=retry-k2'));
      expect(pool.isKeyCoolingDown('retry-k1'), isTrue);
    });
  });

  group('SettingsHandler /api/gemini-key-pool 与 Flutter Key 池编辑器测试', () {
    test('HTTP POST /api/settings 与 GET /api/gemini-key-pool 状态契约', () async {
      final driver = _FakeDriver();
      final router = HttpRouter(driverPort: driver);
      SettingsHandler(driver).registerRoutes(router);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(router.handle);
      final client = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        await server.close(force: true);
      });

      final postReq = await client.post(
          InternetAddress.loopbackIPv4.address, server.port, '/api/settings');
      postReq.headers.contentType = ContentType.json;
      postReq.write(jsonEncode({
        'geminiApiKeys': [
          {
            'id': 'srv-1',
            'label': 'Proj1',
            'apiKey': 'srv-key-1',
            'tpmLimit': 10000
          },
          {
            'id': 'srv-2',
            'label': 'Proj2',
            'apiKey': 'srv-key-2',
            'tpmLimit': 20000
          },
        ],
      }));
      final postRes = await postReq.close();
      expect(postRes.statusCode, HttpStatus.ok);
      await postRes.drain<void>();
      expect(driver.settings.geminiApiKeys.length, 2);
      expect(driver.settings.geminiApiKey, 'srv-key-1');

      GeminiLiveKeyPool.instance.reset();
      GeminiLiveKeyPool.instance
          .recordUsage('srv-key-1', {'totalTokenCount': 8500});
      addTearDown(GeminiLiveKeyPool.instance.reset);

      final getReq = await client.get(InternetAddress.loopbackIPv4.address,
          server.port, '/api/gemini-key-pool');
      final getRes = await getReq.close();
      expect(getRes.statusCode, HttpStatus.ok);
      final body = jsonDecode(await utf8.decoder.bind(getRes).join()) as Map;
      final keys = body['keys'] as List;
      expect(keys.length, 2);
      expect(keys[0]['tpm'], 8500);
      expect(keys[0]['overThreshold'], isTrue);
      expect(keys[1]['tpm'], 0);
      expect(keys[1]['overThreshold'], isFalse);

      // 验证 AppDriverServer SSE 会在 KeyPool 用量变化时实时推送 geminiKeyPool
      final freeSocket =
          await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final ssePort = freeSocket.port;
      await freeSocket.close();
      final appServer = AppDriverServer(
        driverPort: driver,
        port: ssePort,
        bindAddress: InternetAddress.loopbackIPv4,
      );
      await appServer.start();
      addTearDown(appServer.stop);

      final sseReq = await client.get(
          InternetAddress.loopbackIPv4.address, ssePort, '/api/events');
      final sseRes = await sseReq.close();
      expect(sseRes.statusCode, HttpStatus.ok);

      final ssePayloads = <Map<String, dynamic>>[];
      final secondPush = Completer<void>();
      final sub = sseRes
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (!line.startsWith('data: ')) return;
        final map = jsonDecode(line.substring(6)) as Map<String, dynamic>;
        ssePayloads.add(map);
        if (ssePayloads.length >= 2 && !secondPush.isCompleted) {
          secondPush.complete();
        }
      });
      addTearDown(sub.cancel);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      GeminiLiveKeyPool.instance
          .recordUsage('srv-key-2', {'totalTokenCount': 4200});
      await secondPush.future.timeout(const Duration(seconds: 2));

      final latestPool = ssePayloads.last['geminiKeyPool'] as List;
      expect(latestPool.length, 2);
      expect(latestPool[1]['tpm'], 4200);
    });
  });
}
