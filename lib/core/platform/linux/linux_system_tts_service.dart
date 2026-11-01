import 'dart:async';
import 'dart:io';
import 'package:path/path.dart' as p;
import '../foundation_bridge.dart';
import '../storage_bridge.dart';
import 'linux_audio_playback_service.dart';

/// Linux 系统离线 TTS 兜底服务：
/// 基于 espeak-ng 生成中文语音 WAV，转交 LinuxAudioPlaybackService 进行播放
class LinuxSystemTtsService {
  LinuxSystemTtsService._();

  /// Linux 系统级离线 TTS 兜底（基于 espeak-ng 生成 WAV 后走扬声器播放）
  static Future<LinuxPlaybackHandle?> speakSystemTts(
    String text, {
    double speed = 1.0,
    String outputDeviceId = '',
  }) async {
    try {
      final tempDir = await StorageBridge.getAppTemporaryDirectory();
      final outWav = File(
        p.join(
          tempDir.path,
          'espeak_${DateTime.now().microsecondsSinceEpoch}.wav',
        ),
      );
      final wpm = (175 * speed).round().clamp(80, 450);
      final res = await Process.run('espeak-ng', [
        '-v',
        'cmn',
        '-s',
        '$wpm',
        '-w',
        outWav.path,
        text,
      ]).timeout(const Duration(seconds: 8));
      if (res.exitCode == 0 && outWav.existsSync()) {
        return LinuxAudioPlaybackService.playAudioFile(
          outWav.path,
          outputDeviceId: outputDeviceId,
          cleanupFilePath: outWav.path,
        );
      }
    } catch (e) {
      debugPrint('[LinuxSystemTtsService] espeak-ng 合成失败: $e');
    }
    return null;
  }
}
