import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/automation/app_driver_server.dart';
import 'package:side_assistant/core/platform/linux/linux_hardware_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  group('Linux Server & Web Console API 测试', () {
    late AssistantController controller;
    late AppDriverServer server;
    late int port;
    late HttpClient client;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      // 随机找一个空闲端口
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

    test('GET / 应返回对齐客户端风格的 Web 控制台 HTML 页面', () async {
      final req = await client.get('127.0.0.1', port, '/');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      final html = await utf8.decodeStream(res);
      expect(html, contains('--fg: #004D40'));
      expect(html, contains('助手设置'));
      expect(html, contains('服务器播放音量'));
      expect(html, contains('开始麦克风测试'));
      expect(html, contains('/api/state'));
      expect(html, contains('/api/hardware-devices'));
      // 麦克风图标包含静音/禁用状态与动态切换
      expect(html, contains('micToggleBtn'));
      expect(html, contains('micToggleIcon'));
      expect(html, contains('M19 11h-1.7')); // mic_off SVG path
      // 主界面状态栏包含服务器实时 CPU 占用率指标且紧邻麦克风音量指示器
      expect(html, contains('miniCpuWrap'));
      expect(html, contains('miniCpuLabel'));
      expect(html, contains('mini-cpu-wrap'));
    });

    test('GET /api/state、/api/volume 与 /api/mic-test 应支持音量调节与麦克风测试', () async {
      final req = await client.get('127.0.0.1', port, '/api/state');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.ok);
      final state =
          jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
      expect(state['status'], 'idle');
      expect(state.containsKey('isMicListening'), isTrue);
      expect(state.containsKey('micLevel'), isTrue);
      expect(state.containsKey('micDbfs'), isTrue);
      expect(state.containsKey('cpuUsage'), isTrue);
      expect(state.containsKey('isMicTesting'), isTrue);
      expect(state.containsKey('playbackVolume'), isTrue);
      expect(state.containsKey('sessions'), isTrue);

      // 测试调整服务器播放音量
      final volReq = await client.post('127.0.0.1', port, '/api/volume');
      volReq.headers.contentType = ContentType.json;
      volReq.write(jsonEncode({'volume': 65}));
      final volRes = await volReq.close();
      expect(volRes.statusCode, HttpStatus.ok);
      final volMap =
          jsonDecode(await utf8.decodeStream(volRes)) as Map<String, dynamic>;
      expect(volMap['playbackVolume'], 65);
      expect(controller.settings.playbackVolume, 65);

      // 测试麦克风测试模式开关
      final micReq = await client.post('127.0.0.1', port, '/api/mic-test');
      micReq.headers.contentType = ContentType.json;
      micReq.write(jsonEncode({'enabled': true}));
      final micRes = await micReq.close();
      expect(micRes.statusCode, HttpStatus.ok);
      final micMap =
          jsonDecode(await utf8.decodeStream(micRes)) as Map<String, dynamic>;
      expect(micMap['isMicTesting'], isTrue);

      final setReq = await client.get('127.0.0.1', port, '/api/settings');
      final setRes = await setReq.close();
      expect(setRes.statusCode, HttpStatus.ok);
      final setMap = (jsonDecode(await utf8.decodeStream(setRes))
          as Map)['settings'] as Map<String, dynamic>;
      expect(setMap.containsKey('audioOutputDeviceId'), isTrue);
      expect(setMap.containsKey('playbackVolume'), isTrue);
      expect(setMap.containsKey('linuxCameraDevice'), isTrue);
      expect(setMap.containsKey('autoStartMicOnLaunch'), isTrue);
      expect(setMap.containsKey('webAccessPassword'), isTrue);
    });

    test('POST /api/settings 配置 webAccessPassword 后应启用访问鉴权', () async {
      final postReq = await client.post('127.0.0.1', port, '/api/settings');
      postReq.headers.contentType = ContentType.json;
      postReq.write(jsonEncode({
        'startWord': '小管家',
        'linuxCameraDevice': '/dev/video0',
        'webAccessPassword': 'secret_password_123',
      }));
      final postRes = await postReq.close();
      expect(postRes.statusCode, HttpStatus.ok);
      expect(controller.settings.startWord, '小管家');
      expect(controller.settings.linuxCameraDevice, '/dev/video0');
      expect(controller.settings.webAccessPassword, 'secret_password_123');

      // 未携带密码访问 /api/state 应返回 401
      final unauthReq = await client.get('127.0.0.1', port, '/api/state');
      final unauthRes = await unauthReq.close();
      expect(unauthRes.statusCode, HttpStatus.unauthorized);

      // 携带正确密码头访问应返回 200
      final authReq = await client.get('127.0.0.1', port, '/api/state');
      authReq.headers.set('X-Access-Password', 'secret_password_123');
      final authRes = await authReq.close();
      expect(authRes.statusCode, HttpStatus.ok);
    });

    test('唤醒后发送消息应立即重置已激活状态与识别字稿，不残留旧的已激活标记', () async {
      await controller.sendTextMessage('今天几号');
      expect(controller.isWakeWordMatched, isFalse);
      expect(controller.displayTranscript, isEmpty);
      expect(controller.lastRecognizedSpeech, isEmpty);
    });

    test('POST /api/speaker 接口应支持声纹录入、清除与相似度测试', () async {
      // 1. 无语音直接请求录入（record: false 避免测试阻塞）
      final enrollReq =
          await client.post('127.0.0.1', port, '/api/speaker/enroll');
      enrollReq.headers.contentType = ContentType.json;
      enrollReq.write(jsonEncode({'record': false}));
      final enrollRes = await enrollReq.close();
      expect(enrollRes.statusCode, HttpStatus.ok);
      final enrollMap = jsonDecode(await utf8.decodeStream(enrollRes))
          as Map<String, dynamic>;
      expect(enrollMap.containsKey('accepted'), isTrue);
      expect(enrollMap.containsKey('enrolledCount'), isTrue);

      // 2. 清空声纹
      final clearReq =
          await client.post('127.0.0.1', port, '/api/speaker/clear');
      final clearRes = await clearReq.close();
      expect(clearRes.statusCode, HttpStatus.ok);
      final clearMap =
          jsonDecode(await utf8.decodeStream(clearRes)) as Map<String, dynamic>;
      expect(clearMap['accepted'], isTrue);
      expect(clearMap['enrolledCount'], 0);

      // 3. 测试未录入声纹时的比对结果
      final testReq = await client.post('127.0.0.1', port, '/api/speaker/test');
      testReq.headers.contentType = ContentType.json;
      testReq.write(jsonEncode({'record': false}));
      final testRes = await testReq.close();
      expect(testRes.statusCode, HttpStatus.ok);
      final testMap =
          jsonDecode(await utf8.decodeStream(testRes)) as Map<String, dynamic>;
      expect(testMap['passed'], isFalse);
    });

    test('LinuxHardwareService CPU 占用率解析与计算测试', () {
      LinuxHardwareService.resetCpuUsageCountersForTest();

      const sample1 = '''
cpu  100 0 100 800 0 0 0 0 0 0
cpu0 50 0 50 400 0 0 0 0 0 0
''';
      final counters1 = LinuxHardwareService.parseProcStatCpuCounters(sample1);
      expect(counters1, isNotNull);
      final (active1, total1) = counters1!;
      expect(active1, 200);
      expect(total1, 1000);

      const sample2 = '''
cpu  150 0 150 1500 0 0 0 0 0 0
cpu0 75 0 75 750 0 0 0 0 0 0
''';
      final counters2 = LinuxHardwareService.parseProcStatCpuCounters(sample2);
      expect(counters2, isNotNull);
      final (active2, total2) = counters2!;
      expect(active2, 300);
      expect(total2, 1800);

      // deltaActive = 100, deltaTotal = 800 -> 100 / 800 * 100 = 12.5%
      final deltaActive = active2 - active1;
      final deltaTotal = total2 - total1;
      final usage = ((deltaActive / deltaTotal) * 100.0);
      expect(usage, closeTo(12.5, 0.01));
    });
  });
}
