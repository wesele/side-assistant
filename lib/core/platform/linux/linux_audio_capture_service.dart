import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../foundation_bridge.dart';
import 'linux_audio_env.dart';

/// Linux 麦克风录音进程与数据流包装类
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

/// Linux 麦克风音频采集服务：
/// - 基于 parec (PipeWire/Pulse) 或 arecord (ALSA) 进行 16kHz 16-bit 单声道流式录音
/// - 支持录制 WAV 文件至指定磁盘路径
class LinuxAudioCaptureService {
  LinuxAudioCaptureService._();

  /// 启动 16kHz 16-bit 单声道 PCM 麦克风实时流
  static Future<LinuxMicRecordStream> startMicStream({
    String deviceId = '',
    int sampleRate = 16000,
    int numChannels = 1,
  }) async {
    final env = LinuxAudioEnvironment.buildAudioEnv();
    String executable = 'arecord';
    List<String> args;

    final usePulse = deviceId.startsWith('pulse:') ||
        (!deviceId.startsWith('alsa:') && deviceId.contains('_input.'));
    if (usePulse) {
      final sourceName = deviceId.startsWith('pulse:')
          ? deviceId.substring('pulse:'.length)
          : deviceId;
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
    final env = LinuxAudioEnvironment.buildAudioEnv();
    final alsaDev =
        deviceId.startsWith('alsa:') ? deviceId.substring('alsa:'.length) : '';

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
}
