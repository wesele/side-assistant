import 'dart:io';

import '../../core/models/device_options.dart';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/linux/linux_hardware_adapter.dart';
import '../../core/platform/method_channel_bridge.dart';

export '../../core/models/device_options.dart';

/// 录音输入设备枚举。
///
/// 为什么不用 `AudioRecorder.listInputDevices()`：`record_android` 生成设备名时
/// 会拼接 `AudioDeviceInfo.getAddress()`，而 Android 12+ 读取蓝牙设备地址需要
/// `BLUETOOTH_CONNECT` 运行时权限，连接蓝牙耳机的场景下会直接抛
/// SecurityException，导致整个设备列表拿不到。这里改走自己的原生方法通道，
/// 只读 type / productName，不碰 address。
class AudioInputDeviceService {
  AudioInputDeviceService._();

  static const PlatformMethodChannel _channel =
      PlatformMethodChannel('com.sideassistant.side_assistant/audio_devices');

  /// “自动（系统默认）”的保留 id。
  static const String autoId = '';

  /// 枚举当前可用的录音输入设备；Android 走原生通道，Linux 走系统音频枚举。
  static Future<List<AudioInputDeviceOption>> listInputDevices() async {
    if (Platform.isLinux) {
      return LinuxHardwareAdapter.listInputDevices();
    }
    if (!Platform.isAndroid) return const [];
    try {
      final raw =
          await _channel.invokeMethod<List<dynamic>>('listInputDevices');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map(AudioInputDeviceOption.fromMap)
          .where((d) => d.id.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('[AudioInputDeviceService] 枚举录音设备失败: $e');
      return const [];
    }
  }
}
