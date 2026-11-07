import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'linux/linux_audio_playback_service.dart';

/// 将 16-bit 小端 PCM 字节按音量百分比（0~150）做软件增益缩放。
Uint8List scalePcm16Volume(Uint8List pcmBytes, int volumePercent) {
  final clampedVol = volumePercent.clamp(0, 150);
  if (clampedVol == 100 || pcmBytes.length < 2) return pcmBytes;
  if (clampedVol == 0) return Uint8List(pcmBytes.length);

  final sampleCount = pcmBytes.length ~/ 2;
  final out = Uint8List(sampleCount * 2);
  final inData = ByteData.sublistView(pcmBytes, 0, sampleCount * 2);
  final outData = ByteData.sublistView(out);
  final factor = clampedVol / 100.0;

  for (var i = 0; i < sampleCount; i++) {
    final sample = inData.getInt16(i * 2, Endian.little);
    final scaled = (sample * factor).round().clamp(-32768, 32767);
    outData.setInt16(i * 2, scaled, Endian.little);
  }
  return out;
}

/// 纯 Dart 边缘端（Linux 无头服务 / 单元测试）24kHz PCM 流式播放器
class PlatformPcmStreamPlayer {
  Process? _linuxProcess;
  int _activeSampleRate = 0;
  String _activeDeviceId = '';
  DateTime _playingUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _disposed = false;

  bool get isPlaying => DateTime.now().isBefore(_playingUntil);

  void _extendPlaybackHorizon(int byteCount, int sampleRate,
      {int extraPadMs = 0}) {
    if (byteCount <= 0 || sampleRate <= 0) return;
    final durationMs =
        ((byteCount / 2) * 1000 / sampleRate).ceil() + extraPadMs;
    final now = DateTime.now();
    final base = _playingUntil.isAfter(now) ? _playingUntil : now;
    _playingUntil = base.add(Duration(milliseconds: durationMs));
  }

  Future<void> feedPcm(
    Uint8List pcmBytes, {
    int sampleRate = 24000,
    int volumePercent = 100,
    String outputDeviceId = '',
  }) async {
    if (_disposed || pcmBytes.isEmpty) return;
    final isColdStart = Platform.isLinux &&
        (_linuxProcess == null ||
            _activeSampleRate != sampleRate ||
            _activeDeviceId != outputDeviceId);
    _extendPlaybackHorizon(
      pcmBytes.length,
      sampleRate,
      extraPadMs: isColdStart ? 120 : 0,
    );

    if (!Platform.isLinux) return;

    final scaled = scalePcm16Volume(pcmBytes, volumePercent);
    try {
      if (_linuxProcess == null ||
          _activeSampleRate != sampleRate ||
          _activeDeviceId != outputDeviceId) {
        await _killLinuxProcess();
        _linuxProcess = await LinuxAudioPlaybackService.startPcmStreamProcess(
          sampleRate: sampleRate,
          outputDeviceId: outputDeviceId,
        );
        _activeSampleRate = sampleRate;
        _activeDeviceId = outputDeviceId;
        final proc = _linuxProcess!;
        unawaited(
          proc.exitCode.then((_) {
            if (identical(_linuxProcess, proc)) {
              _linuxProcess = null;
            }
          }).catchError((_) {}),
        );
      }
      _linuxProcess?.stdin.add(scaled);
    } catch (_) {
      await _killLinuxProcess();
    }
  }

  Future<void> stopImmediate() async {
    _playingUntil = DateTime.fromMillisecondsSinceEpoch(0);
    await _killLinuxProcess();
  }

  Future<void> _killLinuxProcess() async {
    final proc = _linuxProcess;
    _linuxProcess = null;
    _activeSampleRate = 0;
    if (proc == null) return;
    try {
      proc.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }

  void dispose() {
    _disposed = true;
    unawaited(stopImmediate());
  }
}
