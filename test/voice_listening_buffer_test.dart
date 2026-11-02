import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/asr_service.dart';
import 'package:side_assistant/services/speech/support/audio_segment_buffer.dart';
import 'package:side_assistant/services/speech/support/native_streaming_session.dart';
import 'package:side_assistant/services/speech/support/pcm_audio_utils.dart';
import 'package:side_assistant/services/speech/support/voice_prompt_text.dart';
import 'package:side_assistant/services/speech/voice_listening_service.dart';

import 'model_assets.dart';

/// `VoiceListeningService` 音频链路的特征测试（characterization tests）。
///
/// 前四组（预卷 / 尾静音 / 环形缓冲 / 缓冲清空）与「边说边传」组只通过
/// 公开 API 驱动（`initializeVadForTest` / `feedAudioForTest` / `getRecentAudio` /
/// `clearRecentAudio` / `flushBuffers`），不触碰任何私有字段，因此这些逻辑
/// 被抽到 `support/` 下的类之后，用例可以原样复用，作为“改动前后行为一致”的证据。
///
/// 末尾几组针对抽取出来的纯逻辑类做直接单测（流式会话 / PCM 工具 / 文案）。
const String _wavPath = 'assets/models/sense-voice/test_wavs/zh.wav';

/// VAD 依赖真实 `silero_vad.onnx`；未拉取 LFS 的环境里该文件只是指针，
/// 切不出音频段会变成一堆看不懂的 `Expected: non-empty`，因此显式 skip。
final bool _vadReady = hasRealAsset(kSileroVad);
const String _skipNoModel = kSkipNoModel;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  // 纯测试环境没有 record 原生实现，构造/释放 PlatformAudioRecorder 时会走通道。
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.llfbandit.record/messages'),
    (methodCall) async => null,
  );

  group('预卷（pre-roll）', skip: _vadReady ? false : _skipNoModel, () {
    test('preRollMs=500 时每段开头精确多出 8000 个历史采样点', () async {
      final base = await _captureVadSegments(preRollMs: 0, postRollMs: 0);
      final withPreRoll =
          await _captureVadSegments(preRollMs: 500, postRollMs: 0);

      expect(base, isNotEmpty, reason: '测试音频必须能切出至少一段 VAD 段');
      expect(withPreRoll.length, base.length);

      for (var i = 0; i < base.length; i++) {
        expect(
          withPreRoll[i].length - base[i].length,
          8000,
          reason: '500ms @ 16kHz 应恰好补回 8000 个采样点',
        );
        expect(
          withPreRoll[i].sublist(8000),
          base[i],
          reason: '预卷只加在段首，段体本身不得被改动',
        );
      }
    });

    test('preRollMs 超长时钳制在 1 秒（16000 采样点）', () async {
      // 先垫 2 秒历史音频，保证段首之前确实有超过 1 秒的可用历史，
      // 否则截取量会被“环里没那么多音频”限制，测不到 1 秒上限。
      final base = await _captureVadSegments(
          preRollMs: 0, postRollMs: 0, leadingMs: 2000);
      final withPreRoll = await _captureVadSegments(
        preRollMs: 5000,
        postRollMs: 0,
        leadingMs: 2000,
      );

      expect(base, isNotEmpty);
      expect(withPreRoll.length, base.length);
      for (var i = 0; i < base.length; i++) {
        expect(withPreRoll[i].length - base[i].length, 16000);
        expect(withPreRoll[i].sublist(16000), base[i]);
      }
    });

    test('预卷内容取自真实历史音频，而不是静音填充', () async {
      final base = await _captureVadSegments(preRollMs: 0, postRollMs: 0);
      final withPreRoll =
          await _captureVadSegments(preRollMs: 300, postRollMs: 0);

      expect(base, isNotEmpty);
      final preRoll = withPreRoll.first.sublist(0, 4800);
      var energy = 0.0;
      for (final sample in preRoll) {
        energy += sample * sample;
      }
      expect(energy, greaterThan(0.0), reason: '预卷必须来自音频环，不能是全 0 垫片');
    });
  });

  group('尾静音（tail silence）', skip: _vadReady ? false : _skipNoModel, () {
    test('postRollMs=300 时每段尾部追加 4800 个静音采样点', () async {
      final base = await _captureVadSegments(preRollMs: 0, postRollMs: 0);
      final withTail = await _captureVadSegments(preRollMs: 0, postRollMs: 300);

      expect(base, isNotEmpty);
      expect(withTail.length, base.length);
      for (var i = 0; i < base.length; i++) {
        expect(withTail[i].length - base[i].length, 4800);
        expect(
          withTail[i].sublist(0, base[i].length),
          base[i],
          reason: '尾静音只追加在段尾',
        );
        for (final sample in withTail[i].sublist(base[i].length)) {
          expect(sample, 0.0);
        }
      }
    });

    test('postRollMs 超长时同样钳制在 1 秒', () async {
      final base = await _captureVadSegments(preRollMs: 0, postRollMs: 0);
      final withTail =
          await _captureVadSegments(preRollMs: 0, postRollMs: 5000);

      expect(base, isNotEmpty);
      for (var i = 0; i < base.length; i++) {
        expect(withTail[i].length - base[i].length, 16000);
      }
    });

    test('preRoll 与 postRoll 同时开启时长度可叠加', () async {
      final base = await _captureVadSegments(preRollMs: 0, postRollMs: 0);
      final both = await _captureVadSegments(preRollMs: 500, postRollMs: 200);

      expect(base, isNotEmpty);
      for (var i = 0; i < base.length; i++) {
        expect(both[i].length - base[i].length, 8000 + 3200);
        expect(both[i].sublist(8000, 8000 + base[i].length), base[i]);
      }
    });
  });

  group('环形缓冲', skip: _vadReady ? false : _skipNoModel, () {
    test('喂入超过 35 秒音频后 getRecentAudio 仍返回连续的最新片段', () async {
      final service = await _buildService();
      addTearDown(service.dispose);

      const chunkSamples = 16000; // 1s
      const totalChunks = 36; // 超过 35s 容量，必然发生回绕
      var written = 0;
      for (var c = 0; c < totalChunks; c++) {
        final chunk = Float32List(chunkSamples);
        for (var i = 0; i < chunkSamples; i++) {
          chunk[i] = ((written + i) % 1000) / 1000.0;
        }
        written += chunkSamples;
        await service.feedAudioForTest(chunk);
      }

      final recent = service.getRecentAudio(seconds: 2.5);
      expect(recent.length, 40000, reason: '2.5s @ 16kHz');
      final expectedStart = written - 40000;
      for (var i = 0; i < recent.length; i++) {
        expect(
          recent[i],
          closeTo(((expectedStart + i) % 1000) / 1000.0, 1e-6),
        );
      }
    });

    test('请求长度超过已有音频时返回全部可用样本', () async {
      final service = await _buildService();
      addTearDown(service.dispose);

      await service.feedAudioForTest(Float32List(16000));

      expect(service.getRecentAudio(seconds: 10).length, 16000);
    });

    test('多次小块追加与一次大块追加得到相同的最近音频', () async {
      final chunked = await _buildService();
      addTearDown(chunked.dispose);
      final whole = await _buildService();
      addTearDown(whole.dispose);

      final source = Float32List(12000);
      for (var i = 0; i < source.length; i++) {
        source[i] = (i % 100) / 100.0;
      }
      for (var i = 0; i < source.length; i += 700) {
        final end = math.min(i + 700, source.length);
        await chunked.feedAudioForTest(Float32List.sublistView(source, i, end));
      }
      await whole.feedAudioForTest(source);

      expect(
        chunked.getRecentAudio(seconds: 1.0),
        whole.getRecentAudio(seconds: 1.0),
      );
    });
  });

  group('边说边传（live）', skip: _vadReady ? false : _skipNoModel, () {
    test('VAD 判定说话即开流，切段后收尾并回调最终文本', () async {
      final asr = _FakeLiveAsrService(
        settings: AppSettings(),
        liveText: '小曼你好',
      );
      final recognized = <String>[];
      final service = await _buildService(
        asrService: asr,
        onTextRecognized: recognized.add,
      );
      addTearDown(service.dispose);

      await _feedWavAndSilence(service);

      expect(asr.beginCount, 1, reason: 'VAD 一旦判定说话就必须立刻开流');
      expect(asr.appendedSamples, greaterThan(0));
      expect(asr.endCount, 1, reason: '说话结束必须收尾');
      expect(recognized, ['小曼你好']);
      expect(service.lastRecognizedAudio, isNotNull);
    });

    test('live 没接住时用 VAD 整段音频回退识别', () async {
      final asr = _FakeLiveAsrService(
        settings: AppSettings(),
        liveText: null,
        fallbackText: '回退结果',
      );
      final recognized = <String>[];
      final service = await _buildService(
        asrService: asr,
        onTextRecognized: recognized.add,
      );
      addTearDown(service.dispose);

      await _feedWavAndSilence(service);

      expect(asr.endCount, 1);
      expect(asr.fallbackSamples, isNotEmpty, reason: '回退必须送整段 VAD 音频');
      expect(recognized, ['回退结果']);
    });
  });

  group('缓冲清空', skip: _vadReady ? false : _skipNoModel, () {
    test('clearRecentAudio 立即清空预卷环', () async {
      final service = await _buildService();
      addTearDown(service.dispose);

      await service.feedAudioForTest(Float32List(16000));
      expect(service.getRecentAudio(seconds: 2.5), isNotEmpty);

      service.clearRecentAudio();
      expect(service.getRecentAudio(seconds: 2.5), isEmpty);
    });

    test('flushBuffers 清空音频环并进入冷却窗，冷却期内不再采集', () async {
      final service = await _buildService();
      addTearDown(service.dispose);

      await service.feedAudioForTest(Float32List(16000));
      expect(service.getRecentAudio(seconds: 2.5), isNotEmpty);

      service.flushBuffers(cooldownMs: 400);
      expect(service.getRecentAudio(seconds: 2.5), isEmpty);
      expect(service.isInCooldownWindow, isTrue);

      await service.feedAudioForTest(Float32List(16000));
      expect(
        service.getRecentAudio(seconds: 2.5),
        isEmpty,
        reason: '冷却窗内的音频必须被丢弃，避免播放尾音被当成用户语音',
      );
    });

    test('冷却窗结束后恢复采集', () async {
      final service = await _buildService();
      addTearDown(service.dispose);

      service.flushBuffers(cooldownMs: 0);
      expect(service.isInCooldownWindow, isFalse);

      await service.feedAudioForTest(Float32List(16000));
      expect(service.getRecentAudio(seconds: 2.5).length, 16000);
    });

    test('performIdleHygiene 清空待机期间积压的音频环', () async {
      final service = await _buildService();
      addTearDown(service.dispose);

      await service.feedAudioForTest(Float32List(16000));
      expect(service.getRecentAudio(seconds: 2.5), isNotEmpty);

      service.performIdleHygiene();
      expect(service.getRecentAudio(seconds: 2.5), isEmpty);
    });
  });

  group('内置流式会话（NativeStreamingSession）', () {
    test('逐块解码测试语音并回调识别文本', () async {
      final asr = StreamingZipformerAsrService(settings: AppSettings());
      await asr.initialize();
      addTearDown(asr.dispose);

      final buffer = AudioSegmentBuffer();
      final texts = <String>[];
      var recognizedAudioCount = 0;
      final session = NativeStreamingSession(
        asrService: () => asr,
        buffer: buffer,
        hotwords: () => '研究 介绍',
        isStandby: () => true,
        isPlaying: () => false,
        isMicTesting: () => false,
        isEnrollingSpeaker: () => false,
        isInCooldown: () => false,
        onTextRecognized: texts.add,
        onRecognizedAudio: (_) => recognizedAudioCount++,
        onFinalPass: (_) {},
      );

      final wave = sherpa_onnx.readWave(_wavPath);
      const chunkSamples = 1600;
      for (var i = 0; i < wave.samples.length; i += chunkSamples) {
        final end = math.min(i + chunkSamples, wave.samples.length);
        final chunk = Float32List.fromList(wave.samples.sublist(i, end));
        buffer.addUtterance(chunk);
        session.accept(chunk);
      }

      expect(texts, isNotEmpty, reason: '流式会话必须把解码结果回调出去');
      expect(recognizedAudioCount, texts.length, reason: '每条文本都要带上对应音频');
    });

    test('reset 清空整段缓冲并允许重新解码', () async {
      final asr = StreamingZipformerAsrService(settings: AppSettings());
      await asr.initialize();
      addTearDown(asr.dispose);

      final buffer = AudioSegmentBuffer();
      final session = NativeStreamingSession(
        asrService: () => asr,
        buffer: buffer,
        hotwords: () => '',
        isStandby: () => true,
        isPlaying: () => false,
        isMicTesting: () => false,
        isEnrollingSpeaker: () => false,
        isInCooldown: () => false,
        onTextRecognized: (_) {},
        onRecognizedAudio: (_) {},
        onFinalPass: (_) {},
      );

      final wave = sherpa_onnx.readWave(_wavPath);
      final chunk = Float32List.fromList(wave.samples.sublist(0, 16000));
      buffer.addUtterance(chunk);
      session.accept(chunk);
      expect(buffer.utteranceLength, greaterThan(0));

      session.reset();
      expect(buffer.utteranceLength, 0);
    });
  });

  group('PCM 工具（PcmAudioUtils）', () {
    test('16bit 小端 PCM 解码为 [-1, 1) 浮点', () {
      final bytes = Uint8List(6);
      final data = ByteData.sublistView(bytes);
      data.setInt16(0, 16384, Endian.little);
      data.setInt16(2, -32768, Endian.little);
      data.setInt16(4, 0, Endian.little);

      final samples = PcmAudioUtils.pcm16ToFloat32(bytes);
      expect(samples.length, 3);
      expect(samples[0], closeTo(0.5, 1e-6));
      expect(samples[1], -1.0);
      expect(samples[2], 0.0);
      expect(PcmAudioUtils.pcm16ToFloat32(Uint8List(1)), isEmpty);
    });

    test('静音电平钳制在 -60dBFS / 0 电平', () {
      final level = PcmAudioUtils.measureLevel(Float32List(1600));
      expect(level.rms, 0.0);
      expect(level.dbfs, -60.0);
      expect(level.level, 0.0);
    });
  });

  group('语音文案（VoicePromptText）', () {
    test('热词表包含唤醒词、结束词与固定别名', () {
      final settings = AppSettings(startWord: '小美', endWord: '完毕');
      final hotwords = VoicePromptText.hotwords(settings);

      expect(hotwords, contains('小美'));
      expect(hotwords, contains('完毕'));
      expect(hotwords, contains('小曼'));
      expect(hotwords, contains('侧边助手'));
      expect(hotwords.split(' ').toSet().length, hotwords.split(' ').length,
          reason: '热词表必须去重');
    });
  });
}

Future<VoiceListeningService> _buildService({
  int preRollMs = 0,
  int postRollMs = 0,
  AsrService? asrService,
  void Function(String text)? onTextRecognized,
}) async {
  final settings = AppSettings(
    preRollMs: preRollMs,
    postRollMs: postRollMs,
  );
  final service = VoiceListeningService(
    asrService: asrService ?? _CapturingAsrService(settings),
    settings: settings,
    onTextRecognized: onTextRecognized ?? (_) {},
  );
  await service.initializeVadForTest();
  return service;
}

/// 用真实 Silero VAD 切段，并把送进 ASR 的音频原样留档。
Future<List<Float32List>> _captureVadSegments({
  required int preRollMs,
  required int postRollMs,
  int leadingMs = 0,
}) async {
  final asr = _CapturingAsrService(
    AppSettings(preRollMs: preRollMs, postRollMs: postRollMs),
  );
  final service = await _buildService(
    preRollMs: preRollMs,
    postRollMs: postRollMs,
    asrService: asr,
  );
  try {
    const chunkSamples = 1600;
    final leading = Float32List(leadingMs * 16);
    for (var i = 0; i < leading.length; i += chunkSamples) {
      await service.feedAudioForTest(
        Float32List.sublistView(leading, i, i + chunkSamples),
      );
    }
    final wave = sherpa_onnx.readWave(_wavPath);
    for (var i = 0; i < wave.samples.length; i += chunkSamples) {
      final end = math.min(i + chunkSamples, wave.samples.length);
      await service.feedAudioForTest(
        Float32List.fromList(wave.samples.sublist(i, end)),
      );
    }
    // 尾部补 1 秒静音，逼 VAD 把最后一段弹出来。
    final silence = Float32List(16000);
    for (var i = 0; i < silence.length; i += chunkSamples) {
      await service.feedAudioForTest(
        Float32List.sublistView(silence, i, i + chunkSamples),
      );
    }
    return asr.captured;
  } finally {
    service.dispose();
  }
}

/// 喂入测试语音 + 1 秒尾静音，并让出事件循环等待异步收尾落地。
Future<void> _feedWavAndSilence(VoiceListeningService service) async {
  const chunkSamples = 1600;
  final wave = sherpa_onnx.readWave(_wavPath);
  for (var i = 0; i < wave.samples.length; i += chunkSamples) {
    final end = math.min(i + chunkSamples, wave.samples.length);
    await service.feedAudioForTest(
      Float32List.fromList(wave.samples.sublist(i, end)),
    );
  }
  final silence = Float32List(16000);
  for (var i = 0; i < silence.length; i += chunkSamples) {
    await service.feedAudioForTest(
      Float32List.sublistView(silence, i, i + chunkSamples),
    );
  }
  // live 收尾走 Future 队列，需要让出事件循环。
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _CapturingAsrService extends AsrService {
  @override
  final AppSettings settings;

  final List<Float32List> captured = <Float32List>[];

  _CapturingAsrService(this.settings);

  @override
  bool get isReady => true;

  @override
  Future<String> transcribeSamples(
    Float32List samples, {
    int sampleRate = 16000,
    bool isStandbyWakeCheck = false,
    bool fromVad = false,
  }) async {
    captured.add(Float32List.fromList(samples));
    return '';
  }
}

/// 模拟“边说边传”的云端引擎：只记录 begin/append/end 的调用与音频。
class _FakeLiveAsrService extends AsrService {
  @override
  final AppSettings settings;

  /// endLiveUtterance 的返回值：null 表示没接住（走整段回退）。
  final String? liveText;

  /// 整段回退识别时返回的文本。
  final String fallbackText;

  int beginCount = 0;
  int endCount = 0;
  int appendedSamples = 0;
  Float32List? fallbackSamples;

  _FakeLiveAsrService({
    required this.settings,
    this.liveText,
    this.fallbackText = '',
  });

  @override
  bool get isReady => true;

  @override
  bool get supportsLiveStreaming => true;

  @override
  void beginLiveUtterance(
    Float32List backfill, {
    bool isStandbyWakeCheck = false,
  }) {
    beginCount++;
  }

  @override
  void appendLiveAudio(Float32List samples) {
    appendedSamples += samples.length;
  }

  @override
  Future<String?> endLiveUtterance() async {
    endCount++;
    return liveText;
  }

  @override
  Future<String> transcribeSamples(
    Float32List samples, {
    int sampleRate = 16000,
    bool isStandbyWakeCheck = false,
    bool fromVad = false,
  }) async {
    fallbackSamples = Float32List.fromList(samples);
    return fallbackText;
  }
}
