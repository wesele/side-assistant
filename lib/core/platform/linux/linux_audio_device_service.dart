import 'dart:async';
import 'dart:io';
import '../../models/device_options.dart';
import 'linux_audio_env.dart';

/// Linux 音频硬件与混音器服务：
/// - 麦克风输入设备枚举（PulseAudio/PipeWire Sources + ALSA capture cards）
/// - 扬声器输出设备枚举（PulseAudio/PipeWire Sinks + ALSA playback cards）
/// - 混音器音量查询与调节（pactl get/set-sink-volume + amixer Master）
class LinuxAudioDeviceService {
  LinuxAudioDeviceService._();

  static int _currentVolumePercent = 80;
  static int get currentVolumePercent => _currentVolumePercent;

  /// 解析 pactl list short sources 输出
  static List<AudioInputDeviceOption> parsePactlSources(
    String stdout, {
    Set<String>? seenIds,
  }) {
    final devices = <AudioInputDeviceOption>[];
    final seen = seenIds ?? <String>{};
    final lines = stdout.split(RegExp(r'[\r\n]+'));
    for (final line in lines) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final name = parts[1].trim();
        // 排除扬声器环回监听源 (.monitor)
        if (name.isEmpty || name.endsWith('.monitor')) continue;
        final id = 'pulse:$name';
        if (seen.add(id)) {
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
    return devices;
  }

  /// 解析 arecord -l 输出
  static List<AudioInputDeviceOption> parseArecordList(
    String stdout, {
    Set<String>? seenIds,
  }) {
    final devices = <AudioInputDeviceOption>[];
    final seen = seenIds ?? <String>{};
    final lines = stdout.split(RegExp(r'[\r\n]+'));
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
        if (seen.add(id)) {
          devices.add(AudioInputDeviceOption(
            id: id,
            label: 'ALSA: $cardName - $devName (plughw:$cardNum,$devNum)',
          ));
        }
      }
    }
    return devices;
  }

  /// 解析 pactl list short sinks 输出
  static List<AudioOutputDeviceOption> parsePactlSinks(
    String stdout, {
    Set<String>? seenIds,
  }) {
    final devices = <AudioOutputDeviceOption>[];
    final seen = seenIds ?? <String>{};
    final lines = stdout.split(RegExp(r'[\r\n]+'));
    for (final line in lines) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final name = parts[1].trim();
        if (name.isEmpty) continue;
        final id = 'pulse:$name';
        if (seen.add(id)) {
          devices.add(AudioOutputDeviceOption(
            id: id,
            label: 'PipeWire/Pulse: $name',
          ));
        }
      }
    }
    return devices;
  }

  /// 解析 aplay -l 输出
  static List<AudioOutputDeviceOption> parseAplayList(
    String stdout, {
    Set<String>? seenIds,
  }) {
    final devices = <AudioOutputDeviceOption>[];
    final seen = seenIds ?? <String>{};
    final lines = stdout.split(RegExp(r'[\r\n]+'));
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
        if (seen.add(id)) {
          devices.add(AudioOutputDeviceOption(
            id: id,
            label: 'ALSA: $cardName - $devName (plughw:$cardNum,$devNum)',
          ));
        }
      }
    }
    return devices;
  }

  /// 解析 pactl get-sink-volume 输出
  static int? parsePactlVolume(String stdout) {
    final match = RegExp(r'(\d+)%').firstMatch(stdout);
    if (match != null) {
      final v = int.tryParse(match.group(1)!);
      if (v != null) {
        return v.clamp(0, 150);
      }
    }
    return null;
  }

  /// 解析 amixer sget Master 输出
  static int? parseAmixerVolume(String stdout) {
    final match = RegExp(r'\[(\d+)%\]').firstMatch(stdout);
    if (match != null) {
      final v = int.tryParse(match.group(1)!);
      if (v != null) {
        return v.clamp(0, 150);
      }
    }
    return null;
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
        environment: LinuxAudioEnvironment.buildAudioEnv(),
      ).timeout(const Duration(seconds: 3));
      if (res.exitCode == 0) {
        devices.addAll(parsePactlSources(res.stdout.toString(), seenIds: seenIds));
      }
    } catch (_) {}

    // 2. ALSA hardware capture devices (arecord -l)
    try {
      final res = await Process.run('arecord', ['-l'])
          .timeout(const Duration(seconds: 3));
      if (res.exitCode == 0) {
        devices.addAll(parseArecordList(res.stdout.toString(), seenIds: seenIds));
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
        environment: LinuxAudioEnvironment.buildAudioEnv(),
      ).timeout(const Duration(seconds: 3));
      if (res.exitCode == 0) {
        devices.addAll(parsePactlSinks(res.stdout.toString(), seenIds: seenIds));
      }
    } catch (_) {}

    // 2. ALSA hardware playback devices (aplay -l)
    try {
      final res = await Process.run('aplay', ['-l'])
          .timeout(const Duration(seconds: 3));
      if (res.exitCode == 0) {
        devices.addAll(parseAplayList(res.stdout.toString(), seenIds: seenIds));
      }
    } catch (_) {}

    return devices;
  }

  /// 读取 Linux 服务器当前扬声器音量百分比（0 - 150）
  static Future<int> getOutputVolume({String outputDeviceId = ''}) async {
    if (!Platform.isLinux) return _currentVolumePercent;
    final env = LinuxAudioEnvironment.buildAudioEnv();
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
        final v = parsePactlVolume(res.stdout.toString());
        if (v != null) {
          _currentVolumePercent = v;
          return _currentVolumePercent;
        }
      }
    } catch (_) {}

    try {
      final res = await Process.run('amixer', ['sget', 'Master'])
          .timeout(const Duration(seconds: 2));
      if (res.exitCode == 0) {
        final v = parseAmixerVolume(res.stdout.toString());
        if (v != null) {
          _currentVolumePercent = v;
          return _currentVolumePercent;
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

    final env = LinuxAudioEnvironment.buildAudioEnv();
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
}
