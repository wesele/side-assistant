import 'dart:io';

import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/method_channel_bridge.dart';
import '../linux/linux_hardware_service.dart';

/// 一个可选的录音输入设备（由 Android 原生枚举得到）。
///
/// [id] 与 `record` 插件内部使用的 `AudioDeviceInfo.id` 一致，可直接塞进
/// `RecordConfig.device`；`record` 会把它翻译成 `AudioRecord.setPreferredDevice`。
class AudioInputDeviceOption {
  final String id;
  final String label;
  final bool isBluetooth;
  final int type;

  const AudioInputDeviceOption({
    required this.id,
    required this.label,
    this.isBluetooth = false,
    this.type = 0,
  });

  factory AudioInputDeviceOption.fromMap(Map<dynamic, dynamic> map) {
    return AudioInputDeviceOption(
      id: map['id']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
      isBluetooth: map['bluetooth'] == true,
      type: (map['type'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  String toString() => 'AudioInputDeviceOption($id, $label, bt=$isBluetooth)';
}

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
      return LinuxHardwareService.listInputDevices();
    }
    if (!Platform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('listInputDevices');
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
