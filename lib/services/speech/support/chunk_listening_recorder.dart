import 'dart:async';
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import '../../../core/platform/audio_recorder_bridge.dart';
import '../../../core/platform/foundation_bridge.dart';
import '../../../core/platform/storage_bridge.dart';
import '../asr_service.dart';

/// 降级文件切片录音机（Chunk-based Fallback Audio Recorder）
///
/// 当原生 PCM 实时流通道不可用或崩溃时，使用 1.2 秒 Wav 文件切片持续监听。
class ChunkListeningRecorder {
  final PlatformAudioRecorder _recorder = PlatformAudioRecorder();
  final AsrService asrService;
  final PlatformInputDevice? activeInputDevice;
  final bool Function() isListening;
  final bool Function() isDisposed;
  final bool Function() isEnrollingSpeaker;
  final bool Function() isStandbyMode;
  final bool Function() isInCooldown;
  final Float32List Function(Float32List audio) applyTse;
  final bool Function(Float32List samples) isTseZeroed;
  final void Function(bool isListening, String statusHint)? onStateChanged;
  final void Function(String text) onTextRecognized;

  Timer? _loopTimer;

  ChunkListeningRecorder({
    required this.asrService,
    this.activeInputDevice,
    required this.isListening,
    required this.isDisposed,
    required this.isEnrollingSpeaker,
    required this.isStandbyMode,
    required this.isInCooldown,
    required this.applyTse,
    required this.isTseZeroed,
    this.onStateChanged,
    required this.onTextRecognized,
  });

  void start() {
    _startNextChunk();
  }

  void stop() {
    _loopTimer?.cancel();
    _loopTimer = null;
    unawaited(_recorder.stop());
  }

  void dispose() {
    stop();
    _recorder.dispose();
  }

  void _startNextChunk() async {
    if (!isListening() || isDisposed()) return;

    try {
      final tempDir = await StorageBridge.getAppTemporaryDirectory();
      final chunkFile =
          '${tempDir.path}/mic_chunk_${DateTime.now().millisecondsSinceEpoch}.wav';

      await _recorder.startWavFile(
        path: chunkFile,
        device: activeInputDevice,
      );

      bool hasSpeechActivity = false;
      bool amplitudeFailedOrUnsupported = false;

      final ampTimer =
          Timer.periodic(const Duration(milliseconds: 200), (_) async {
        try {
          final amp = await _recorder.getAmplitude();
          if (amp.current > -58.0 || amp.max > -58.0) {
            hasSpeechActivity = true;
          }
        } catch (_) {
          amplitudeFailedOrUnsupported = true;
        }
      });

      // 降级模式：录制 1200ms 短音频切片（避免过大延迟）
      _loopTimer = Timer(const Duration(milliseconds: 1200), () async {
        ampTimer.cancel();
        if (!isListening() || isDisposed()) return;

        try {
          final stoppedPath = await _recorder.stop();
          // 无缝启动下一个切片
          _startNextChunk();

          if (isInCooldown() || isEnrollingSpeaker()) {
            if (stoppedPath != null && File(stoppedPath).existsSync()) {
              try {
                File(stoppedPath).deleteSync();
              } catch (_) {}
            }
            return;
          }

          final shouldTranscribe =
              hasSpeechActivity || amplitudeFailedOrUnsupported;

          if (shouldTranscribe &&
              stoppedPath != null &&
              File(stoppedPath).existsSync()) {
            final isStandby = isStandbyMode();
            debugPrint(
                '[ChunkListeningRecorder] 切片录制就绪，送检 ASR: $stoppedPath (isStandby=$isStandby)');
            onStateChanged?.call(true, '检测到声音，正在识别...');

            try {
              final wave = sherpa_onnx.readWave(stoppedPath);
              final samples = applyTse(wave.samples);
              if (isTseZeroed(samples)) return;
              final text = samples.isEmpty
                  ? ''
                  : await asrService.transcribeSamples(
                      samples,
                      sampleRate: wave.sampleRate,
                      isStandbyWakeCheck: isStandby,
                      fromVad: true,
                    );
              if (text.isNotEmpty) {
                debugPrint('[ChunkListeningRecorder] 识别到有效文字: "$text"');
                onTextRecognized(text);
              }
            } finally {
              try {
                if (File(stoppedPath).existsSync()) {
                  File(stoppedPath).deleteSync();
                }
              } catch (_) {}
            }
          } else if (stoppedPath != null && File(stoppedPath).existsSync()) {
            try {
              File(stoppedPath).deleteSync();
            } catch (_) {}
          }
        } catch (e, st) {
          debugPrint('[ChunkListeningRecorder] 切片处理异常: $e\n$st');
          if (isListening()) {
            _startNextChunk();
          }
        }
      });
    } catch (e, st) {
      debugPrint('[ChunkListeningRecorder] 启动录音切片失败: $e\n$st');
      _loopTimer = Timer(const Duration(seconds: 1), _startNextChunk);
    }
  }
}
