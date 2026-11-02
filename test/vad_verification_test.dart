import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/asr_service.dart';

import 'model_assets.dart';

void main() {
  test('VoiceActivityDetector and SenseVoice end-to-end memory pipeline test',
      () async {
    // 统一走工程内的绑定初始化（Windows 预加载 dll / Linux 从 pub-cache 里找 .so），
    // 不要直接调 sherpa_onnx.initBindings()，否则 Linux 上找不到
    // libsherpa-onnx-c-api.so 会直接抛 DynamicLibrary.open 失败。
    ensureSherpaBindings();

    const vadModelPath = 'assets/models/silero_vad.onnx';
    expect(File(vadModelPath).existsSync(), isTrue);

    final config = sherpa_onnx.VadModelConfig(
      sileroVad: const sherpa_onnx.SileroVadModelConfig(
        model: vadModelPath,
        threshold: 0.5,
        minSilenceDuration: 0.35,
        minSpeechDuration: 0.2,
        windowSize: 512,
        maxSpeechDuration: 10.0,
      ),
      sampleRate: 16000,
      numThreads: 1,
      provider: 'cpu',
      debug: false,
    );

    final vad = sherpa_onnx.VoiceActivityDetector(
      config: config,
      bufferSizeInSeconds: 30,
    );

    // Read the test wav
    const zhWavPath = 'assets/models/sense-voice/test_wavs/zh.wav';
    expect(File(zhWavPath).existsSync(), isTrue);
    final wave = sherpa_onnx.readWave(zhWavPath);

    // Feed in chunks of 512 samples to simulate streaming input
    const chunkSize = 512;
    for (int i = 0; i < wave.samples.length; i += chunkSize) {
      final end = (i + chunkSize < wave.samples.length)
          ? i + chunkSize
          : wave.samples.length;
      final chunk = wave.samples.sublist(i, end);
      vad.acceptWaveform(chunk);
    }
    vad.flush();

    expect(vad.isEmpty(), isFalse);
    final segment = vad.front();
    vad.pop();

    expect(segment.samples.isNotEmpty, isTrue);

    // Initialize LocalSenseVoiceAsrService
    final settings = AppSettings();
    final asr = LocalSenseVoiceAsrService(settings: settings);
    await asr.initialize();
    expect(asr.isReady, isTrue);

    final recognized = await asr.transcribeSamples(segment.samples);
    expect(recognized.isNotEmpty, isTrue);
    // 这里只验证 VAD 分段 + SenseVoice 链路能产出完整时间句，
    // 不把某一次具体误识别（如“开放”识别成“派饭”）固化成测试预期。
    expect(recognized.contains('时间'), isTrue);

    vad.free();
    asr.dispose();
  },
      skip: skipUnlessAssets([
        kSileroVad,
        kSenseVoiceModel,
        kSenseVoiceTokens,
      ]));
}
