import '../models/device_options.dart';
import '../platform/linux/linux_hardware_adapter.dart';

/// 宿主声卡与硬件交互端口 (Audio Hardware Port)
///
/// 定义输入设备枚举与系统输出音量控制契约。
abstract interface class AudioHardwarePort {
  Future<List<AudioInputDeviceOption>> listInputDevices();
  Future<void> setOutputVolume(int volume, {String? outputDeviceId});
}

/// 默认系统硬件适配器实现
class DefaultAudioHardwareAdapter implements AudioHardwarePort {
  const DefaultAudioHardwareAdapter();

  @override
  Future<List<AudioInputDeviceOption>> listInputDevices() =>
      LinuxHardwareAdapter.listInputDevices();

  @override
  Future<void> setOutputVolume(int volume, {String? outputDeviceId}) =>
      LinuxHardwareAdapter.setOutputVolume(
        volume,
        outputDeviceId: outputDeviceId ?? '',
      );
}

/// 音频硬件服务 SPI 注册表
class AudioHardwareRegistry {
  static Future<List<AudioInputDeviceOption>> Function()? defaultInputDeviceLister;
}

