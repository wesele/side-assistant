import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;
import 'package:side_assistant/core/models/app_settings.dart';
import 'package:side_assistant/services/speech/asr_service.dart';
import 'package:side_assistant/services/speech/speaker_verification_service.dart';
import 'package:side_assistant/services/speech/target_speaker_extraction_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
    ensureSherpaBindings();
  });

  const modelPath =
      'assets/models/speaker/3dspeaker_speech_campplus_sv_zh-cn_16k-common.onnx';
  const zhWavPath = 'assets/models/sense-voice/test_wavs/zh.wav';
  const enWavPath = 'assets/models/sense-voice/test_wavs/en.wav';

  group('AppSettings - 目标说话人语音抽取 (TSE) 配置测试', () {
    test('默认配置应为关闭，抑制强度 20dB，相似度阈值 0.50', () {
      final settings = AppSettings();
      expect(settings.enableTargetSpeakerExtraction, isFalse);
      expect(settings.tseAttenuationDb, equals(20.0));
      expect(settings.tseSimilarityThreshold, equals(0.50));
    });

    test('toMap 与 fromMap 应正确序列化与反序列化 TSE 配置', () {
      final original = AppSettings(
        enableSpeakerVerification: true,
        enableTargetSpeakerExtraction: true,
        tseAttenuationDb: 24.0,
        tseSimilarityThreshold: 0.58,
      );

      final map = original.toMap();
      final restored = AppSettings.fromMap(map);

      expect(restored.enableTargetSpeakerExtraction, isTrue);
      expect(restored.tseAttenuationDb, closeTo(24.0, 0.01));
      expect(restored.tseSimilarityThreshold, closeTo(0.58, 0.01));
    });
  });

  group('TargetSpeakerExtractionService - 目标说话人抽取测试', () {
    test('开关关闭或未录入声纹时应直接原样透传 (passthrough)', () {
      final settings = AppSettings(
        enableTargetSpeakerExtraction: false,
        ownerSpeakerEmbeddings: [],
      );
      final spkService = SpeakerVerificationService(settings: settings);
      final tseService = TargetSpeakerExtractionService(
        settings: settings,
        speakerVerificationService: spkService,
      );

      final fakeAudio = Float32List.fromList([0.1, -0.2, 0.3, -0.4]);
      final result = tseService.extractTargetSpeakerWithMetrics(fakeAudio);

      expect(result.isExtracted, isFalse);
      expect(result.extractedSamples, equals(fakeAudio));
    });

    test('录入主人声纹后，对主人纯净音频完整保留，对异说话人/干扰音频深度衰减', () async {
      expect(File(modelPath).existsSync(), isTrue);

      final settings = AppSettings(
        enableSpeakerVerification: true,
        enableTargetSpeakerExtraction: true,
        tseAttenuationDb: 20.0,
        tseSimilarityThreshold: 0.50,
        speakerModelPath: modelPath,
      );
      final spkService = SpeakerVerificationService(settings: settings);
      await spkService.initialize();

      final tseService = TargetSpeakerExtractionService(
        settings: settings,
        speakerVerificationService: spkService,
      );

      final waveZh = sherpa_onnx.readWave(zhWavPath);
      final mid = waveZh.samples.length ~/ 2;
      final zhPart1 = waveZh.samples.sublist(0, mid);
      final zhPart2 = waveZh.samples.sublist(mid);

      // 1. 录入 zhPart1 为主人声纹
      final enrolled = await spkService.enrollOwner(zhPart1);
      expect(enrolled, isTrue);
      expect(spkService.hasEnrolledOwner, isTrue);

      // 2. 对主人自身的后半段语音 (zhPart2) 进行抽取测试
      final resultZh = tseService.extractTargetSpeakerWithMetrics(zhPart2);
      expect(resultZh.isExtracted, isTrue);
      expect(resultZh.averageTargetConfidence, greaterThan(0.50));
      expect(resultZh.suppressedRatio, lessThan(0.20)); // 主人声音基本无抑制
      expect(resultZh.extractedSamples.length, equals(zhPart2.length));

      // 计算能量保留比 (RMS)
      double rms(Float32List s) =>
          math.sqrt(s.fold(0.0, (acc, e) => acc + e * e) / s.length);

      final inRmsZh = rms(zhPart2);
      final outRmsZh = rms(resultZh.extractedSamples);
      expect(outRmsZh / inRmsZh, greaterThan(0.70), reason: '主人声音应高保真保留');

      // 3. 对完全不同的异说话人/电视/路人语音 (en.wav) 进行抽取测试
      final waveEn = sherpa_onnx.readWave(enWavPath);
      final resultEn =
          tseService.extractTargetSpeakerWithMetrics(waveEn.samples);
      expect(resultEn.isExtracted, isTrue);
      expect(resultEn.averageTargetConfidence, lessThan(0.35));
      expect(resultEn.suppressedRatio, greaterThan(0.85)); // 几乎全程被判定为干扰人声

      final inRmsEn = rms(waveEn.samples);
      final outRmsEn = rms(resultEn.extractedSamples);
      // 20dB 衰减对应振幅为原幅度的 10% (0.10) 左右
      expect(outRmsEn / inRmsEn, lessThan(0.25),
          reason: '电视/路人/非目标人声应被衰减至 20% 以下');

      spkService.dispose();
    });

    test('混合音频测试：拼接主人语音与路人/电视语音，主人段保留、非主人段消除', () async {
      final settings = AppSettings(
        enableSpeakerVerification: true,
        enableTargetSpeakerExtraction: true,
        tseAttenuationDb: 20.0,
        tseSimilarityThreshold: 0.50,
        speakerModelPath: modelPath,
      );
      final spkService = SpeakerVerificationService(settings: settings);
      await spkService.initialize();

      final tseService = TargetSpeakerExtractionService(
        settings: settings,
        speakerVerificationService: spkService,
      );

      final waveZh = sherpa_onnx.readWave(zhWavPath);
      final waveEn = sherpa_onnx.readWave(enWavPath);

      // 录入 zh 全程声纹
      await spkService.enrollOwner(waveZh.samples);

      // 构造合成混合音频：前半段是主人 (zh)，后半段是干扰说话人 (en)
      final mixed = Float32List(waveZh.samples.length + waveEn.samples.length);
      mixed.setRange(0, waveZh.samples.length, waveZh.samples);
      mixed.setRange(waveZh.samples.length, mixed.length, waveEn.samples);

      final result = tseService.extractTargetSpeakerWithMetrics(mixed);
      expect(result.isExtracted, isTrue);
      expect(result.extractedSamples.length, equals(mixed.length));

      // 检验前半段（主人段）与后半段（干扰段）的能量衰减对比
      double rms(Float32List s, int start, int end) {
        final len = end - start;
        double sum = 0.0;
        for (int i = start; i < end; i++) {
          sum += s[i] * s[i];
        }
        return math.sqrt(sum / len);
      }

      final zhLen = waveZh.samples.length;
      final outZhRms = rms(result.extractedSamples, 0, zhLen);
      final inZhRms = rms(mixed, 0, zhLen);

      final outEnRms = rms(result.extractedSamples, zhLen, mixed.length);
      final inEnRms = rms(mixed, zhLen, mixed.length);

      // 前半段主人语音高保留率
      expect(outZhRms / inZhRms, greaterThan(0.70));

      // 后半段路人/电视语音被深度衰减
      expect(outEnRms / inEnRms, lessThan(0.30));

      spkService.dispose();
    });
  });
}
