/// 主人声纹子管线（Speaker Pipeline）。
///
/// 职责：声纹校验、样本录入、相似度诊断三件事的完整实现，从
/// `VoicePipelineCoordinator` 中按职责内聚拆出。所有依赖协作者通过构造函数注入
/// （`settings` / 声纹引擎 / 语音监听均为访问器，因为协调器会在
/// `initServices()` 与 `applyAudioConfig()` 中热替换这些实例），不持有协调器引用。
///
/// 协调器对外暴露的同名方法只做一行委托，公开契约保持不变。
library;

import '../../models/app_settings.dart';
import '../../platform/foundation_bridge.dart';
import '../../ports/speaker_verification_port.dart';
import '../../ports/voice_listening_port.dart';

/// 声纹校验、录入与相似度诊断的独立子管线。
class SpeakerPipeline {
  SpeakerPipeline({
    required AppSettings Function() settingsOf,
    required SpeakerVerifierPort Function() verifierOf,
    required VoiceListeningPort Function() listeningOf,
    required void Function() onNotify,
  })  : _settingsOf = settingsOf,
        _verifierOf = verifierOf,
        _listeningOf = listeningOf,
        _onNotify = onNotify;

  final AppSettings Function() _settingsOf;
  final SpeakerVerifierPort Function() _verifierOf;
  final VoiceListeningPort Function() _listeningOf;
  final void Function() _onNotify;

  /// 是否正在录制声纹样本（录制中需丢弃常规 ASR 流与待机唤醒）。
  bool isEnrolling = false;

  AppSettings get _settings => _settingsOf();
  SpeakerVerifierPort get _verifier => _verifierOf();
  VoiceListeningPort get _listening => _listeningOf();

  /// 校验当前输入音频是否来自注册的主人声纹
  bool verifyOwnerSpeaker({
    String contextHint = '唤醒',
    void Function(String reason)? onRejected,
  }) {
    if (!_settings.enableSpeakerVerification) return true;
    if (!_verifier.hasEnrolledOwner) return true;

    final audio = _listening.lastRecognizedAudio ??
        _listening.getRecentAudio(seconds: 2.5);
    if (audio.isEmpty) return true;

    final isShortContext = contextHint.contains('唤醒') ||
        contextHint.contains('打断') ||
        contextHint.contains('重置');
    final effectiveThreshold = isShortContext
        ? (_settings.speakerSimilarityThreshold - 0.08).clamp(0.40, 0.65)
        : _settings.speakerSimilarityThreshold;

    final result = _verifier.verifyOwner(
      audio,
      customThreshold: effectiveThreshold,
    );
    if (result.bypassed || result.isMatched) {
      debugPrint(
        '[VoicePipelineCoordinator] 主人声纹校验通过 ($contextHint): '
        '${(result.similarity * 100).toStringAsFixed(1)}% (耗时 ${result.durationMs}ms)',
      );
      return true;
    }

    debugPrint(
      '[VoicePipelineCoordinator] 主人声纹校验拦截 ($contextHint): '
      '${(result.similarity * 100).toStringAsFixed(1)}% < ${(effectiveThreshold * 100).toStringAsFixed(1)}% (耗时 ${result.durationMs}ms)',
    );
    final reason =
        '检测到$contextHint词，但声纹不匹配 (${(result.similarity * 100).toStringAsFixed(1)}% < ${(effectiveThreshold * 100).toInt()}%)，已忽略';
    onRejected?.call(reason);
    return false;
  }

  /// 校验指定原始 PCM 字节数据是否匹配主人声纹
  Future<SpeakerVerificationResult> verifyOwnerSpeakerData(
    List<int> pcmData, {
    required int sampleRate,
  }) async {
    if (pcmData.isEmpty) {
      return SpeakerVerificationResult.bypassed(reason: 'PCM 数据为空');
    }
    final numSamples = pcmData.length ~/ 2;
    final floatList = Float32List(numSamples);
    final byteData = ByteData.sublistView(Uint8List.fromList(pcmData));
    for (int i = 0; i < numSamples; i++) {
      floatList[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    final res = _verifier.verifyOwner(
      floatList,
      sampleRate: sampleRate,
    );
    return SpeakerVerificationResult(
      isMatched: res.isMatched,
      similarity: res.similarity,
      hasEnrolledOwner: res.hasEnrolledOwner,
      bypassed: res.bypassed,
      reason: res.reason,
      durationMs: res.durationMs,
    );
  }

  /// 获取最近音频切片 (Float32List)
  Float32List? getRecentAudioSnippet({double seconds = 3.0}) {
    return _listening.lastRecognizedAudio ??
        _listening.getRecentAudio(seconds: seconds);
  }

  /// 使用提供的样本录入主人声纹
  Future<bool> enrollOwnerSpeaker({Float32List? samples}) async {
    final audio = samples ??
        _listening.lastRecognizedAudio ??
        _listening.getRecentAudio(seconds: 3.0);
    final minEnrollSamples = (0.75 * 16000).round();
    if (audio.isEmpty || audio.length < minEnrollSamples) {
      debugPrint(
        '[VoicePipelineCoordinator] 录制声纹失败：有效音频过短（需 >= 0.75s）',
      );
      return false;
    }

    await _verifier.saveDebugWave(audio);
    final success = await _verifier.enrollOwner(audio);
    if (success) {
      _listening.flushBuffers(cooldownMs: 500);
      _listening.resetStream();
      _onNotify();
    }
    return success;
  }

  /// 录制并录入主人声纹
  Future<bool> recordAndEnrollOwnerSpeaker({double seconds = 3.5}) async {
    final wasListening = _listening.isListening;
    isEnrolling = true;
    _listening.isEnrollingSpeaker = true;
    _onNotify();

    try {
      if (!wasListening) {
        await _listening.startContinuousListening();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final recordDurationMs = (seconds * 1000).round();
      final preClickAudio = _listening.getRecentAudio(seconds: 1.5);
      _listening.clearRecentAudio();
      await Future<void>.delayed(Duration(milliseconds: recordDurationMs));

      var totalWindowSec = seconds;
      var audio = _listening.getRecentAudio(seconds: totalWindowSec);
      if (audio.isNotEmpty) {
        for (int extra = 0; extra < 4; extra++) {
          final trimmed = _verifier.trimAudioToSpeech(
            audio,
            minSeconds: 0.75,
          );
          if (trimmed.length >= (16000 * 1.2).round()) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
          totalWindowSec += 0.25;
          audio = _listening.getRecentAudio(seconds: totalWindowSec);
        }
      }
      if (preClickAudio.isNotEmpty &&
          _verifier
                  .trimAudioToSpeech(
                    audio,
                    minSeconds: 0.75,
                  )
                  .length <
              (0.75 * 16000).round()) {
        final combined = Float32List(preClickAudio.length + audio.length);
        combined.setRange(0, preClickAudio.length, preClickAudio);
        combined.setRange(preClickAudio.length, combined.length, audio);
        if (_verifier
                .trimAudioToSpeech(
                  combined,
                  minSeconds: 0.75,
                )
                .length >=
            (0.75 * 16000).round()) {
          audio = combined;
        }
      }
      final success = await enrollOwnerSpeaker(samples: audio);
      return success;
    } finally {
      _listening.flushBuffers(cooldownMs: 600);
      _listening.resetStream();
      isEnrolling = false;
      _listening.isEnrollingSpeaker = false;

      if (!wasListening) {
        await _listening.stopContinuousListening();
      }
      _onNotify();
    }
  }

  /// 清空已录入的主人声纹
  Future<void> clearOwnerSpeaker() async {
    await _verifier.clearOwnerEmbeddings();
    _onNotify();
  }

  /// 录制并测试与主人声纹的相似度
  Future<Map<String, dynamic>> recordAndTestOwnerSpeakerSimilarity({
    double seconds = 3.0,
  }) async {
    final wasListening = _listening.isListening;
    isEnrolling = true;
    _listening.isEnrollingSpeaker = true;
    _onNotify();

    try {
      if (!wasListening) {
        await _listening.startContinuousListening();
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }

      final recordDurationMs = (seconds * 1000).round();
      final preClickAudio = _listening.getRecentAudio(seconds: 1.5);
      _listening.clearRecentAudio();
      await Future<void>.delayed(Duration(milliseconds: recordDurationMs));

      var totalWindowSec = seconds;
      var audio = _listening.getRecentAudio(seconds: totalWindowSec);
      final minSamples = _verifier.minAudioSamples;
      final minSec = _verifier.minSpeechSeconds;
      if (audio.isNotEmpty) {
        for (int extra = 0; extra < 4; extra++) {
          final trimmed = _verifier.trimAudioToSpeech(
            audio,
            minSeconds: minSec,
          );
          if (trimmed.length >= (16000 * 1.0).round()) break;
          await Future<void>.delayed(const Duration(milliseconds: 250));
          totalWindowSec += 0.25;
          audio = _listening.getRecentAudio(seconds: totalWindowSec);
        }
      }
      if (preClickAudio.isNotEmpty &&
          _verifier
                  .trimAudioToSpeech(
                    audio,
                    minSeconds: minSec,
                  )
                  .length <
              minSamples) {
        final combined = Float32List(preClickAudio.length + audio.length);
        combined.setRange(0, preClickAudio.length, preClickAudio);
        combined.setRange(preClickAudio.length, combined.length, audio);
        if (_verifier
                .trimAudioToSpeech(
                  combined,
                  minSeconds: minSec,
                )
                .length >=
            minSamples) {
          audio = combined;
        }
      }
      return await testOwnerSpeakerSimilarity(samples: audio);
    } finally {
      _listening.flushBuffers(cooldownMs: 600);
      _listening.resetStream();
      isEnrolling = false;
      _listening.isEnrollingSpeaker = false;

      if (!wasListening) {
        await _listening.stopContinuousListening();
      }
      _onNotify();
    }
  }

  /// 测试样本与主人声纹的余弦相似度
  Future<Map<String, dynamic>> testOwnerSpeakerSimilarity({
    Float32List? samples,
  }) async {
    if (!_verifier.isReady) {
      final ok = await _verifier.initialize();
      if (!ok) {
        return {
          'error': '声纹模型加载失败，请检查模型文件',
          'passed': false,
          'similarity': 0.0,
        };
      }
    }
    if (!_verifier.hasEnrolledOwner || _verifier.enrolledSampleCount == 0) {
      return {
        'error': '尚未录入主人声纹（当前模型需要重新录制），请先点击录制样本',
        'passed': false,
        'similarity': 0.0,
      };
    }

    final audio = samples ??
        _listening.lastRecognizedAudio ??
        _listening.getRecentAudio(seconds: 3.0);
    final minSamples = _verifier.minAudioSamples;
    final minSec = _verifier.minSpeechSeconds;
    if (audio.isEmpty || audio.length < minSamples) {
      return {
        'error': '未捕获到足够时长的语音（请先对着麦克风说话 >= ${minSec.toStringAsFixed(2)}秒）',
        'passed': false,
        'similarity': 0.0,
      };
    }

    final debugPath = await _verifier.saveDebugWave(audio);

    final analysis = _verifier.analyzeOwner(audio);
    if (analysis.hasError) {
      return {
        'error': analysis.error,
        'passed': false,
        'similarity': 0.0,
        'durationMs': analysis.durationMs,
        'text': analysis.error,
        if (debugPath != null) 'debugWavePath': debugPath,
      };
    }

    final threshold = _settings.speakerSimilarityThreshold;
    final isPass = analysis.similarity >= threshold;
    final simPct = (analysis.similarity * 100).toStringAsFixed(1);
    final threshPct = (threshold * 100).toStringAsFixed(0);
    final samplePcts = analysis.sampleSimilarities
        .map((s) => double.parse((s * 100).toStringAsFixed(1)))
        .toList(growable: false);
    final text = '与主人声纹匹配度: $simPct% '
        '(${isPass ? "✅ 判定为主人" : "❌ 未达到阈值 $threshPct%"})';

    debugPrint(
      '[VoicePipelineCoordinator] 声纹测试: 综合=$simPct% '
      '质心=${(analysis.centroidSimilarity * 100).toStringAsFixed(1)}% '
      '单样本最高=${(analysis.maxSampleSimilarity * 100).toStringAsFixed(1)}% '
      '均值=${(analysis.meanSampleSimilarity * 100).toStringAsFixed(1)}% '
      '有效语音=${analysis.speechSeconds.toStringAsFixed(2)}s '
      '阈值=$threshPct% 样本=${samplePcts.join("/")}',
    );

    return {
      'similarity': analysis.similarity,
      'similarityPercent': double.parse(simPct),
      'threshold': threshold,
      'passed': isPass,
      'durationMs': analysis.durationMs,
      'speechSeconds': analysis.speechSeconds,
      'centroidSimilarity': analysis.centroidSimilarity,
      'maxSampleSimilarity': analysis.maxSampleSimilarity,
      'meanSampleSimilarity': analysis.meanSampleSimilarity,
      'sampleSimilarities': analysis.sampleSimilarities,
      'samplePercents': samplePcts,
      'enrolledCount': _verifier.enrolledSampleCount,
      'debugAudioPath': debugPath,
      'text': text,
    };
  }
}
