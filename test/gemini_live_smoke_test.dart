import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/gemini_live_asr_service.dart';

/// Gemini 3.5 Transcribe Live 联网冒烟测试。
///
/// 默认跳过，避免普通 `flutter test` 依赖网络/API 配额。手动运行：
///   $env:GEMINI_LIVE_SMOKE="1"
///   $env:GEMINI_API_KEY="..."   # 可选，留空用内置默认 Key
///   flutter test test/gemini_live_smoke_test.dart
///
/// 未设置 `GEMINI_LIVE_SMOKE=1` 时该套件会被标记为 skipped 而非通过。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final bool liveEnabled = Platform.environment['GEMINI_LIVE_SMOKE'] == '1';

  test('Gemini Live 能识别仓库自带中文样例', () async {
    final envKey = Platform.environment['GEMINI_API_KEY']?.trim() ?? '';
    final settings = AppSettings(
      asrEngine: AppConstants.asrEngineGeminiLive,
      geminiApiKey: envKey.isEmpty ? AppConstants.defaultGeminiApiKey : envKey,
    );

    final asr = GeminiLiveAsrService(settings: settings);
    try {
      await asr.initialize();
      expect(asr.isReady, isTrue, reason: asr.lastError);

      const wav = 'assets/models/sense-voice/test_wavs/zh.wav';
      expect(File(wav).existsSync(), isTrue, reason: '样例音频不存在: $wav');

      final text = await asr.transcribeAudioFile(wav);
      // ignore: avoid_print
      print('Gemini Live 识别结果: $text');
      expect(text, isNotEmpty);
      expect(text, contains('开放时间'));

      // 第二条验证同一条 WebSocket 长连接可以连续识别多段语音。
      final text2 = await asr.transcribeAudioFile(wav);
      // ignore: avoid_print
      print('Gemini Live 第二次识别结果: $text2');
      expect(text2, contains('开放时间'));
    } finally {
      asr.dispose();
    }
  },
      timeout: const Timeout(Duration(minutes: 3)),
      skip: liveEnabled ? false : '需要 GEMINI_LIVE_SMOKE=1（联网 + API Key）');
}
