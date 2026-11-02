import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'linux/linux_hardware_adapter.dart';

class PlatformInputDevice {
  final String id;
  final String label;

  const PlatformInputDevice({
    required this.id,
    required this.label,
  });
}

class PlatformAmplitude {
  final double current;
  final double max;
  const PlatformAmplitude({required this.current, required this.max});
}

class PlatformAudioRecorder {
  LinuxMicRecordStream? _activeStream;
  Process? _activeFileProcess;
  String? _activeFilePath;
  bool _recording = false;

  int get streamBufferSize => 8192;
  String get audioInterruptionName => 'none';

  Future<bool> hasPermission() async {
    return true;
  }

  Future<Stream<Uint8List>> startStream({PlatformInputDevice? device}) async {
    await stop();
    final micStream = await LinuxHardwareService.startMicStream(
      deviceId: device?.id ?? '',
      sampleRate: 16000,
      numChannels: 1,
    );
    _activeStream = micStream;
    _recording = true;

    // 保证每个发出的 PCM16 分片字节数为偶数（2 字节对齐），防止管道拆分奇数字节导致采样高低位错位
    final alignedController = StreamController<Uint8List>();
    int? carryByte;

    micStream.stream.listen(
      (chunk) {
        if (chunk.isEmpty || alignedController.isClosed) return;
        Uint8List work;
        if (carryByte != null) {
          work = Uint8List(chunk.length + 1);
          work[0] = carryByte!;
          work.setRange(1, work.length, chunk);
          carryByte = null;
        } else {
          work = chunk;
        }
        if (work.length.isOdd) {
          carryByte = work[work.length - 1];
          if (work.length > 1) {
            alignedController
                .add(Uint8List.sublistView(work, 0, work.length - 1));
          }
        } else {
          alignedController.add(work);
        }
      },
      onError: (Object e, StackTrace st) {
        if (!alignedController.isClosed) alignedController.addError(e, st);
      },
      onDone: () {
        if (!alignedController.isClosed) alignedController.close();
      },
    );

    return alignedController.stream;
  }

  Future<void> startWavFile({
    required String path,
    PlatformInputDevice? device,
  }) async {
    await stop();
    _activeFilePath = path;
    _activeFileProcess = await LinuxHardwareService.startWavFileRecording(
      filePath: path,
      deviceId: device?.id ?? '',
      sampleRate: 16000,
      numChannels: 1,
    );
    _recording = true;
  }

  Future<bool> isRecording() async => _recording;

  Future<String?> stop() async {
    _recording = false;
    if (_activeStream != null) {
      await _activeStream!.stop();
      _activeStream = null;
    }
    final fileProc = _activeFileProcess;
    final filePath = _activeFilePath;
    _activeFileProcess = null;
    _activeFilePath = null;
    if (fileProc != null) {
      try {
        fileProc.kill(ProcessSignal.sigint);
        await fileProc.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          fileProc.kill(ProcessSignal.sigterm);
        } catch (_) {}
      }
      return filePath;
    }
    return null;
  }

  Future<PlatformAmplitude> getAmplitude() async {
    return const PlatformAmplitude(current: -20.0, max: -15.0);
  }

  void dispose() {
    unawaited(stop());
  }
}
