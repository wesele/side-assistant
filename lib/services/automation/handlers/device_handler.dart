import 'base_handler.dart';
import '../http_router.dart';
import '../request_context.dart';
import '../../speech/audio_input_device_service.dart';
import '../../../core/platform/linux/linux_hardware_adapter.dart';

/// 硬件外设与音量控制处理器：
/// - GET /api/hardware-devices: 枚举输入、输出、摄像头外设列表
/// - GET /audio-devices: 枚举录音输入设备状态与配置
/// - POST /audio-device: 切换当前音频录音输入设备
/// - POST /api/volume: 调节系统扬声器播放音量 (0 - 150)
class DeviceHandler extends BaseHandler {
  DeviceHandler(super.driverPort);

  @override
  void registerRoutes(HttpRouter router) {
    router.get('/api/hardware-devices', handleHardwareDevices);
    router.get('/audio-devices', handleListAudioDevices);
    router.post('/audio-device', handleSetAudioDevice);
    router.post('/api/volume', handleSetVolume);
  }

  Future<void> handleHardwareDevices(RequestContext ctx) async {
    final inputDevices = await AudioInputDeviceService.listInputDevices();
    final outputDevices = await LinuxHardwareService.listOutputDevices();
    final cameraDevices = await LinuxHardwareService.listCameraDevices();
    ctx.sendJson({
      'inputDevices': inputDevices
          .map((d) => {
                'id': d.id,
                'label': d.label,
                'bluetooth': d.isBluetooth,
                'type': d.type,
              })
          .toList(),
      'outputDevices': outputDevices.map((d) => d.toMap()).toList(),
      'cameraDevices': cameraDevices.map((d) => d.toMap()).toList(),
    });
  }

  Future<void> handleListAudioDevices(RequestContext ctx) async {
    final devices = await AudioInputDeviceService.listInputDevices();
    ctx.sendJson({
      'configuredId': driverPort.settings.audioInputDeviceId,
      'configuredLabel': driverPort.settings.audioInputDeviceLabel,
      'activeLabel': driverPort.activeAudioInputDeviceLabel,
      'isListening': driverPort.isMicListening,
      'devices': devices
          .map((d) => {
                'id': d.id,
                'label': d.label,
                'bluetooth': d.isBluetooth,
                'type': d.type,
              })
          .toList(),
    });
  }

  Future<void> handleSetAudioDevice(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final id = (map['id'] as String?)?.trim() ?? '';
    var label = (map['label'] as String?)?.trim() ?? '';
    if (label.isEmpty && id.isNotEmpty) {
      final devices = await AudioInputDeviceService.listInputDevices();
      for (final d in devices) {
        if (d.id == id) {
          label = d.label;
          break;
        }
      }
    }
    await driverPort.setAudioInputDevice(id, label);
    ctx.sendJson({
      'accepted': true,
      'configuredId': driverPort.settings.audioInputDeviceId,
      'configuredLabel': driverPort.settings.audioInputDeviceLabel,
      'activeLabel': driverPort.activeAudioInputDeviceLabel,
      'isListening': driverPort.isMicListening,
    });
  }

  Future<void> handleSetVolume(RequestContext ctx) async {
    final map = await ctx.readJsonMap();
    final vol = (map['volume'] as num?)?.toInt() ??
        driverPort.settings.playbackVolume;
    await driverPort.setPlaybackVolume(vol);
    ctx.sendJson({
      'accepted': true,
      'playbackVolume': driverPort.settings.playbackVolume,
    });
  }
}
