import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../../../core/platform/foundation_bridge.dart';

import '../speaker_audio_processor.dart';

/// Gemini Live 实时音频编码工具（纯计算、无状态）。
///
/// 职责边界：只负责 Float32 采样 → 16bit 小端 PCM 的转换、重采样，以及
/// `realtimeInput.audio` 帧的组装；不持有 socket、不涉及发送节奏。
class GeminiLivePcm {
  const GeminiLivePcm._();

  /// 每帧 100ms @ 16kHz PCM16。
  static const int bytesPerChunk = 1600 * 2;

  /// 组装一条 `realtimeInput.audio` 消息（[offset, end) 为 PCM 字节区间）。
  static String encodeChunkMessage(Uint8List pcm, int offset, int end) {
    return jsonEncode({
      'realtimeInput': {
        'audio': {
          'mimeType': 'audio/pcm;rate=16000',
          'data': base64Encode(Uint8List.sublistView(pcm, offset, end)),
        },
      },
    });
  }

  /// Float32 [-1, 1] 采样 → 16bit 小端 PCM 字节。
  static Uint8List float32ToPcm16(Float32List samples) {
    final bytes = Uint8List(samples.length * 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0).toDouble();
      data.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
    }
    return bytes;
  }

  /// 线性插值重采样（ASR 只接受 16k）。
  static Float32List resample(
    Float32List input, {
    required int fromRate,
    required int toRate,
  }) {
    if (input.isEmpty || fromRate == toRate || fromRate <= 0 || toRate <= 0) {
      return input;
    }
    final outLength = (input.length * toRate / fromRate).round();
    final output = Float32List(outLength);
    final ratio = fromRate / toRate;
    for (var i = 0; i < outLength; i++) {
      final position = i * ratio;
      final index = position.floor();
      final next = math.min(index + 1, input.length - 1);
      final fraction = position - index;
      output[i] = input[index] * (1 - fraction) + input[next] * fraction;
    }
    return output;
  }

  /// 播报期本地真人插话判定：最小 RMS / 峰值 / 连续有声样本数（16kHz，2400≈150ms）。
  static const double bargeInMinRms = 0.004;
  static const double bargeInMinPeak = 0.0075;
  static const int bargeInVoicedSamplesNeeded = 2400;

  /// 移动端外放播报期强声学回声消除与防自激插话判定门限（300ms @ 16kHz）。
  static const double mobileBargeInMinRms = 0.055;
  static const double mobileBargeInMinPeak = 0.13;
  static const int mobileBargeInVoicedSamplesNeeded = 4800;

  static double _speechRmsEnv = 0.003;
  static double _currentGain = 1.0;
  static int _hangoverSamples = 0;

  static bool _bargeInActive = false;
  static int _bargeInVoicedSamples = 0;
  static final List<Float32List> _bargeInPreRoll = <Float32List>[];
  static Float32List? _idlePreRollFrame;

  static double _outputRmsEnv = 0.0;
  static DateTime _playbackStartedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static bool? debugForceMobileEchoProfile;

  static bool get isMobileEchoProfile =>
      debugForceMobileEchoProfile ?? (Platform.isAndroid || Platform.isIOS);

  static double get currentOutputRmsEnvelope => _outputRmsEnv;

  /// 当前是否处于活跃人声包络（含 600ms 尾音保持窗）内
  static bool get isInSpeechHangover => _hangoverSamples > 0;

  /// 当前是否处于打断已触发并保持状态
  static bool get isBargeInActive => _bargeInActive;

  /// 喂入下行扬声器外放 PCM16 音频，用于动态计算回声包络参考电平
  static void feedOutputPcm16(Uint8List pcmBytes) {
    if (pcmBytes.length < 2) return;
    final sampleCount = pcmBytes.length ~/ 2;
    if (sampleCount == 0) return;

    final data = ByteData.sublistView(pcmBytes);
    double sumSq = 0.0;
    for (var i = 0; i < sampleCount; i++) {
      final sample = data.getInt16(i * 2, Endian.little) / 32768.0;
      sumSq += sample * sample;
    }
    final chunkRms = math.sqrt(sumSq / sampleCount);

    if (chunkRms > _outputRmsEnv) {
      _outputRmsEnv = 0.65 * chunkRms + 0.35 * _outputRmsEnv;
    } else {
      _outputRmsEnv = 0.90 * _outputRmsEnv + 0.10 * chunkRms;
    }
  }

  /// 重置流式增益包络状态（新会话建立、断开或单测隔离时调用）
  static void resetConditioner() {
    _speechRmsEnv = 0.003;
    _currentGain = 1.0;
    _hangoverSamples = 0;
    _bargeInActive = false;
    _bargeInVoicedSamples = 0;
    _bargeInPreRoll.clear();
    _idlePreRollFrame = null;
    _outputRmsEnv = 0.0;
    _playbackStartedAt = DateTime.fromMillisecondsSinceEpoch(0);
    debugForceMobileEchoProfile = null;
  }

  /// 当检测到新一轮回复音频开始播放时调用，重置增益包络并开启回声屏蔽闸门
  static void notifyPlaybackStarted() {
    _speechRmsEnv = 0.003;
    _currentGain = 1.0;
    _hangoverSamples = 0;
    _bargeInActive = false;
    _bargeInVoicedSamples = 0;
    _bargeInPreRoll.clear();
    _idlePreRollFrame = null;
    _playbackStartedAt = DateTime.now();
  }

  /// 对实时上推给 Gemini Live 的音频帧做自适应动态增益规整（AGC）：
  /// 解决蓝牙 HFP/SCO (CVSD/mSBC) 或低增益麦克风有效人声仅 -55~-35 dBFS
  /// 导致云端服务端 VAD 无法触发的问题；对正常响度麦克风保持 1.0x 原样透传。
  static Float32List conditionLiveSamples(
    Float32List samples, {
    bool isPlayingOutput = false,
  }) {
    if (samples.isEmpty) return samples;
    if (samples.length > 640) {
      Float32List? out;
      for (var offset = 0; offset < samples.length; offset += 480) {
        final end = math.min(offset + 480, samples.length);
        final slice = Float32List.sublistView(samples, offset, end);
        final condSlice =
            conditionLiveSamples(slice, isPlayingOutput: isPlayingOutput);
        if (!identical(condSlice, slice)) {
          out ??= Float32List.fromList(samples);
          out.setRange(offset, end, condSlice);
        }
      }
      return out ?? samples;
    }

    double maxPeak = 0.0;
    double sumSq = 0.0;
    for (var i = 0; i < samples.length; i++) {
      final absVal = samples[i].abs();
      if (absVal > maxPeak) maxPeak = absVal;
      sumSq += absVal * absVal;
    }
    if (maxPeak < 1.5e-4 || (sumSq / samples.length) < 6.4e-9) {
      _hangoverSamples = math.max(0, _hangoverSamples - samples.length);
      if (_hangoverSamples == 0) _currentGain = 1.0;
      return samples;
    }
    final rms = math.sqrt(sumSq / samples.length);
    if (rms < 8.0e-5) {
      _hangoverSamples = math.max(0, _hangoverSamples - samples.length);
      if (_hangoverSamples == 0) _currentGain = 1.0;
      return samples;
    }

    final isSpeechFrame = isPlayingOutput
        ? (rms >= 0.00125 || maxPeak >= 0.0052)
        : (rms >= 0.00065 || maxPeak >= 0.0032);

    const targetRms = 0.085;
    const maxGain = 32.0;
    const hangoverHoldSamples = 9600; // 600ms @ 16kHz

    if (isSpeechFrame) {
      _hangoverSamples = hangoverHoldSamples;
      if (rms >= targetRms) {
        _currentGain = 1.0;
        return samples;
      }
      final clampedRms = rms.clamp(0.0012, targetRms);
      if (_currentGain <= 1.5) {
        _speechRmsEnv = clampedRms;
      } else {
        _speechRmsEnv =
            (_speechRmsEnv * 0.72 + clampedRms * 0.28).clamp(0.0012, targetRms);
      }
    } else if (_hangoverSamples > 0) {
      _hangoverSamples = math.max(0, _hangoverSamples - samples.length);
    } else {
      _currentGain = 1.0;
      return samples;
    }

    final refRms =
        isSpeechFrame ? math.max(rms * 0.5, _speechRmsEnv) : _speechRmsEnv;
    final effectiveMaxGain =
        (isPlayingOutput && isMobileEchoProfile) ? 3.0 : maxGain;
    final desiredGain = (targetRms / refRms).clamp(1.0, effectiveMaxGain);
    _currentGain = _currentGain <= 1.5
        ? desiredGain
        : (_currentGain * 0.6 + desiredGain * 0.4);
    var scale = _currentGain;
    if (maxPeak * scale > 0.92) {
      scale = 0.92 / maxPeak;
    }
    if ((scale - 1.0).abs() < 0.05) return samples;

    final out = Float32List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      out[i] = (samples[i] * scale).clamp(-1.0, 1.0).toDouble();
    }
    return out;
  }

  /// 综合上行音频帧流水线：
  /// 1. 播放回声区（isInPlaybackEchoZone）且打断未激活时，对外下发纯数字静音（0.0 字节），
  ///    内部 300ms 环形缓存预卷帧，并通过基频声带振动漏桶积分器判定真实用户开口；
  /// 2. 一旦达到 150ms 连续人声打断判定门限，立即触发本地快速打断回调，并回放补传
  ///    过去 300ms 经 AGC 恢复的完整辅音/元音音频；
  /// 3. 空闲待机时，提供 1 帧轻辅音预卷回溯与 AGC 增益规整。
  static Uint8List processUplinkSamples(
    Float32List samples, {
    required bool isInPlaybackEchoZone,
    required void Function() onLocalBargeInTriggered,
  }) {
    if (samples.isEmpty) return Uint8List(0);
    final outBytes = BytesBuilder(copy: false);

    for (var offset = 0; offset < samples.length; offset += 480) {
      final end = math.min(offset + 480, samples.length);
      final subFrame = Float32List.sublistView(samples, offset, end);

      if (isInPlaybackEchoZone && !_bargeInActive) {
        _outputRmsEnv *= 0.96;
        if (_outputRmsEnv < 1e-4) {
          _outputRmsEnv = 0.0;
        }

        _hangoverSamples = 0;
        _currentGain = 1.0;
        _idlePreRollFrame = null;
        _bargeInPreRoll.add(Float32List.fromList(subFrame));
        if (_bargeInPreRoll.length > 10) {
          _bargeInPreRoll.removeAt(0);
        }

        double maxPeak = 0.0;
        double sumSq = 0.0;
        for (var i = 0; i < subFrame.length; i++) {
          final absVal = subFrame[i].abs();
          if (absVal > maxPeak) maxPeak = absVal;
          sumSq += absVal * absVal;
        }
        final rms = math.sqrt(sumSq / subFrame.length);

        final voicing = (subFrame.length >= 256 && rms >= 0.00125)
            ? SpeakerAudioProcessor.framePitchVoicing(
                subFrame,
                0,
                subFrame.length,
                16000,
              )
            : 0.0;

        final mobileProfile = isMobileEchoProfile;
        final double minRms;
        final double minPeak;
        final int samplesNeeded;

        if (mobileProfile) {
          final isAecSettling =
              DateTime.now().difference(_playbackStartedAt).inMilliseconds <
                  450;
          if (isAecSettling) {
            minRms = math.max(0.11, _outputRmsEnv * 1.8);
            minPeak = math.max(0.25, _outputRmsEnv * 3.0);
          } else {
            minRms = math.max(mobileBargeInMinRms, _outputRmsEnv * 1.35);
            minPeak = math.max(mobileBargeInMinPeak, _outputRmsEnv * 2.4);
          }
          samplesNeeded = mobileBargeInVoicedSamplesNeeded;
        } else {
          minRms = math.max(bargeInMinRms, _outputRmsEnv * 0.35);
          minPeak = math.max(bargeInMinPeak, _outputRmsEnv * 0.70);
          samplesNeeded = bargeInVoicedSamplesNeeded;
        }

        // 外放蓝牙音箱（麦克风与扬声器同机）实测回声 RMS 峰值约 0.003，
        // 移动端扬声器直对外放回声可达 0.04~0.08，结合下行包络自适应动态门限判定。
        final isUserVoiced = (rms >= minRms &&
                maxPeak >= minPeak &&
                voicing >= 0.5) ||
            (rms >= minRms * 1.8 && maxPeak >= minPeak * 1.7 && voicing >= 0.4);

        if (isUserVoiced) {
          _bargeInVoicedSamples += subFrame.length;
        } else if (mobileProfile) {
          _bargeInVoicedSamples =
              math.max(0, _bargeInVoicedSamples - subFrame.length);
        } else if (rms < 0.0005) {
          _bargeInVoicedSamples =
              math.max(0, _bargeInVoicedSamples - (subFrame.length ~/ 2));
        } else {
          _bargeInVoicedSamples =
              math.max(0, _bargeInVoicedSamples - (subFrame.length ~/ 4));
        }

        if (_bargeInVoicedSamples >= samplesNeeded) {
          debugPrint('[GeminiLivePcm] 本地打断触发: rms=${rms.toStringAsFixed(4)}, '
              'peak=${maxPeak.toStringAsFixed(4)}, voicing=${voicing.toStringAsFixed(2)}');
          _bargeInActive = true;
          _bargeInVoicedSamples = 0;
          onLocalBargeInTriggered();
          final framesToFlush = mobileProfile
              ? _bargeInPreRoll.skip(math.max(0, _bargeInPreRoll.length - 3))
              : _bargeInPreRoll;
          for (final preFrame in framesToFlush) {
            final cond = conditionLiveSamples(preFrame, isPlayingOutput: false);
            outBytes.add(float32ToPcm16(cond));
          }
          _bargeInPreRoll.clear();
        } else {
          outBytes.add(Uint8List(subFrame.length * 2));
        }
      } else {
        if (!isInPlaybackEchoZone) {
          _outputRmsEnv = 0.0;
          if (_bargeInActive) {
            _bargeInActive = false;
            _bargeInVoicedSamples = 0;
            _bargeInPreRoll.clear();
          }
        }

        final wasInSpeech = isInSpeechHangover;
        final conditioned =
            conditionLiveSamples(subFrame, isPlayingOutput: false);
        final nowInSpeech = isInSpeechHangover;

        if (!wasInSpeech && !nowInSpeech) {
          final prev = _idlePreRollFrame;
          _idlePreRollFrame = Float32List.fromList(subFrame);
          if (prev != null) {
            outBytes.add(float32ToPcm16(prev));
          }
        } else {
          if (!wasInSpeech && nowInSpeech && _idlePreRollFrame != null) {
            final retro = conditionLiveSamples(_idlePreRollFrame!,
                isPlayingOutput: false);
            _idlePreRollFrame = null;
            outBytes.add(float32ToPcm16(retro));
          } else if (_idlePreRollFrame != null) {
            outBytes.add(float32ToPcm16(_idlePreRollFrame!));
            _idlePreRollFrame = null;
          }
          outBytes.add(float32ToPcm16(conditioned));
        }
      }
    }

    return outBytes.takeBytes();
  }
}
