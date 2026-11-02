import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:side_assistant/controllers/assistant_controller.dart';
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/asr_service.dart';
import 'package:side_assistant/services/speech/speaker_verification_service.dart';

import 'model_assets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.llfbandit.record/messages'),
      (methodCall) async => null,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers.global'),
      (methodCall) async => 1,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('xyz.luan/audioplayers'),
      (methodCall) async => 1,
    );
    SharedPreferences.setMockInitialValues({});
    ensureSherpaBindings();
  });

  group('AppSettings - 主人声纹配置测试', () {
    test('默认配置应为关闭，阈值 0.55，仅唤醒校验', () {
      final settings = AppSettings();
      expect(settings.enableSpeakerVerification, isFalse);
      expect(settings.speakerSimilarityThreshold, equals(0.55));
      expect(settings.speakerVerifyWakeOnly, isTrue);
      expect(settings.speakerMinSpeechSeconds, equals(0.30));
      expect(settings.ownerSpeakerEmbeddings, isEmpty);
      expect(settings.speakerModelPath, isEmpty);
    });

    test('toMap 与 fromMap 应正确序列化与反序列化声纹配置与向量', () {
      final original = AppSettings(
        enableSpeakerVerification: true,
        speakerSimilarityThreshold: 0.62,
        speakerVerifyWakeOnly: false,
        speakerMinSpeechSeconds: 0.25,
        speakerModelPath: 'custom/model.onnx',
        ownerSpeakerEmbeddings: [
          [0.1, 0.2, 0.3],
          [0.4, 0.5, 0.6],
        ],
      );

      final map = original.toMap();
      final restored = AppSettings.fromMap(map);

      expect(restored.enableSpeakerVerification, isTrue);
      expect(restored.speakerSimilarityThreshold, closeTo(0.62, 0.001));
      expect(restored.speakerVerifyWakeOnly, isFalse);
      expect(restored.speakerMinSpeechSeconds, closeTo(0.25, 0.001));
      expect(restored.speakerModelPath, equals('custom/model.onnx'));
      expect(restored.ownerSpeakerEmbeddings.length, equals(2));
      expect(restored.ownerSpeakerEmbeddings[0], equals([0.1, 0.2, 0.3]));
      expect(restored.ownerSpeakerEmbeddings[1], equals([0.4, 0.5, 0.6]));
    });
  });

  group('SpeakerVerificationService - 声纹提取与验证测试', () {
    const modelPath =
        'assets/models/speaker/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx';
    const zhWavPath = 'assets/models/sense-voice/test_wavs/zh.wav';
    const enWavPath = 'assets/models/sense-voice/test_wavs/en.wav';

    test('音频波形动态规整测试 (normalizeWaveform)', () {
      final quiet = Float32List.fromList([0.02, -0.04, 0.03, -0.01]);
      final loud = Float32List.fromList([0.2, -0.4, 0.3, -0.1]); // 10x volume

      final normQuiet = SpeakerVerificationService.normalizeWaveform(quiet);
      final normLoud = SpeakerVerificationService.normalizeWaveform(loud);

      // 无论原始信号是 0.04 还是 0.4，归一化后峰值与波形比例完全一致
      expect(normQuiet.length, equals(quiet.length));
      expect(normLoud.length, equals(loud.length));
      for (int i = 0; i < quiet.length; i++) {
        expect(normQuiet[i], closeTo(normLoud[i], 0.01));
      }

      // 超大音量（发生削顶风险）
      final huge = Float32List.fromList([2.5, -3.8, 1.9, -0.8]);
      final normHuge = SpeakerVerificationService.normalizeWaveform(huge);
      for (final s in normHuge) {
        expect(s.abs(), lessThanOrEqualTo(1.0));
      }

      // 微弱底噪保留不盲目放大
      final silence = Float32List.fromList([1e-6, -2e-6, 0.0]);
      final normSilence = SpeakerVerificationService.normalizeWaveform(silence);
      expect(normSilence[0], closeTo(1e-6, 1e-8));
    });

    test('模型加载与特征提取维度', () async {
      expect(File(modelPath).existsSync(), isTrue,
          reason: '声纹模型文件必须存在于 assets 目录');

      final settings = AppSettings(
        enableSpeakerVerification: true,
        speakerModelPath: modelPath,
      );
      final service = SpeakerVerificationService(settings: settings);

      final ok = await service.initialize();
      expect(ok, isTrue);
      expect(service.isReady, isTrue);
      expect(service.embeddingDim, equals(192));

      service.dispose();
      expect(service.isReady, isFalse);
    }, skip: skipUnlessAsset(kCampplusSpeakerModel));

    test('语音裁剪 trimToSpeech', () {
      final rnd = math.Random(11);
      Float32List noise(int seconds, double amp) =>
          Float32List.fromList(List.generate(
              seconds * 16000, (_) => (rnd.nextDouble() * 2 - 1) * amp));

      // 生成带声带基频谐波 (F0=140Hz) 与共振峰高频分量及音节包络调制的模拟人声
      Float32List voicedSpeech(int seconds, double amp) {
        final len = seconds * 16000;
        final out = Float32List(len);
        for (int i = 0; i < len; i++) {
          final t = i / 16000.0;
          // 4Hz 音节包络调制 (模拟说话字词起伏)
          final env =
              0.35 + 0.65 * (0.5 + 0.5 * math.sin(2 * math.pi * 4.0 * t));
          final harmonic = 0.50 * math.sin(2 * math.pi * 140.0 * t) +
              0.30 * math.sin(2 * math.pi * 280.0 * t) +
              0.25 * math.sin(2 * math.pi * 840.0 * t) +
              0.20 * math.sin(2 * math.pi * 1680.0 * t);
          out[i] = (amp * env * harmonic).clamp(-1.0, 1.0);
        }
        return out;
      }

      // 1. 纯静音 -> 空（无有效人声）
      expect(
          SpeakerVerificationService.trimToSpeech(Float32List(32000)), isEmpty);
      expect(
          SpeakerVerificationService.trimToSpeech(noise(3, 0.0001)), isEmpty);

      // 2. 中间 2 秒有声人声 + 首尾 2 秒静音 -> 裁掉首尾静音，长度接近 2 秒
      final padded = Float32List(4 * 16000 + 32000);
      final speech = voicedSpeech(2, 0.18);
      padded.setRange(2 * 16000, 2 * 16000 + speech.length, speech);
      final trimmed = SpeakerVerificationService.trimToSpeech(padded);
      expect(trimmed.length, lessThan(padded.length));
      expect(trimmed.length / 16000, greaterThanOrEqualTo(1.8));
      expect(trimmed.length / 16000, lessThan(2.5));

      // 3. 稳态背景噪声（包络平坦无音节调制，如风扇声/白噪声）-> 应被判为无人声并拒绝
      final stationaryNoise = noise(3, 0.12);
      expect(SpeakerVerificationService.trimToSpeech(stationaryNoise), isEmpty);

      // 3.2 蓝牙硬件静音门场景（前 1.8s 纯零 + 后 1.0s 无谐波噪声突发）-> 必须拦截，不能被静音门零底噪欺骗
      final btGatedNoise = Float32List(46000);
      final burstNoise = noise(1, 0.05);
      btGatedNoise.setRange(28800, 28800 + 16000, burstNoise);
      expect(SpeakerVerificationService.trimToSpeech(btGatedNoise), isEmpty);

      // 3.5 两段 1 秒有声语音之间夹杂 1.5 秒静音/底噪 -> 应剔除中间静音段，仅拼接两段有效语音
      final twoBursts = Float32List((3.5 * 16000).round());
      twoBursts.setRange(0, 16000, voicedSpeech(1, 0.18));
      twoBursts.setRange(
          (2.5 * 16000).round(), (3.5 * 16000).round(), voicedSpeech(1, 0.18));
      final trimmedBursts = SpeakerVerificationService.trimToSpeech(twoBursts);
      expect(trimmedBursts.length / 16000, greaterThanOrEqualTo(1.7));
      expect(trimmedBursts.length / 16000, lessThan(2.4));

      // 4. 零星脉冲（占比过低）-> 判为无人声
      final blips = Float32List(3 * 16000);
      blips.setRange(0, 320, voicedSpeech(1, 0.3).sublist(0, 320));
      blips.setRange(4000, 4320, voicedSpeech(1, 0.3).sublist(0, 320));
      expect(SpeakerVerificationService.trimToSpeech(blips), isEmpty);
    });

    test('多样本鲁棒聚合应抑制被污染的单个样本', () {
      final settings = AppSettings(enableSpeakerVerification: true);
      final service = SpeakerVerificationService(settings: settings);

      // 4 个主人样本（e0 方向）+ 1 个误录的电视样本（e1 方向）
      List<double> axis(int i) => List<double>.filled(4, 0.0)..[i] = 1.0;
      settings.ownerSpeakerEmbeddings = [
        axis(0),
        axis(0),
        axis(0),
        axis(0),
        axis(1),
      ];

      final tvCandidate = axis(1);
      final analysis = service.computeMatchScore(tvCandidate);
      expect(analysis, isNotNull);
      // 单样本最高分被污染样本抬高，鲁棒综合分必须显著低于它
      expect(analysis!.maxSampleSimilarity, closeTo(1.0, 0.01));
      expect(analysis.similarity, lessThan(0.6));
      expect(analysis.meanSampleSimilarity, closeTo(0.2, 0.01));

      // 主人样本一致时综合分应保持高分
      final ownerAnalysis = service.computeMatchScore(axis(0));
      expect(ownerAnalysis!.similarity, greaterThan(0.8));

      service.dispose();
    });

    test('dropoutRatio：正常音频≈0，蓝牙 mSBC 式斩波显著偏高', () {
      final clean = Float32List(16000);
      for (int i = 0; i < clean.length; i++) {
        clean[i] = 0.1 * math.sin(2 * math.pi * 180 * i / 16000) + 0.01;
      }
      expect(SpeakerVerificationService.dropoutRatio(clean), lessThan(0.01));

      // 每 683 采样点保留 ~350 个有效值，其余置 0（233 上实测的 mSBC 丢包模式）
      final chopped = Float32List.fromList(clean);
      for (int b = 0; b + 683 <= chopped.length; b += 683) {
        for (int k = 350; k < 683; k++) {
          chopped[b + k] = 0.0;
        }
      }
      expect(
          SpeakerVerificationService.dropoutRatio(chopped), greaterThan(0.3));
    });

    test('已录入主人声纹时，无足够清晰人声不得放行（防电视/杂音绕过）', () async {
      final settings = AppSettings(
        enableSpeakerVerification: true,
        speakerModelPath: modelPath,
      );
      final service = SpeakerVerificationService(settings: settings);
      await service.initialize();
      final waveZh = sherpa_onnx.readWave(zhWavPath);
      expect(await service.enrollOwner(waveZh.samples), isTrue);

      // 过短音频
      final tooShort = service.verifyOwner(Float32List(4000));
      expect(tooShort.isMatched, isFalse);
      expect(tooShort.bypassed, isFalse);

      // 够长但全是静音/无人声
      final silence = service.verifyOwner(Float32List(32000));
      expect(silence.isMatched, isFalse);
      expect(silence.bypassed, isFalse);

      service.dispose();
    }, skip: skipUnlessAsset(kCampplusSpeakerModel));

    test('声纹识别最短有效时长参数应支持 0.2s~0.6s 动态调节', () {
      final settings = AppSettings(
        enableSpeakerVerification: true,
        speakerMinSpeechSeconds: 0.20,
      );
      final service = SpeakerVerificationService(settings: settings);
      expect(service.minSpeechSeconds, closeTo(0.20, 0.001));
      expect(service.minAudioSamples, equals(3200));

      settings.speakerMinSpeechSeconds = 0.60;
      expect(service.minSpeechSeconds, closeTo(0.60, 0.001));
      expect(service.minAudioSamples, equals(9600));

      settings.speakerMinSpeechSeconds = 0.35;
      expect(service.minSpeechSeconds, closeTo(0.35, 0.001));
      expect(service.minAudioSamples, equals(5600));

      // 边界 clamp 测试
      settings.speakerMinSpeechSeconds = 0.05;
      expect(service.minSpeechSeconds, closeTo(0.20, 0.001));
      settings.speakerMinSpeechSeconds = 1.5;
      expect(service.minSpeechSeconds, closeTo(0.60, 0.001));

      service.dispose();
    });

    test('声纹验证开关未开启时应直接放行 (bypassed)', () {
      final settings = AppSettings(enableSpeakerVerification: false);
      final service = SpeakerVerificationService(settings: settings);

      final wave = sherpa_onnx.readWave(zhWavPath);
      final result = service.verifyOwner(wave.samples);

      expect(result.isMatched, isTrue);
      expect(result.bypassed, isTrue);

      service.dispose();
    });

    test('尚未录入声纹样本时应默认放行 (noOwnerEnrolled)', () {
      final settings = AppSettings(
        enableSpeakerVerification: true,
        ownerSpeakerEmbeddings: [],
      );
      final service = SpeakerVerificationService(settings: settings);

      final wave = sherpa_onnx.readWave(zhWavPath);
      final result = service.verifyOwner(wave.samples);

      expect(result.isMatched, isTrue);
      expect(result.hasEnrolledOwner, isFalse);

      service.dispose();
    });

    test('录入主人声纹后，同说话人通过、异说话人拦截', () async {
      final settings = AppSettings(
        enableSpeakerVerification: true,
        speakerSimilarityThreshold: 0.55,
        speakerModelPath: modelPath,
      );
      final service = SpeakerVerificationService(settings: settings);
      await service.initialize();

      final waveZh = sherpa_onnx.readWave(zhWavPath);
      final mid = waveZh.samples.length ~/ 2;
      final zhPart1 = waveZh.samples.sublist(0, mid);
      final zhPart2 = waveZh.samples.sublist(mid);

      // 1. 录入 zhPart1 作为主人声纹
      final enrolled = await service.enrollOwner(zhPart1);
      expect(enrolled, isTrue);
      expect(service.hasEnrolledOwner, isTrue);
      expect(service.enrolledSampleCount, equals(1));

      // 2. 用 zhPart2 进行验证（同一个说话人的后半句话）
      final verifySame = service.verifyOwner(zhPart2);
      expect(verifySame.isMatched, isTrue);
      expect(verifySame.similarity, greaterThan(0.55));
      expect(verifySame.similarity, closeTo(0.69, 0.15));

      // 3. 用 en.wav 进行验证（完全不同的英语说话人）
      final waveEn = sherpa_onnx.readWave(enWavPath);
      final verifyDiff = service.verifyOwner(waveEn.samples);
      expect(verifyDiff.isMatched, isFalse);
      expect(verifyDiff.similarity, lessThan(0.30));

      // 4. 清空声纹
      await service.clearOwnerEmbeddings();
      expect(service.hasEnrolledOwner, isFalse);
      expect(service.enrolledSampleCount, equals(0));

      service.dispose();
    }, skip: skipUnlessAsset(kCampplusSpeakerModel));

    test('蓝牙 SCO 周期性丢包零填充补偿 (concealBluetoothScoDropouts) 与声纹识别鲁棒性', () async {
      final settings = AppSettings(
        enableSpeakerVerification: true,
        speakerSimilarityThreshold: 0.55,
        speakerModelPath: modelPath,
      );
      final service = SpeakerVerificationService(settings: settings);
      await service.initialize();

      // 模拟 BCM20702 蓝牙 mSBC 每 683 采样点 (42.67ms) 丢失 323 个采样点并填 0.0
      Float32List simulateScoDropouts(Float32List src) {
        final out = Float32List.fromList(src);
        for (int i = 0; i < out.length; i += 683) {
          final zStart = i + 360;
          final zEnd = math.min(out.length, i + 683);
          for (int k = zStart; k < zEnd; k++) {
            out[k] = 0.0;
          }
        }
        return out;
      }

      final waveZh = sherpa_onnx.readWave(zhWavPath);
      final waveEn = sherpa_onnx.readWave(enWavPath);
      final mid = waveZh.samples.length ~/ 2;
      final zhPart1Sco = simulateScoDropouts(waveZh.samples.sublist(0, mid));
      final zhPart2Sco = simulateScoDropouts(waveZh.samples.sublist(mid));
      final enSco = simulateScoDropouts(waveEn.samples);

      // 1. 被 SCO 周期性切碎的人声经补偿后应能正常通过 trimToSpeech 检测
      final trimmed =
          SpeakerVerificationService.trimToSpeech(zhPart1Sco, minSeconds: 0.6);
      expect(trimmed.length / 16000.0, greaterThanOrEqualTo(0.6));

      // 2. 被 SCO 周期性切碎的纯白噪声不产生伪造谐波，仍必须被 trimToSpeech 拦截
      final rnd = math.Random(99);
      final rawNoise = Float32List.fromList(
          List.generate(3 * 16000, (_) => (rnd.nextDouble() * 2 - 1) * 0.05));
      final scoNoise = simulateScoDropouts(rawNoise);
      expect(SpeakerVerificationService.trimToSpeech(scoNoise, minSeconds: 0.6),
          isEmpty);

      // 3. 在 SCO 丢包环境下录入与验证：同说话人高分通过，异说话人低分拦截
      final enrolled = await service.enrollOwner(zhPart1Sco);
      expect(enrolled, isTrue);

      final verifySame = service.verifyOwner(zhPart2Sco);
      expect(verifySame.isMatched, isTrue);
      expect(verifySame.similarity, greaterThan(0.55));

      final verifyDiff = service.verifyOwner(enSco);
      expect(verifyDiff.isMatched, isFalse);
      expect(verifyDiff.similarity, lessThan(0.42));

      service.dispose();
    }, skip: skipUnlessAsset(kCampplusSpeakerModel));

    test('多样本录入上限保护（最多保留 5 个样本）', () async {
      final settings = AppSettings(
        enableSpeakerVerification: true,
        speakerModelPath: modelPath,
      );
      final service = SpeakerVerificationService(settings: settings);
      await service.initialize();

      final waveZh = sherpa_onnx.readWave(zhWavPath);

      for (int i = 0; i < 7; i++) {
        await service.enrollOwner(waveZh.samples);
      }

      expect(service.enrolledSampleCount, equals(5));

      service.dispose();
    }, skip: skipUnlessAsset(kCampplusSpeakerModel));
  });

  group('AppSettings - 开始词检测与静音超时范围测试', () {
    test('默认配置：开启开始词检测，静音超时默认 12 秒', () {
      final settings = AppSettings();
      expect(settings.enableStartWordDetection, isTrue);
      expect(settings.silenceTimeoutSeconds, equals(12));
    });

    test('关闭开始词检测序列化与反序列化测试', () {
      final s = AppSettings(enableStartWordDetection: false);
      expect(s.enableStartWordDetection, isFalse);

      final map = s.toMap();
      expect(map['enableStartWordDetection'], isFalse);

      final restored = AppSettings.fromMap(map);
      expect(restored.enableStartWordDetection, isFalse);
    });

    test('静音超时保护范围严格限制在 1-30 秒', () {
      final sMin = AppSettings(silenceTimeoutSeconds: 1);
      expect(sMin.silenceTimeoutSeconds, equals(1));

      final fromZero = AppSettings.fromMap({'silenceTimeoutSeconds': 0});
      expect(fromZero.silenceTimeoutSeconds, equals(1));

      final fromMax = AppSettings.fromMap({'silenceTimeoutSeconds': 30});
      expect(fromMax.silenceTimeoutSeconds, equals(30));

      final fromOverflow = AppSettings.fromMap({'silenceTimeoutSeconds': 45});
      expect(fromOverflow.silenceTimeoutSeconds, equals(30));
    });
  });

  group('声纹录入期间语音识别隔离防误触发测试', () {
    test('声纹录入状态下，实时语音识别文本应被坚决丢弃，不唤醒助手且不向大模型发请求', () async {
      final settings = AppSettings(
        enableSpeakerVerification: true,
        speakerSimilarityThreshold: 0.55,
      );
      final controller = AssistantController(settings: settings);

      expect(controller.status, equals(AssistantStatus.idle));
      expect(controller.isEnrollingSpeaker, isFalse);

      // 启动声纹录入隔离状态
      controller.voiceService.isEnrollingSpeaker = true;
      expect(controller.isEnrollingSpeaker, isTrue);

      // 模拟声纹录制期间收到识别文本（用户朗读样例文本“小曼小曼，今天天气怎么样”）
      await controller.simulateUserInput('小曼小曼，今天天气怎么样');

      // 助手必须严格保持待机状态，识别字稿为空，消息列表为空，不触发大模型请求
      expect(controller.status, equals(AssistantStatus.idle));
      expect(controller.messages, isEmpty);
      expect(controller.displayTranscript, isEmpty);
      expect(controller.lastRecognizedSpeech, isEmpty);

      controller.dispose();
    });
  });
}
