import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'foundation_bridge.dart' show isRunningInFlutterTest;
import 'pcm_stream_player_bridge_io.dart' as io_impl;

export 'pcm_stream_player_bridge_io.dart' show scalePcm16Volume;

/// Flutter 跨平台（Windows waveOut / Android AudioTrack / Linux pacat）24kHz PCM 流式播放器
class PlatformPcmStreamPlayer {
  static const MethodChannel _channel =
      MethodChannel('com.sideassistant.side_assistant/pcm_player');

  final io_impl.PlatformPcmStreamPlayer _linuxPlayer =
      io_impl.PlatformPcmStreamPlayer();

  bool _nativeChannelSupported = true;
  bool _disposed = false;
  DateTime _playingUntil = DateTime.fromMillisecondsSinceEpoch(0);

  // 当未重编原生 Runner 时的内存 WAV 队列降级播放器
  AudioPlayer? _fallbackPlayer;
  final List<Uint8List> _fallbackBuffer = <Uint8List>[];
  int _fallbackBufferBytes = 0;
  int _fallbackSampleRate = 24000;
  bool _fallbackPlaying = false;
  int _generation = 0;

  bool get isPlaying => DateTime.now().isBefore(_playingUntil);

  void _extendPlaybackHorizon(int byteCount, int sampleRate) {
    if (byteCount <= 0 || sampleRate <= 0) return;
    final durationMs = ((byteCount / 2) * 1000 / sampleRate).ceil();
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
    _extendPlaybackHorizon(pcmBytes.length, sampleRate);

    if (isRunningInFlutterTest) return;

    if (Platform.isLinux) {
      await _linuxPlayer.feedPcm(
        pcmBytes,
        sampleRate: sampleRate,
        volumePercent: volumePercent,
        outputDeviceId: outputDeviceId,
      );
      return;
    }

    final scaled = io_impl.scalePcm16Volume(pcmBytes, volumePercent);

    if (_nativeChannelSupported && (Platform.isWindows || Platform.isAndroid)) {
      try {
        await _channel.invokeMethod<bool>('feed', <String, dynamic>{
          'bytes': scaled,
          'sampleRate': sampleRate,
        });
        return;
      } on MissingPluginException {
        _nativeChannelSupported = false;
      } catch (_) {}
    }

    // 降级：微批次内存 WAV 流式播放
    _fallbackSampleRate = sampleRate;
    _fallbackBuffer.add(scaled);
    _fallbackBufferBytes += scaled.length;
    if (!_fallbackPlaying && _fallbackBufferBytes >= sampleRate ~/ 4) {
      unawaited(_drainFallbackQueue(_generation));
    }
  }

  Future<void> _drainFallbackQueue(int gen) async {
    if (_fallbackPlaying || _disposed || gen != _generation) return;
    _fallbackPlaying = true;
    try {
      while (_fallbackBuffer.isNotEmpty && !_disposed && gen == _generation) {
        final total = _fallbackBufferBytes;
        final merged = Uint8List(total);
        var offset = 0;
        for (final chunk in _fallbackBuffer) {
          merged.setRange(offset, offset + chunk.length, chunk);
          offset += chunk.length;
        }
        _fallbackBuffer.clear();
        _fallbackBufferBytes = 0;

        final wav = _buildWavFromPcm16(merged, _fallbackSampleRate);
        _fallbackPlayer ??= AudioPlayer();
        final completer = Completer<void>();
        final sub = _fallbackPlayer!.onPlayerComplete.listen((_) {
          if (!completer.isCompleted) completer.complete();
        });
        await _fallbackPlayer!.play(BytesSource(wav, mimeType: 'audio/wav'));
        final durationMs =
            ((merged.length / 2) * 1000 / _fallbackSampleRate).ceil() + 300;
        await completer.future.timeout(
          Duration(milliseconds: durationMs),
          onTimeout: () {},
        );
        await sub.cancel();
      }
    } catch (_) {
    } finally {
      _fallbackPlaying = false;
    }
  }

  Future<void> stopImmediate() async {
    _generation++;
    _playingUntil = DateTime.fromMillisecondsSinceEpoch(0);
    _fallbackBuffer.clear();
    _fallbackBufferBytes = 0;

    if (isRunningInFlutterTest) return;

    if (Platform.isLinux) {
      await _linuxPlayer.stopImmediate();
      return;
    }

    if (_nativeChannelSupported && (Platform.isWindows || Platform.isAndroid)) {
      try {
        await _channel.invokeMethod<bool>('stop');
      } on MissingPluginException {
        _nativeChannelSupported = false;
      } catch (_) {}
    }

    try {
      await _fallbackPlayer?.stop();
    } catch (_) {}
  }

  static Uint8List _buildWavFromPcm16(Uint8List pcmBytes, int sampleRate) {
    final byteRate = sampleRate * 2;
    final wav = Uint8List(44 + pcmBytes.length);
    final bd = ByteData.sublistView(wav);
    wav.setRange(0, 4, const [0x52, 0x49, 0x46, 0x46]); // RIFF
    bd.setUint32(4, 36 + pcmBytes.length, Endian.little);
    wav.setRange(8, 12, const [0x57, 0x41, 0x56, 0x45]); // WAVE
    wav.setRange(12, 16, const [0x66, 0x6D, 0x74, 0x20]); // fmt
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, 1, Endian.little); // Mono
    bd.setUint32(24, sampleRate, Endian.little);
    bd.setUint32(28, byteRate, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    wav.setRange(36, 40, const [0x64, 0x61, 0x74, 0x61]); // data
    bd.setUint32(40, pcmBytes.length, Endian.little);
    wav.setRange(44, 44 + pcmBytes.length, pcmBytes);
    return wav;
  }

  void dispose() {
    _disposed = true;
    _linuxPlayer.dispose();
    unawaited(stopImmediate());
    try {
      _fallbackPlayer?.dispose();
    } catch (_) {}
  }
}
