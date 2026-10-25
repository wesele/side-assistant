import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../../services/linux/linux_hardware_service.dart';
import '../models/app_settings.dart';

class PlatformSoundPlayer {
  String outputDeviceId;
  LinuxPlaybackHandle? _activeHandle;

  PlatformSoundPlayer({this.outputDeviceId = ''});

  Future<void> playWavBytes(Uint8List wav, {String tag = 'tone'}) async {
    if (!Platform.isLinux) return;
    try {
      await _activeHandle?.stop();
      _activeHandle = await LinuxHardwareService.playWavBytes(
        wav,
        outputDeviceId: outputDeviceId,
        tag: tag,
      );
    } catch (_) {}
  }

  void dispose() {
    _activeHandle?.stop();
    _activeHandle = null;
  }
}

class PlatformTtsBackend {
  final AppSettings settings;
  LinuxPlaybackHandle? _activeHandle;

  PlatformTtsBackend({required this.settings});

  Future<void> init() async {}

  Future<void> playAudioFile(String filePath, {Duration? timeout}) async {
    if (!Platform.isLinux) return;
    await _activeHandle?.stop();
    final handle = await LinuxHardwareService.playAudioFile(
      filePath,
      outputDeviceId: settings.audioOutputDeviceId,
    );
    _activeHandle = handle;
    if (timeout != null) {
      await handle.done.timeout(timeout, onTimeout: () {
        handle.stop();
      });
    } else {
      await handle.done;
    }
  }

  Future<void> speakSystemTts(String sentence, {Duration? timeout}) async {
    if (!Platform.isLinux) return;
    await _activeHandle?.stop();
    final handle = await LinuxHardwareService.speakSystemTts(
      sentence,
      speed: settings.ttsSpeed,
      outputDeviceId: settings.audioOutputDeviceId,
    );
    _activeHandle = handle;
    if (handle != null) {
      if (timeout != null) {
        await handle.done.timeout(timeout, onTimeout: () {
          handle.stop();
        });
      } else {
        await handle.done;
      }
    }
  }

  Future<void> stop() async {
    final handle = _activeHandle;
    _activeHandle = null;
    if (handle != null) {
      await handle.stop();
    }
  }

  void dispose() {
    unawaited(stop());
  }
}
