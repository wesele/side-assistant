import '../../../core/platform/audio_recorder_bridge.dart';
import '../../../core/platform/foundation_bridge.dart';
import '../audio_input_device_service.dart';

/// 录音输入设备的解析与麦克风权限查询。
///
/// 职责边界：
/// - 维护“本次采集实际使用的录音设备”状态（null = 自动/系统默认）与 UI 文案；
/// - 把设置里的设备 id 解析成可用设备：设备已断开（蓝牙耳机摘掉、换机后 id 变化）
///   时回退系统默认，避免把不存在的设备塞给 AudioRecord 导致录音直接失败；
/// - 查询麦克风权限。
///
/// 不负责：采集流的建立/重建/看门狗（那属于 `VoiceListeningService` 的时序逻辑）。
class InputDeviceResolver {
  InputDeviceResolver({
    required this.recorder,
    Future<List<AudioInputDeviceOption>> Function()? listDevices,
  }) : _listDevices = listDevices ?? AudioInputDeviceService.listInputDevices;

  final PlatformAudioRecorder recorder;
  final Future<List<AudioInputDeviceOption>> Function() _listDevices;

  PlatformInputDevice? _active;

  /// 当前实际使用的录音设备（null = 自动/系统默认）。
  PlatformInputDevice? get active => _active;

  /// 供 UI / 调试用的设备描述。
  String get label => _active?.label ?? '自动（系统默认）';

  /// 检查麦克风权限（异常一律视为无权限）。
  Future<bool> hasPermission() async {
    try {
      return await recorder.hasPermission();
    } catch (_) {
      return false;
    }
  }

  /// 按设置中的设备 id 解析要使用的录音设备，并缓存结果。
  ///
  /// - 设置为空 → null，交给系统自动选择（兼容性最好，推荐默认）。
  /// - 设备不在当前列表 → 回退自动。
  Future<void> resolve(String configuredId) async {
    final id = configuredId.trim();
    if (id.isEmpty) {
      _active = null;
      return;
    }
    final options = await _listDevices();
    for (final option in options) {
      if (option.id == id) {
        _active = PlatformInputDevice(id: option.id, label: option.label);
        return;
      }
    }
    debugPrint('[VoiceListeningService] 设置的录音设备不可用 (id=$id)，回退系统默认');
    _active = null;
  }
}
