import 'device_options.dart';

/// 当前生效录音输入设备的物理类型。
///
/// 用于在主界面 / Web 控制台的话筒图标上区分「内置麦克风」与「蓝牙麦克风」，
/// 同时作为声纹模板声学域分组的判据（见 [speakerDomainFor]）。
enum AudioInputDeviceKind {
  builtIn,
  bluetooth,
  external,
  unknown,
}

/// 声纹模板的声学域标签。
///
/// 宽带（16k 内置麦克风）与窄带（8k 蓝牙 HFP）模板不能混在一个质心里比对，
/// 否则本人分数被压低、异人分数被抬高。旧版本未打标签的模板一律按宽带处理。
const String speakerDomainWideband = 'wideband';
const String speakerDomainNarrowband = 'narrowband';

/// 依据设备标签 / id 判定音源类型。
///
/// [label] 优先（它是「当前实际生效」的设备描述），无法判定时再回退 [id]
/// （配置里的设备 id，可能为空或已失效）。判定只用字符串特征，不依赖平台通道，
/// 因此纯 Dart 的 Linux 无头服务与 Flutter UI 可以共用同一套结果。
AudioInputDeviceKind classifyAudioInputDevice(
  String? label, {
  String? id,
}) {
  final fromLabel = _classifyOne(label);
  if (fromLabel != AudioInputDeviceKind.unknown) return fromLabel;
  return _classifyOne(id);
}

AudioInputDeviceKind _classifyOne(String? raw) {
  if (raw == null || raw.trim().isEmpty) return AudioInputDeviceKind.unknown;
  final s = raw.toLowerCase();

  // 蓝牙优先：HFP/CVSD 窄带链路与 mSBC 宽带链路都算蓝牙。
  if (s.contains('bluez') ||
      s.contains('bluetooth') ||
      s.contains('ble_headset') ||
      s.contains('bt_headset') ||
      s.contains('type_bluetooth') ||
      s.contains('sco') ||
      s.contains('hfp') ||
      s.contains('蓝牙')) {
    return AudioInputDeviceKind.bluetooth;
  }

  // 内置：主板声卡 / 平台内置麦 / Android TYPE_BUILTIN_MIC。
  if (s.contains('alsa_input.pci') ||
      s.contains('alsa_input.platform') ||
      s.contains('builtin') ||
      s.contains('built-in') ||
      s.contains('internal mic') ||
      s.contains('hda intel') ||
      s.contains('analog-stereo') ||
      s.contains('plughw:0,0') ||
      s.contains('内置') ||
      s.contains('内建')) {
    return AudioInputDeviceKind.builtIn;
  }

  // 其它外接：USB 声卡、有线耳机、其它 plughw 设备。
  if (s.contains('usb') ||
      s.contains('external') ||
      s.contains('headset') ||
      s.contains('plughw:') ||
      s.contains('外接') ||
      s.contains('有线')) {
    return AudioInputDeviceKind.external;
  }
  return AudioInputDeviceKind.unknown;
}

/// 稳定机器可读名称（写入 SSE / REST payload）。
String audioInputDeviceKindName(AudioInputDeviceKind kind) => switch (kind) {
      AudioInputDeviceKind.builtIn => 'builtIn',
      AudioInputDeviceKind.bluetooth => 'bluetooth',
      AudioInputDeviceKind.external => 'external',
      AudioInputDeviceKind.unknown => 'unknown',
    };

/// 供 tooltip / 徽标使用的人类可读名称。
String audioInputDeviceKindLabel(AudioInputDeviceKind kind) => switch (kind) {
      AudioInputDeviceKind.builtIn => '内置麦克风',
      AudioInputDeviceKind.bluetooth => '蓝牙麦克风',
      AudioInputDeviceKind.external => '外接麦克风',
      AudioInputDeviceKind.unknown => '未知音源',
    };

/// 由 [AudioDeviceOption] 枚举结果判定类型（供设备列表复用）。
AudioInputDeviceKind classifyAudioDeviceOption(AudioDeviceOption option) {
  if (option.isBluetooth) return AudioInputDeviceKind.bluetooth;
  return classifyAudioInputDevice(option.label, id: option.id);
}

/// 当前音频应归属的声学域。
///
/// 蓝牙音源一律按窄带处理；普通音源若信号本身带有 SCO 丢包指纹
/// （[narrowbandSignal]），同样归入窄带，避免设备标签滞后导致模板错配。
String speakerDomainFor({
  String? deviceLabel,
  String? deviceId,
  bool narrowbandSignal = false,
}) {
  final kind = classifyAudioInputDevice(deviceLabel, id: deviceId);
  if (kind == AudioInputDeviceKind.bluetooth || narrowbandSignal) {
    return speakerDomainNarrowband;
  }
  return speakerDomainWideband;
}
