/// 设备选项数据模型（音频输入/输出、摄像头）
///
/// 属于基础核心数据模型，供底层平台适配器与领域服务共同引用，破除分层倒置与循环依赖。
class AudioDeviceOption {
  static const String autoId = '';
  final String id;
  final String label;
  final bool isBluetooth;
  final int type;

  const AudioDeviceOption({
    required this.id,
    required this.label,
    this.isBluetooth = false,
    this.type = 0,
  });

  factory AudioDeviceOption.fromMap(Map<dynamic, dynamic> map) {
    return AudioDeviceOption(
      id: map['id']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
      isBluetooth: map['bluetooth'] == true,
      type: (map['type'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
        'bluetooth': isBluetooth,
        'type': type,
      };

  @override
  String toString() => 'AudioDeviceOption($id, $label, bt=$isBluetooth)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioDeviceOption &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          label == other.label &&
          isBluetooth == other.isBluetooth &&
          type == other.type;

  @override
  int get hashCode => Object.hash(id, label, isBluetooth, type);
}

/// 录音输入设备别名（与既有代码保持向后兼容）
typedef AudioInputDeviceOption = AudioDeviceOption;

/// 扬声器音频输出设备
class AudioOutputDeviceOption {
  final String id;
  final String label;

  const AudioOutputDeviceOption({
    required this.id,
    required this.label,
  });

  factory AudioOutputDeviceOption.fromMap(Map<dynamic, dynamic> map) {
    return AudioOutputDeviceOption(
      id: map['id']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
      };

  @override
  String toString() => 'AudioOutputDeviceOption($id, $label)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioOutputDeviceOption &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          label == other.label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// Linux 视频采集设备
class LinuxCameraDeviceOption {
  final String id; // e.g. '/dev/video0'
  final String label;

  const LinuxCameraDeviceOption({
    required this.id,
    required this.label,
  });

  factory LinuxCameraDeviceOption.fromMap(Map<dynamic, dynamic> map) {
    return LinuxCameraDeviceOption(
      id: map['id']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
      };

  @override
  String toString() => 'LinuxCameraDeviceOption($id, $label)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LinuxCameraDeviceOption &&
          runtimeType == other.runtimeType &&
          id == other.id &&
          label == other.label;

  @override
  int get hashCode => Object.hash(id, label);
}

/// 设备真实支持的一档拍照分辨率
class CameraResolution {
  final int width;
  final int height;

  const CameraResolution({required this.width, required this.height});

  double get megapixels => width * height / 1000000;

  String get aspectLabel {
    final ratio = width / height;
    if ((ratio - 4 / 3).abs() < 0.02) return '4:3';
    if ((ratio - 16 / 9).abs() < 0.02) return '16:9';
    if ((ratio - 3 / 2).abs() < 0.02) return '3:2';
    if ((ratio - 16 / 10).abs() < 0.02) return '16:10';
    if ((ratio - 5 / 4).abs() < 0.02) return '5:4';
    if ((ratio - 1.0).abs() < 0.02) return '1:1';
    return '${ratio.toStringAsFixed(2)}:1';
  }

  String get label {
    final mp = megapixels;
    final mpText = mp.toStringAsFixed(1).replaceAll(RegExp(r'\.0$'), '');
    return '$width × $height（$mpText MP · $aspectLabel）';
  }

  String get key => '${width}x$height';

  static CameraResolution? fromKey(String key) {
    final parts = key.split('x');
    if (parts.length != 2) return null;
    final w = int.tryParse(parts[0]);
    final h = int.tryParse(parts[1]);
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return CameraResolution(width: w, height: h);
  }
}

