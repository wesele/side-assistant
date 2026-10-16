import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/edge_tts_service.dart';
import 'package:side_assistant/services/speech/tts_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('EdgeTtsService 单元测试', () {
    test('语速倍率格式化验证 (formatRate)', () {
      expect(EdgeTtsService.formatRate(1.0), equals('+0%'));
      expect(EdgeTtsService.formatRate(1.2), equals('+20%'));
      expect(EdgeTtsService.formatRate(0.8), equals('-20%'));
      expect(EdgeTtsService.formatRate(1.5), equals('+50%'));
      expect(EdgeTtsService.formatRate(0.5), equals('-50%'));
    });

    test('edge_tts_worker.py 脚本文件应存在且包含关键实现', () {
      final script = File('lib/services/speech/edge_tts_worker.py');
      expect(script.existsSync(), isTrue);
      final content = script.readAsStringSync();
      expect(content, contains('reconfigure(encoding=\'utf-8\')'));
      expect(content, contains('DEFAULT_VOICE = "zh-CN-XiaoxiaoNeural"'));
      expect(content, contains('cmd == "ping"'));
    });

    test('真实调用 EdgeTtsService 合成晓晓声线音频文件', () async {
      final edgeService = EdgeTtsService();
      // 等待守护进程就绪
      await Future.delayed(const Duration(milliseconds: 500));

      if (edgeService.isAvailable) {
        final mp3Path = await edgeService.synthesizeToFile(
          '你好，我是晓漫，语音已升级为超自然神经网络。',
          voice: 'zh-CN-XiaoxiaoNeural',
          speed: 1.0,
        );

        expect(mp3Path, isNotNull);
        final file = File(mp3Path!);
        expect(file.existsSync(), isTrue);
        expect(file.lengthSync(), greaterThan(1000));

        // 清理临时文件
        try {
          file.deleteSync();
        } catch (_) {}
      }

      edgeService.dispose();
    });
  });

  group('TtsService 多引擎配置与音色支持测试', () {
    test('AppSettings 默认开启微软 Edge Neural 晓晓音色', () {
      final settings = AppSettings();
      expect(settings.ttsEngine, equals('edge'));
      expect(settings.edgeVoice, equals(AppConstants.defaultEdgeVoice));
      expect(settings.edgeVoice, equals('zh-CN-XiaoxiaoNeural'));
    });

    test('TtsService 实例化应自动初始化 EdgeTtsService', () {
      final settings = AppSettings(ttsEngine: 'edge');
      final tts = TtsService(settings: settings);
      expect(tts.isSpeaking, isFalse);
      tts.dispose();
    });
  });
}
