import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/asr_service.dart';

/// 流式 Zipformer 端到端冒烟测试。
///
/// 使用仓库内自带的 [zh.wav]，不依赖 %TEMP% 下手工下载的模型测试音频，
/// 保证在任何机器上 `flutter test` 都能跑通。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const wavFile = 'assets/models/sense-voice/test_wavs/zh.wav';

  test('StreamingZipformerAsrService 端到端流式识别冒烟测试', () async {
    expect(File(wavFile).existsSync(), isTrue, reason: '缺少测试音频 $wavFile');

    final asr = StreamingZipformerAsrService(settings: AppSettings());
    await asr.initialize();
    expect(asr.isReady, isTrue);
    expect(asr.isStreaming, isTrue);

    final wave = sherpa_onnx.readWave(wavFile);

    // 1. 整段批量识别
    final batchText = await asr.transcribeSamples(wave.samples, sampleRate: wave.sampleRate);
    debugPrint('[BATCH RECOGNITION RESULT]: "$batchText"');
    expect(batchText.isNotEmpty, isTrue);

    // 2. 逐 100ms 切片实时流式解码，模拟真实麦克风喂数据
    final stream = asr.createOnlineStream(hotwords: '研究 介绍');
    expect(stream, isNotNull);
    final recognizer = asr.onlineRecognizer;
    expect(recognizer, isNotNull);

    const chunkSize = 1600; // 100ms @16kHz
    String liveText = '';
    for (int i = 0; i < wave.samples.length; i += chunkSize) {
      final end = (i + chunkSize < wave.samples.length) ? i + chunkSize : wave.samples.length;
      stream!.acceptWaveform(samples: wave.samples.sublist(i, end), sampleRate: wave.sampleRate);

      while (recognizer!.isReady(stream)) {
        recognizer.decode(stream);
      }
      final cur = recognizer.getResult(stream).text;
      if (cur.isNotEmpty && cur != liveText) {
        liveText = cur;
        debugPrint('[LIVE STREAMING]: "$liveText"');
      }
    }

    stream!.inputFinished();
    while (recognizer!.isReady(stream)) {
      recognizer.decode(stream);
    }
    final streamFinal = recognizer.getResult(stream).text;
    debugPrint('[STREAMING FINAL]: "$streamFinal"');
    expect(streamFinal.isNotEmpty, isTrue);

    stream.free();
    asr.dispose();
  }, timeout: const Timeout(Duration(minutes: 2)));
}
