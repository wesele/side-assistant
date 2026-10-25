import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path/path.dart' as p;
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/storage_bridge.dart';
import '../speech/audio_input_device_service.dart';

class AudioOutputDeviceOption {
  final String id;
  final String label;

  const AudioOutputDeviceOption({
    required this.id,
    required this.label,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
      };
}

class LinuxCameraDeviceOption {
  final String id; // e.g. '/dev/video0'
  final String label;

  const LinuxCameraDeviceOption({
    required this.id,
    required this.label,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
      };
}

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

class LinuxMicRecordStream {
  final Process process;
  final Stream<Uint8List> stream;

  LinuxMicRecordStream({
    required this.process,
    required this.stream,
  });

  Future<void> stop() async {
    try {
      process.kill(ProcessSignal.sigterm);
    } catch (_) {}
    try {
      process.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }
}

/// Linux 无头服务端硬件驱动层：
/// - 麦克风枚举与 16kHz 16-bit 单声道 PCM 采集（ALSA / PipeWire / PulseAudio）
/// - 扬声器枚举与 WAV/MP3 播放（aplay / paplay / ffmpeg）
/// - 离线系统 TTS 兜底（espeak-ng）
/// - V4L2 本地摄像头枚举与抓拍（/dev/video* + ffmpeg）
class LinuxHardwareService {
  LinuxHardwareService._();

  /// 构建包含 XDG_RUNTIME_DIR 的环境变量，确保 systemd 服务或 SSH 下也能访问 PipeWire/PulseAudio。
  static Map<String, String> _audioEnv() {
    final env = Map<String, String>.from(Platform.environment);
    if (!env.containsKey('XDG_RUNTIME_DIR') || env['XDG_RUNTIME_DIR']!.isEmpty) {
      try {
        final res = Process.runSync('id', ['-u']);
        if (res.exitCode == 0) {
          final uid = res.stdout.toString().trim();
          final runDir = '/run/user/$uid';
          if (Directory(runDir).existsSync()) {
            env['XDG_RUNTIME_DIR'] = runDir;
          }
        }
      } catch (_) {}
    }
    return env;
  }

  /// 枚举 Linux 上的麦克风输入设备（包含 PulseAudio/PipeWire 源与 ALSA 硬件采集卡）
  static Future<List<AudioInputDeviceOption>> listInputDevices() async {
    if (!Platform.isLinux) return const [];
    final devices = <AudioInputDeviceOption>[];
    final seenIds = <String>{};

    // 1. PulseAudio / PipeWire sources
    try {
      final res = await Process.run(
        'pactl',
        ['list', 'short', 'sources'],
        environment: _audioEnv(),
      ).timeout(const Duration(seconds: 3));
      if (res.exitCode == 0) {
        final lines = res.stdout.toString().split(RegExp(r'[\r\n]+'));
        for (final line in lines) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            final name = parts[1].trim();
            // 排除扬声器环回监听源 (.monitor)
            if (name.isEmpty || name.endsWith('.monitor')) continue;
            final id = 'pulse:$name';
            if (seenIds.add(id)) {
              final isBt = name.toLowerCase().contains('bluez') ||
                  name.toLowerCase().contains('bluetooth');
              devices.add(AudioInputDeviceOption(
                id: id,
                label: 'PipeWire/Pulse: $name',
                isBluetooth: isBt,
              ));
            }
          }
        }
      }
    } catch (_) {}

    // 2. ALSA hardware capture devices (arecord -l)
    try {
      final res = await Process.run('arecord', ['-l'])
          .timeout(const Duration(seconds: 3));
      if (res.exitCode == 0) {
        final lines = res.stdout.toString().split(RegExp(r'[\r\n]+'));
        final cardDevRegex = RegExp(
          r'card\s+(\d+):\s*([^\[]+)\[([^\]]+)\],\s*device\s+(\d+):\s*([^\[]+)\[([^\]]+)\]',
          caseSensitive: false,
        );
        for (final line in lines) {
          final match = cardDevRegex.firstMatch(line);
          if (match != null) {
            final cardNum = match.group(1)!;
            final cardName = match.group(3)!.trim();
            final devNum = match.group(4)!;
            final devName = match.group(6)!.trim();
            final id = 'alsa:plughw:$cardNum,$devNum';
            if (seenIds.add(id)) {
              devices.add(AudioInputDeviceOption(
                id: id,
                label: 'ALSA: $cardName - $devName (plughw:$cardNum,$devNum)',
              ));
            }
          }
        }
      }
    } catch (_) {}

    return devices;
  }

  /// 枚举 Linux 上的扬声器输出设备
  static Future<List<AudioOutputDeviceOption>> listOutputDevices() async {
    if (!Platform.isLinux) return const [];
    final devices = <AudioOutputDeviceOption>[];
    final seenIds = <String>{};

    // 1. PulseAudio / PipeWire sinks
    try {
      final res = await Process.run(
        'pactl',
        ['list', 'short', 'sinks'],
        environment: _audioEnv(),
      ).timeout(const Duration(seconds: 3));
      if (res.exitCode == 0) {
        final lines = res.stdout.toString().split(RegExp(r'[\r\n]+'));
        for (final line in lines) {
          final parts = line.trim().split(RegExp(r'\s+'));
          if (parts.length >= 2) {
            final name = parts[1].trim();
            if (name.isEmpty) continue;
            final id = 'pulse:$name';
            if (seenIds.add(id)) {
              devices.add(AudioOutputDeviceOption(
                id: id,
                label: 'PipeWire/Pulse: $name',
              ));
            }
          }
        }
      }
    } catch (_) {}

    // 2. ALSA hardware playback devices (aplay -l)
    try {
      final res = await Process.run('aplay', ['-l'])
          .timeout(const Duration(seconds: 3));
      if (res.exitCode == 0) {
        final lines = res.stdout.toString().split(RegExp(r'[\r\n]+'));
        final cardDevRegex = RegExp(
          r'card\s+(\d+):\s*([^\[]+)\[([^\]]+)\],\s*device\s+(\d+):\s*([^\[]+)\[([^\]]+)\]',
          caseSensitive: false,
        );
        for (final line in lines) {
          final match = cardDevRegex.firstMatch(line);
          if (match != null) {
            final cardNum = match.group(1)!;
            final cardName = match.group(3)!.trim();
            final devNum = match.group(4)!;
            final devName = match.group(6)!.trim();
            final id = 'alsa:plughw:$cardNum,$devNum';
            if (seenIds.add(id)) {
              devices.add(AudioOutputDeviceOption(
                id: id,
                label: 'ALSA: $cardName - $devName (plughw:$cardNum,$devNum)',
              ));
            }
          }
        }
      }
    } catch (_) {}

    return devices;
  }

  /// 枚举 Linux 上的本地 V4L2 摄像头设备（排除 metadata 节点）
  static Future<List<LinuxCameraDeviceOption>> listCameraDevices() async {
    if (!Platform.isLinux) return const [];
    final result = <LinuxCameraDeviceOption>[];
    final sysDir = Directory('/sys/class/video4linux');
    if (!sysDir.existsSync()) return const [];

    try {
      final entries = sysDir
          .listSync()
          .where((e) => Directory(e.path).existsSync())
          .toList()
        ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final entry in entries) {
        final devName = p.basename(entry.path); // e.g. video0
        final devPath = '/dev/$devName';
        // 只保留 index 为 0 的主视频采集流节点（跳过 index=1 的 metadata 节点）
        final indexFile = File(p.join(entry.path, 'index'));
        if (indexFile.existsSync()) {
          final idx = indexFile.readAsStringSync().trim();
          if (idx.isNotEmpty && idx != '0') {
            continue;
          }
        }
        String humanName = devName;
        final nameFile = File(p.join(entry.path, 'name'));
        if (nameFile.existsSync()) {
          final rawName = nameFile.readAsStringSync().trim();
          if (rawName.isNotEmpty) {
            humanName = '$rawName ($devPath)';
          }
        }
        result.add(LinuxCameraDeviceOption(
          id: devPath,
          label: humanName,
        ));
      }
    } catch (e) {
      debugPrint('[LinuxHardwareService] 枚举摄像头失败: $e');
    }
    return result;
  }

  /// 启动 16kHz 16-bit 单声道 PCM 麦克风实时流
  static Future<LinuxMicRecordStream> startMicStream({
    String deviceId = '',
    int sampleRate = 16000,
    int numChannels = 1,
  }) async {
    final env = _audioEnv();
    String executable = 'arecord';
    List<String> args;

    if (deviceId.startsWith('pulse:')) {
      final sourceName = deviceId.substring('pulse:'.length);
      executable = 'parec';
      args = [
        '--format=s16le',
        '--rate=$sampleRate',
        '--channels=$numChannels',
        '--latency-msec=40',
        if (sourceName.isNotEmpty) '--device=$sourceName',
      ];
    } else if (deviceId.startsWith('alsa:')) {
      final alsaDev = deviceId.substring('alsa:'.length);
      args = [
        '-D',
        alsaDev,
        '-f',
        'S16_LE',
        '-r',
        '$sampleRate',
        '-c',
        '$numChannels',
        '-t',
        'raw',
        '-q',
      ];
    } else {
      // 默认优先走 ALSA default（若系统有 PipeWire/Pulse 会自动桥接，无桌面则走默认声卡）
      args = [
        '-f',
        'S16_LE',
        '-r',
        '$sampleRate',
        '-c',
        '$numChannels',
        '-t',
        'raw',
        '-q',
      ];
    }

    final proc = await Process.start(executable, args, environment: env);
    final controller = StreamController<Uint8List>();

    proc.stdout.listen(
      (chunk) {
        if (!controller.isClosed && chunk.isNotEmpty) {
          controller.add(Uint8List.fromList(chunk));
        }
      },
      onError: (Object e, StackTrace st) {
        if (!controller.isClosed) controller.addError(e, st);
      },
      onDone: () {
        if (!controller.isClosed) controller.close();
      },
    );

    proc.stderr.transform(utf8.decoder).listen((err) {
      final trimmed = err.trim();
      if (trimmed.isNotEmpty) {
        debugPrint('[LinuxMicRecordStream][$executable] $trimmed');
      }
    });

    return LinuxMicRecordStream(
      process: proc,
      stream: controller.stream,
    );
  }

  /// 录制 WAV 文件（用于手动按住对讲录音）
  static Future<Process> startWavFileRecording({
    required String filePath,
    String deviceId = '',
    int sampleRate = 16000,
    int numChannels = 1,
  }) async {
    final env = _audioEnv();
    final alsaDev = deviceId.startsWith('alsa:')
        ? deviceId.substring('alsa:'.length)
        : '';

    final args = <String>[
      if (alsaDev.isNotEmpty) ...['-D', alsaDev],
      '-f',
      'S16_LE',
      '-r',
      '$sampleRate',
      '-c',
      '$numChannels',
      '-t',
      'wav',
      '-q',
      filePath,
    ];
    return Process.start('arecord', args, environment: env);
  }

  static int _currentVolumePercent = 80;
  static int get currentVolumePercent => _currentVolumePercent;

  /// 读取 Linux 服务器当前扬声器音量百分比（0 - 150）
  static Future<int> getOutputVolume({String outputDeviceId = ''}) async {
    if (!Platform.isLinux) return _currentVolumePercent;
    final env = _audioEnv();
    final sink = outputDeviceId.startsWith('pulse:') &&
            outputDeviceId.substring('pulse:'.length).isNotEmpty
        ? outputDeviceId.substring('pulse:'.length)
        : '@DEFAULT_SINK@';
    try {
      final res = await Process.run(
        'pactl',
        ['get-sink-volume', sink],
        environment: env,
      ).timeout(const Duration(seconds: 2));
      if (res.exitCode == 0) {
        final match = RegExp(r'(\d+)%').firstMatch(res.stdout.toString());
        if (match != null) {
          final v = int.tryParse(match.group(1)!);
          if (v != null) {
            _currentVolumePercent = v.clamp(0, 150);
            return _currentVolumePercent;
          }
        }
      }
    } catch (_) {}

    try {
      final res = await Process.run('amixer', ['sget', 'Master'])
          .timeout(const Duration(seconds: 2));
      if (res.exitCode == 0) {
        final match = RegExp(r'\[(\d+)%\]').firstMatch(res.stdout.toString());
        if (match != null) {
          final v = int.tryParse(match.group(1)!);
          if (v != null) {
            _currentVolumePercent = v.clamp(0, 150);
            return _currentVolumePercent;
          }
        }
      }
    } catch (_) {}

    return _currentVolumePercent;
  }

  /// 设置 Linux 服务器扬声器播放音量百分比（0 - 150）
  static Future<void> setOutputVolume(
    int volumePercent, {
    String outputDeviceId = '',
  }) async {
    final clamped = volumePercent.clamp(0, 150);
    _currentVolumePercent = clamped;
    if (!Platform.isLinux) return;

    final env = _audioEnv();
    final sink = outputDeviceId.startsWith('pulse:') &&
            outputDeviceId.substring('pulse:'.length).isNotEmpty
        ? outputDeviceId.substring('pulse:'.length)
        : '@DEFAULT_SINK@';

    try {
      await Process.run(
        'pactl',
        ['set-sink-mute', sink, clamped == 0 ? '1' : '0'],
        environment: env,
      ).timeout(const Duration(seconds: 2));
      await Process.run(
        'pactl',
        ['set-sink-volume', sink, '$clamped%'],
        environment: env,
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}

    try {
      String? cardNum;
      if (outputDeviceId.startsWith('alsa:plughw:')) {
        final rest = outputDeviceId.substring('alsa:plughw:'.length);
        cardNum = rest.split(',').first.trim();
      }
      final args = <String>[
        if (cardNum != null && cardNum.isNotEmpty) ...['-c', cardNum],
        'sset',
        'Master',
        '${clamped.clamp(0, 100)}%',
        clamped == 0 ? 'mute' : 'unmute',
      ];
      await Process.run('amixer', args).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  /// 在服务器端扬声器播放音频文件（支持 WAV 与 MP3）。
  ///
  /// 注意：不要使用 `ffmpeg ... -f pulse` 直接推流播放短音频！因为 ffmpeg 的 pulse muxer
  /// 在写入约 2 秒环形缓冲后会立即关闭流退出而不执行 `pa_simple_drain`，导致每句话末尾约 2 秒被截断。
  /// 因此对非 WAV（如 Edge-TTS 生成的 MP3）或需 ALSA 软件缩放的音频，先用 ffmpeg 极速转码为临时 WAV，
  /// 再交由 `paplay` / `aplay` 播放并完整 drain 硬件缓冲。
  static Future<LinuxPlaybackHandle> playAudioFile(
    String filePath, {
    String outputDeviceId = '',
    int? volumePercent,
    String? cleanupFilePath,
  }) async {
    final env = _audioEnv();
    final isWav = filePath.toLowerCase().endsWith('.wav');
    final vol = (volumePercent ?? _currentVolumePercent).clamp(0, 150);
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
        // 统一转成声卡普遍原生支持的 48kHz / 立体声 / s16le，避免 Edge-TTS 的
        // 24kHz 单声道 MP3 在部分 Linux 声卡/PipeWire 上因重采样或格式协商不稳而后半段出现乱音。
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
      return LinuxPlaybackHandle(proc, tempFilePath: tempWavToCleanup);
    }

    final alsaDev = outputDeviceId.startsWith('alsa:')
        ? outputDeviceId.substring('alsa:'.length)
        : 'default';

    final proc = await Process.start(
      'aplay',
      [
        '-q',
        // 加大缓冲，避免 CPU 抖动导致 underrun 后输出错位的噪音
        '--buffer-time=500000',
        if (alsaDev != 'default') ...['-D', alsaDev],
        playTargetPath,
      ],
      environment: env,
    );
    return LinuxPlaybackHandle(proc, tempFilePath: tempWavToCleanup);
  }

  /// 播放内存中的 WAV 字节（如轻滴提示音、快门声）
  static Future<LinuxPlaybackHandle> playWavBytes(
    Uint8List wavBytes, {
    String outputDeviceId = '',
    String tag = 'tone',
  }) async {
    final tempDir = await StorageBridge.getAppTemporaryDirectory();
    final file = File(p.join(tempDir.path, 'linux_${tag}.wav'));
    await file.writeAsBytes(wavBytes, flush: true);
    return playAudioFile(file.path, outputDeviceId: outputDeviceId);
  }

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
        return playAudioFile(
          outWav.path,
          outputDeviceId: outputDeviceId,
          cleanupFilePath: outWav.path,
        );
      }
    } catch (e) {
      debugPrint('[LinuxHardwareService] espeak-ng 合成失败: $e');
    }
    return null;
  }

  /// 使用 V4L2 + ffmpeg 从本地摄像头抓拍一帧 JPEG
  static Future<(Uint8List bytes, String filePath)> captureV4l2Photo({
    String configuredDevice = '',
    int targetWidth = 0,
    int targetHeight = 0,
    int sendShortEdge = 0,
  }) async {
    String devicePath = configuredDevice.trim();
    if (devicePath.isEmpty) {
      final cameras = await listCameraDevices();
      if (cameras.isNotEmpty) {
        devicePath = cameras.first.id;
      } else {
        devicePath = '/dev/video0';
      }
    }

    final tempDir = await StorageBridge.getAppTemporaryDirectory();
    final outPath = p.join(
      tempDir.path,
      'capture_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );

    final vfParts = <String>[
      // 跳过前几帧以便摄像头自动曝光稳定
      r'select=gte(n\,4)',
    ];
    if (sendShortEdge > 0) {
      vfParts.add(
        "scale='if(gt(iw,ih),-2,min($sendShortEdge,iw))':'if(gt(iw,ih),min($sendShortEdge,ih),-2)'",
      );
    }

    final args = <String>[
      '-y',
      '-hide_banner',
      '-loglevel',
      'error',
      '-f',
      'v4l2',
      if (targetWidth > 0 && targetHeight > 0) ...[
        '-video_size',
        '${targetWidth}x$targetHeight',
      ],
      '-i',
      devicePath,
      '-vf',
      vfParts.join(','),
      '-frames:v',
      '1',
      '-update',
      '1',
      '-q:v',
      '2',
      outPath,
    ];

    var res = await Process.run('ffmpeg', args)
        .timeout(const Duration(seconds: 12));
    final outFile = File(outPath);

    // 若摄像头帧率较低或不支持 select=gte(n,4)，回退到直接抓第一帧
    if (res.exitCode != 0 || !outFile.existsSync() || outFile.lengthSync() == 0) {
      final fallbackArgs = <String>[
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-f',
        'v4l2',
        '-i',
        devicePath,
        if (sendShortEdge > 0) ...[
          '-vf',
          "scale='if(gt(iw,ih),-2,min($sendShortEdge,iw))':'if(gt(iw,ih),min($sendShortEdge,ih),-2)'",
        ],
        '-frames:v',
        '1',
        '-update',
        '1',
        '-q:v',
        '2',
        outPath,
      ];
      res = await Process.run('ffmpeg', fallbackArgs)
          .timeout(const Duration(seconds: 10));
    }

    if (res.exitCode != 0 || !outFile.existsSync() || outFile.lengthSync() == 0) {
      final errText = res.stderr.toString().trim();
      throw Exception('Linux V4L2 ($devicePath) 抓拍失败: $errText');
    }

    final bytes = await outFile.readAsBytes();
    return (bytes, outPath);
  }
}
