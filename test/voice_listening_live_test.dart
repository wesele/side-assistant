import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/asr_service.dart';
import 'package:side_assistant/services/speech/gemini_live_asr_service.dart';
import 'package:side_assistant/services/speech/voice_listening_service.dart';

import 'live_test_support.dart';

/// 边说边传的整链路测试（需要联网，默认跳过）：
///   $env:GEMINI_LIVE_SMOKE="1"
///   flutter test test/voice_listening_live_test.dart
///
/// 走的是正式路径：麦克风回调 → 预卷环 → Silero VAD → `_pumpLiveAudio`
/// → Gemini 边说边传 → `onTextRecognized`。不启动麦克风，用 [feedAudioForTest] 喂音频。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(ensureSherpaBindings);

  setUpAll(() {
    // flutter_test 默认装了一个拦截网络请求的 HttpOverrides，会让 WebSocket
    // 偶发 “Reading from a closed socket”。联网测试里必须恢复真实实现。
    HttpOverrides.global = null;
  });

  setUpAll(() {
    // flutter_test 默认装了一个拦截网络请求的 HttpOverrides，联网测试需要真实实现。
    HttpOverrides.global = null;
    // VoiceListeningService 构造时会 eager 创建 AudioRecorder，测试环境没有
    // record 插件实现；这里挂一个空实现，避免 MissingPluginException。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (call) async => null,
    );
  });

  test('VAD 判定说话就开始推流，说完立即出字', () async {
    if (Platform.environment['GEMINI_LIVE_SMOKE'] != '1') {
      // ignore: avoid_print
      print('⏭  跳过：未设置 GEMINI_LIVE_SMOKE=1');
      return;
    }

    await runLiveNetworkTest(() async {
    final wave =
        sherpa_onnx.readWave('assets/models/sense-voice/test_wavs/zh.wav');
    const chunk = 1024; // 64ms，与麦克风 streamBufferSize 2048 字节对齐

    final asr = GeminiLiveAsrService(
      settings: AppSettings(
        asrEngine: AppConstants.asrEngineGeminiLive,
        geminiApiKey: AppConstants.defaultGeminiApiKey,
      ),
    );
    final recognized = <String>[];
    final gotText = Completer<String>();
    // 以“最后一块语音送入”为起点，在回调里立即测延迟（测试事件循环会在
    // 循环结束后才轮到 await，不能等到那时再算）。
    var lastSpeechAt = DateTime.now();
    var latencyMs = -1;
    final service = VoiceListeningService(
      asrService: asr,
      settings: AppSettings(asrEngine: AppConstants.asrEngineGeminiLive),
      isStandbyMode: () => false,
      onTextRecognized: (text) {
        latencyMs = DateTime.now().difference(lastSpeechAt).inMilliseconds;
        recognized.add(text);
        if (!gotText.isCompleted) gotText.complete(text);
      },
    );

    try {
      await asr.initialize();
      expect(asr.isReady, isTrue, reason: asr.lastError);
      await service.initializeVadForTest();

      // 1s 静音 → 语音 → 0.8s 静音，让 VAD 能切出完整一段。
      final parts = <Float32List>[
        Float32List(16000),
        Float32List.fromList(wave.samples),
        Float32List(16000 * 8 ~/ 10),
      ];

      for (var i = 0; i < parts.length; i++) {
        final part = parts[i];
        for (var offset = 0; offset < part.length; offset += chunk) {
          final end =
              offset + chunk < part.length ? offset + chunk : part.length;
          await service.feedAudioForTest(
            Float32List.sublistView(part, offset, end),
          );
          if (i == 1) lastSpeechAt = DateTime.now();
          await Future<void>.delayed(const Duration(milliseconds: 64));
        }
      }

      final text = await gotText.future.timeout(const Duration(seconds: 20));
      // ignore: avoid_print
      print(
        'PROBE 整链路：最后一块语音 → 出字 ${latencyMs}ms，'
        '文本="$text"，回调次数=${recognized.length}',
      );

      expect(text, contains('开放时间'));
      // 分段模式约 1.5s（上传 0.88s + 解码 0.65s）；边说边传应只剩解码尾巴。
      expect(latencyMs, greaterThan(0));
      expect(latencyMs, lessThan(800));
    } finally {
      try {
        service.dispose();
      } catch (_) {
        // 测试环境没有 record 插件实现，dispose 会抛 MissingPluginException。
      }
      asr.dispose();
    }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));
}
