import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'asr_service.dart';
import 'foreground_service_bridge.dart';

enum MicListenMode {
  continuous, // 连续循环待机监听（实时捕捉触发词）
  manual,     // 手动点按 / 按住对讲
}

class VoiceListeningService {
  final AsrService asrService;
  final void Function(String text) onTextRecognized;
  final void Function(String text)? onManualRecordingRecognized;
  final void Function(bool isListening, String statusHint)? onStateChanged;
  final bool Function()? isStandbyMode;

  final AudioRecorder _recorder = AudioRecorder();
  bool _isListening = false;
  bool _isManualRecording = false;
  bool _disposed = false;
  Timer? _loopTimer;

  VoiceListeningService({
    required this.asrService,
    required this.onTextRecognized,
    this.onManualRecordingRecognized,
    this.onStateChanged,
    this.isStandbyMode,
  });

  bool get isListening => _isListening;
  bool get isManualRecording => _isManualRecording;

  /// 检查麦克风权限
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  /// 启动持续待机监听（循环切片，实时识别）
  Future<bool> startContinuousListening() async {
    if (_isListening) return true;

    final permitted = await hasPermission();
    if (!permitted) {
      onStateChanged?.call(false, '麦克风权限未授予');
      return false;
    }

    _isListening = true;
    await ForegroundServiceBridge.start(
      title: '随身助理后台运行中',
      content: '低功耗待机中，可随时说“晓漫”唤醒',
    );
    onStateChanged?.call(true, '话筒监听中（可随时说“晓漫”唤醒）');
    _startNextChunk();
    return true;
  }

  /// 停止持续待机监听
  Future<void> stopContinuousListening() async {
    _loopTimer?.cancel();
    _loopTimer = null;
    _isListening = false;
    await ForegroundServiceBridge.stop();

    try {
      if (await _recorder.isRecording()) {
        await _recorder.stop();
      }
    } catch (_) {}

    onStateChanged?.call(false, '话筒已静音');
  }

  /// 切换持续监听开关
  Future<bool> toggleContinuousListening() async {
    if (_isListening) {
      await stopContinuousListening();
      return false;
    } else {
      return await startContinuousListening();
    }
  }

  /// 开始手动单次录音（对讲模式）
  Future<bool> startManualRecording() async {
    if (_isListening) {
      await stopContinuousListening();
    }
    final permitted = await hasPermission();
    if (!permitted) return false;

    final tempDir = await getTemporaryDirectory();
    final manualPath = '${tempDir.path}/manual_voice_${DateTime.now().millisecondsSinceEpoch}.wav';

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: manualPath,
      );
      _isManualRecording = true;
      onStateChanged?.call(true, '正在录音...松开或点击发送');
      return true;
    } catch (e) {
      _isManualRecording = false;
      return false;
    }
  }

  /// 停止手动单次录音并立即识别
  Future<String> stopManualRecording() async {
    if (!_isManualRecording) return '';
    _isManualRecording = false;

    try {
      final path = await _recorder.stop();
      if (path != null && File(path).existsSync()) {
        onStateChanged?.call(false, '正在本地离线识别...');
        final recognizedText = await asrService.transcribeAudioFile(path, isStandbyWakeCheck: false);
        try {
          File(path).deleteSync();
        } catch (_) {}

        if (recognizedText.isNotEmpty) {
          if (onManualRecordingRecognized != null) {
            onManualRecordingRecognized!(recognizedText);
          } else {
            onTextRecognized(recognizedText);
          }
        }
        onStateChanged?.call(false, '识别完成');
        return recognizedText;
      }
    } catch (_) {}

    onStateChanged?.call(false, '已取消录音');
    return '';
  }

  void _startNextChunk() async {
    if (!_isListening || _disposed) return;

    try {
      final tempDir = await getTemporaryDirectory();
      final chunkFile = '${tempDir.path}/mic_chunk_${DateTime.now().millisecondsSinceEpoch}.wav';

      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: chunkFile,
      );

      // 实时监测语音能量（VAD 门控）
      // 在移动端/模拟器上，正常人声通常在 -58.0 到 -44.0 dBFS 之间。若底层返回 -160 或不支持则交由 PCM 分析。
      bool hasSpeechActivity = false;
      bool amplitudeFailedOrUnsupported = false;

      final ampTimer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
        try {
          final amp = await _recorder.getAmplitude();
          if (amp.current > -58.0 || amp.max > -58.0) {
            hasSpeechActivity = true;
          }
        } catch (_) {
          amplitudeFailedOrUnsupported = true;
        }
      });

      // 录制 3.0 秒音频切片
      _loopTimer = Timer(const Duration(milliseconds: 3000), () async {
        ampTimer.cancel();
        if (!_isListening || _disposed) return;

        try {
          final stoppedPath = await _recorder.stop();
          // 无缝启动下一个切片
          _startNextChunk();

          final shouldTranscribe = hasSpeechActivity || amplitudeFailedOrUnsupported;

          if (shouldTranscribe && stoppedPath != null && File(stoppedPath).existsSync()) {
            final isStandby = isStandbyMode?.call() ?? true;
            debugPrint('[VoiceListeningService] 切片录制就绪，送检 ASR: $stoppedPath (isStandby=$isStandby)');
            onStateChanged?.call(true, '检测到声音，正在识别...');

            try {
              final text = await asrService.transcribeAudioFile(stoppedPath, isStandbyWakeCheck: isStandby);
              if (text.isNotEmpty) {
                debugPrint('[VoiceListeningService] 识别到有效文字: "$text"');
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
            // 纯静音切片直接清除，0 神经网络开销
            try {
              File(stoppedPath).deleteSync();
            } catch (_) {}
          }
        } catch (e, st) {
          debugPrint('[VoiceListeningService] 切片处理异常: $e\n$st');
          if (_isListening) {
            _startNextChunk();
          }
        }
      });
    } catch (e, st) {
      debugPrint('[VoiceListeningService] 启动录音切片失败: $e\n$st');
      // 若单次启动失败，延迟 1 秒后重试
      _loopTimer = Timer(const Duration(seconds: 1), _startNextChunk);
    }
  }

  void dispose() {
    _disposed = true;
    _loopTimer?.cancel();
    ForegroundServiceBridge.stop();
    _recorder.dispose();
  }
}
