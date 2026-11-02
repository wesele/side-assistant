import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:side_assistant/core/constants/app_constants.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/asr_service.dart';
import 'package:side_assistant/services/speech/gemini_live_asr_service.dart';

import 'live_test_support.dart';

/// “边说边传”集成测试（需要联网，默认跳过）：
///   $env:GEMINI_LIVE_SMOKE="1"
///   flutter test test/gemini_live_streaming_test.dart
///
/// 模拟麦克风：按 64ms 一块、接近实时的节奏把音频推给 [GeminiLiveAsrService]，
/// 统计“最后一块音频发出 → 最终文本返回”的耗时。分段模式这个值是 ~1.5s，
/// 边说边传应该降到 0.3s 量级。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // flutter_test 默认装了一个拦截网络请求的 HttpOverrides，联网测试需要真实实现。
    HttpOverrides.global = null;
    ensureSherpaBindings();
  });

  const wav = 'assets/models/sense-voice/test_wavs/zh.wav';

  test('边说边传：VAD 判定说话期间推流，说完后快速出字', () async {
    if (Platform.environment['GEMINI_LIVE_SMOKE'] != '1') {
      // ignore: avoid_print
      print('⏭  跳过：未设置 GEMINI_LIVE_SMOKE=1');
      return;
    }

    await runLiveNetworkTest(() async {
      final wave = sherpa_onnx.readWave(wav);
      final samples = Float32List.fromList(wave.samples);
      const chunk = 1024; // 64ms @ 16kHz，与 streamBufferSize 2048 字节对齐

      final asr = GeminiLiveAsrService(
        settings: AppSettings(
          asrEngine: AppConstants.asrEngineGeminiLive,
          geminiApiKey: AppConstants.defaultGeminiApiKey,
        ),
      );
      final partials = <String>[];
      try {
        await asr.initialize();
        expect(asr.isReady, isTrue, reason: asr.lastError);

        asr.onPartialText = partials.add;

        final backfill = Float32List.fromList(samples.sublist(0, chunk));
        asr.beginLiveUtterance(backfill, isStandbyWakeCheck: false);
        // 让连接/补发先跑起来，避免把首帧等待算进实时节奏。
        await Future<void>.delayed(const Duration(milliseconds: 150));

        var offset = chunk;
        while (offset < samples.length) {
          final end =
              offset + chunk < samples.length ? offset + chunk : samples.length;
          asr.appendLiveAudio(Float32List.sublistView(samples, offset, end));
          offset = end;
          await Future<void>.delayed(const Duration(milliseconds: 64));
        }

        final sw = Stopwatch()..start();
        final text = await asr.endLiveUtterance();
        sw.stop();

        // ignore: avoid_print
        print(
          'PROBE 边说边传：说完到出字 ${sw.elapsedMilliseconds}ms，'
          '文本="$text"，中间结果 ${partials.length} 条'
          '${partials.isEmpty ? '' : '（最后一条：${partials.last}）'}',
        );

        expect(text, isNotNull);
        expect(text, contains('开放时间'));
        // 分段模式实测 ~1500ms；这里留足余量，但必须明显更快。
        expect(sw.elapsedMilliseconds, lessThan(1000));
      } finally {
        asr.dispose();
      }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('同一连接连续两段边说边传', () async {
    if (Platform.environment['GEMINI_LIVE_SMOKE'] != '1') return;

    await runLiveNetworkTest(() async {
      final wave = sherpa_onnx.readWave(wav);
      final samples = Float32List.fromList(wave.samples);
      const chunk = 1024;

      final asr = GeminiLiveAsrService(
        settings: AppSettings(
          asrEngine: AppConstants.asrEngineGeminiLive,
          geminiApiKey: AppConstants.defaultGeminiApiKey,
        ),
      );
      try {
        await asr.initialize();
        for (var round = 0; round < 2; round++) {
          asr.beginLiveUtterance(
            Float32List.fromList(samples.sublist(0, chunk)),
            isStandbyWakeCheck: false,
          );
          await Future<void>.delayed(const Duration(milliseconds: 150));
          var offset = chunk;
          while (offset < samples.length) {
            final end = offset + chunk < samples.length
                ? offset + chunk
                : samples.length;
            asr.appendLiveAudio(Float32List.sublistView(samples, offset, end));
            offset = end;
            await Future<void>.delayed(const Duration(milliseconds: 16));
          }
          final text = await asr.endLiveUtterance();
          // ignore: avoid_print
          print('PROBE 第 ${round + 1} 段：$text');
          expect(text, contains('开放时间'));
        }
      } finally {
        asr.dispose();
      }
    });
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('只有云端实时引擎支持边说边传', () {
    final gemini = GeminiLiveAsrService(settings: AppSettings());
    final senseVoice = LocalSenseVoiceAsrService(settings: AppSettings());
    expect(gemini.supportsLiveStreaming, isTrue);
    expect(senseVoice.supportsLiveStreaming, isFalse);
    gemini.dispose();
  });
}
