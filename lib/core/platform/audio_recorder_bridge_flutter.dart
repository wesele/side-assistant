import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'audio_recorder_bridge_io.dart'
    show PlatformInputDevice, PlatformAmplitude;
import 'audio_recorder_bridge_io.dart' as io_impl;

export 'audio_recorder_bridge_io.dart'
    show PlatformInputDevice, PlatformAmplitude;

const RecordConfig _asrStreamRecordConfig = RecordConfig(
  encoder: AudioEncoder.pcm16bits,
  sampleRate: 16000,
  numChannels: 1,
  autoGain: true,
  echoCancel: true,
  noiseSuppress: true,
  audioInterruption: AudioInterruptionMode.none,
  streamBufferSize: 8192,
  androidConfig: AndroidRecordConfig(
    audioSource: AndroidAudioSource.voiceCommunication,
  ),
);

const RecordConfig _asrFileRecordConfig = RecordConfig(
  encoder: AudioEncoder.wav,
  sampleRate: 16000,
  numChannels: 1,
  autoGain: true,
  echoCancel: true,
  noiseSuppress: true,
  audioInterruption: AudioInterruptionMode.none,
  androidConfig: AndroidRecordConfig(
    audioSource: AndroidAudioSource.voiceCommunication,
  ),
);

RecordConfig _withInputDevice(RecordConfig base, PlatformInputDevice? device) {
  return RecordConfig(
    encoder: base.encoder,
    bitRate: base.bitRate,
    sampleRate: base.sampleRate,
    numChannels: base.numChannels,
    device:
        device == null ? null : InputDevice(id: device.id, label: device.label),
    autoGain: base.autoGain,
    echoCancel: base.echoCancel,
    noiseSuppress: base.noiseSuppress,
    androidConfig: base.androidConfig,
    iosConfig: base.iosConfig,
    audioInterruption: base.audioInterruption,
    streamBufferSize: base.streamBufferSize,
  );
}

class PlatformAudioRecorder {
  AudioRecorder? _recorder;
  io_impl.PlatformAudioRecorder? _linuxRecorder;

  PlatformAudioRecorder() {
    if (Platform.isLinux) {
      _linuxRecorder = io_impl.PlatformAudioRecorder();
    }
  }

  AudioRecorder _ensureRecorder() {
    if (_recorder != null) return _recorder!;
    runZonedGuarded(() {
      _recorder = AudioRecorder();
    }, (_, __) {});
    return _recorder!;
  }

  int get streamBufferSize => _asrStreamRecordConfig.streamBufferSize ?? 8192;
  String get audioInterruptionName =>
      _asrStreamRecordConfig.audioInterruption.name;

  Future<bool> hasPermission() async {
    if (Platform.isLinux) {
      return _linuxRecorder!.hasPermission();
    }
    try {
      return await _ensureRecorder().hasPermission();
    } catch (_) {
      return false;
    }
  }

  Future<Stream<Uint8List>> startStream({PlatformInputDevice? device}) async {
    if (Platform.isLinux) {
      return _linuxRecorder!.startStream(device: device);
    }
    return _ensureRecorder().startStream(
      _withInputDevice(_asrStreamRecordConfig, device),
    );
  }

  Future<void> startWavFile({
    required String path,
    PlatformInputDevice? device,
  }) async {
    if (Platform.isLinux) {
      await _linuxRecorder!.startWavFile(path: path, device: device);
      return;
    }
    await _ensureRecorder().start(
      _withInputDevice(_asrFileRecordConfig, device),
      path: path,
    );
  }

  Future<bool> isRecording() async {
    if (Platform.isLinux) {
      return _linuxRecorder!.isRecording();
    }
    if (_recorder == null) return false;
    return _recorder!.isRecording();
  }

  Future<String?> stop() async {
    if (Platform.isLinux) {
      return _linuxRecorder!.stop();
    }
    if (_recorder == null) return null;
    return _recorder!.stop();
  }

  Future<PlatformAmplitude> getAmplitude() async {
    if (Platform.isLinux) {
      return _linuxRecorder!.getAmplitude();
    }
    final amp = await _ensureRecorder().getAmplitude();
    return PlatformAmplitude(current: amp.current, max: amp.max);
  }

  void dispose() {
    if (Platform.isLinux) {
      _linuxRecorder!.dispose();
    } else {
      try {
        _recorder?.dispose().catchError((_) {});
      } catch (_) {}
    }
  }
}
