import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../storage_bridge.dart';
import 'linux_audio_device_service.dart';
import 'linux_audio_env.dart';

/// Linux 播放进程句柄包装类
class LinuxPlaybackHandle {
  final Process _process;
  final String? _tempFilePath;
  final Completer<void> _done = Completer<void>();
  bool _stopped = false;

  LinuxPlaybackHandle(this._process, {String? tempFilePath})
      : _tempFilePath = tempFilePath {
    _process.exitCode.then((_) {
      _cleanupTempFile();
      if (!_done.isCompleted) _done.complete();
    }).catchError((_) {
      _cleanupTempFile();
      if (!_done.isCompleted) _done.complete();
    });
  }

  void _cleanupTempFile() {
    final path = _tempFilePath;
    if (path == null || path.isEmpty) return;
    try {
      final f = File(path);
      if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (_) {}
  }

  Future<void> get done => _done.future;

  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    try {
      _process.kill(ProcessSignal.sigterm);
    } catch (_) {}
    try {
      _process.kill(ProcessSignal.sigkill);
    } catch (_) {}
    _cleanupTempFile();
    if (!_done.isCompleted) _done.complete();
  }
}

/// Linux 音频播放与转码服务：
/// - 基于 aplay / paplay 进行 PCM/WAV 低延迟无缝播放
/// - 基于 ffmpeg 进行音频转码（MP3 -> 48kHz 立体声 WAV）与软件增益
/// - 内存 WAV 字节（提示音、快门声）即时播放
/// - 播放句柄生命周期管理与异常中断兜底
class LinuxAudioPlaybackService {
  LinuxAudioPlaybackService._();

  static final Set<LinuxPlaybackHandle> _activeHandles =
      <LinuxPlaybackHandle>{};

  /// 终止所有正在运行的播放子进程并清理活动句柄
  static Future<void> killRunningPlayProcesses() async {
    final handles = _activeHandles.toList();
    for (final h in handles) {
      await h.stop();
    }
    _activeHandles.clear();

    if (Platform.isLinux) {
      try {
        await Process.run('pkill', ['-f', 'paplay|aplay']);
      } catch (_) {}
    }
  }

  /// 在服务器端扬声器播放音频文件（支持 WAV 与 MP3）
  static Future<LinuxPlaybackHandle> playAudioFile(
    String filePath, {
    String outputDeviceId = '',
    int? volumePercent,
    String? cleanupFilePath,
  }) async {
    final env = LinuxAudioEnvironment.buildAudioEnv();
    final isWav = filePath.toLowerCase().endsWith('.wav');
    final vol = (volumePercent ?? LinuxAudioDeviceService.currentVolumePercent)
        .clamp(0, 150);
    final volFactor = (vol / 100.0).toStringAsFixed(2);
    final paVol = ((vol * 65536) / 100).round().clamp(0, 98304);
    final usePulse = outputDeviceId.startsWith('pulse:');

    String playTargetPath = filePath;
    String? tempWavToCleanup = cleanupFilePath;

    // 若输入不是 WAV（如 MP3），或走 ALSA 且音量非 100%，先转码为临时 WAV
    if (!isWav || (!usePulse && vol != 100)) {
      final tempDir = await StorageBridge.getAppTemporaryDirectory();
      final decodedWav = p.join(
        tempDir.path,
        'play_${DateTime.now().microsecondsSinceEpoch}.wav',
      );
      final ffArgs = <String>[
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-i',
        filePath,
        if (!usePulse && vol != 100) ...[
          '-filter:a',
          'volume=$volFactor',
        ],
        // 统一转成声卡普遍原生支持的 48kHz / 立体声 / s16le
        '-ar',
        '48000',
        '-ac',
        '2',
        '-c:a',
        'pcm_s16le',
        '-f',
        'wav',
        decodedWav,
      ];
      final res = await Process.run('ffmpeg', ffArgs, environment: env)
          .timeout(const Duration(seconds: 10));
      if (res.exitCode == 0 && File(decodedWav).existsSync()) {
        if (cleanupFilePath != null && cleanupFilePath != decodedWav) {
          try {
            File(cleanupFilePath).deleteSync();
          } catch (_) {}
        }
        playTargetPath = decodedWav;
        tempWavToCleanup = decodedWav;
      }
    }

    LinuxPlaybackHandle handle;
    if (usePulse) {
      final sinkName = outputDeviceId.substring('pulse:'.length);
      final proc = await Process.start(
        'paplay',
        [
          if (sinkName.isNotEmpty) '--device=$sinkName',
          '--volume=$paVol',
          playTargetPath,
        ],
        environment: env,
      );
      handle = LinuxPlaybackHandle(proc, tempFilePath: tempWavToCleanup);
    } else {
      final alsaDev = outputDeviceId.startsWith('alsa:')
          ? outputDeviceId.substring('alsa:'.length)
          : 'default';

      final proc = await Process.start(
        'aplay',
        [
          '-q',
          '--buffer-time=500000',
          if (alsaDev != 'default') ...['-D', alsaDev],
          playTargetPath,
        ],
        environment: env,
      );
      handle = LinuxPlaybackHandle(proc, tempFilePath: tempWavToCleanup);
    }

    _activeHandles.add(handle);
    handle.done.whenComplete(() {
      _activeHandles.remove(handle);
    });

    return handle;
  }

  /// 播放内存中的 WAV 字节（如提示音、快门声）
  static Future<LinuxPlaybackHandle> playWavBytes(
    Uint8List wavBytes, {
    String outputDeviceId = '',
    String tag = 'tone',
  }) async {
    final tempDir = await StorageBridge.getAppTemporaryDirectory();
    final file = File(p.join(tempDir.path, 'linux_$tag.wav'));
    await file.writeAsBytes(wavBytes, flush: true);
    return playAudioFile(file.path, outputDeviceId: outputDeviceId);
  }
}
