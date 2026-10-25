import 'dart:io';
import '../../core/platform/foundation_bridge.dart';
import '../../core/platform/method_channel_bridge.dart';

/// Android 原生（CameraX）抓拍结果。
class AndroidCameraCapture {
  final Uint8List bytes;
  final String path;

  const AndroidCameraCapture({required this.bytes, required this.path});
}

/// 设备真实支持的一档拍照分辨率。
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

/// 通过 MethodChannel 调用 [BackgroundCameraController]（原生 CameraX）。
///
/// 与 `camera` 插件不同，这里的会话不绑定 Activity 生命周期，因此 App 退到
/// 后台后仍然可以打开并使用系统摄像头（前提是前台服务申报了 camera 类型
/// 且已获得 CAMERA 权限）。
class AndroidCameraBridge {
  static const PlatformMethodChannel _channel =
      PlatformMethodChannel('com.sideassistant.side_assistant/camera');

  static const Duration _permissionTimeout = Duration(seconds: 30);
  static const Duration _openTimeout = Duration(seconds: 20);
  static const Duration _captureTimeout = Duration(seconds: 20);

  static bool get isSupported => Platform.isAndroid;

  static Future<bool> hasPermission() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 请求相机权限；若已授权或不再弹窗则返回当前授权状态。
  static Future<bool> requestPermission() async {
    if (!isSupported) return false;
    try {
      final granted =
          await _channel.invokeMethod<bool>('requestPermission').timeout(_permissionTimeout);
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 读取目标镜头真实支持的全部 JPEG 拍照档位（按像素从大到小排序）。
  static Future<List<CameraResolution>> getSupportedResolutions({
    String lensDirection = 'back',
  }) async {
    if (!isSupported) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>(
        'getSupportedResolutions',
        {'lensDirection': lensDirection},
      ).timeout(_openTimeout);
      if (raw == null) return const [];

      final result = <CameraResolution>[];
      final seen = <String>{};
      for (final item in raw) {
        if (item is! Map) continue;
        final width = (item['width'] as num?)?.toInt() ?? 0;
        final height = (item['height'] as num?)?.toInt() ?? 0;
        if (width <= 0 || height <= 0) continue;
        final resolution = CameraResolution(width: width, height: height);
        if (seen.add(resolution.key)) result.add(resolution);
      }
      return result;
    } catch (e) {
      debugPrint('[AndroidCameraBridge] 读取摄像头支持分辨率失败: $e');
      return const [];
    }
  }

  /// 打开（并保持在后台可用）系统摄像头。
  ///
  /// [targetWidth]/[targetHeight] 传 0 表示自动（按 1600×1200 就近选档）。
  static Future<bool> open({
    String lensDirection = 'back',
    int targetWidth = 0,
    int targetHeight = 0,
  }) async {
    if (!isSupported) return false;
    // 前台兜底：如果还没授权（例如用文字触发视觉意图），先请求一次。
    if (!await hasPermission()) {
      final granted = await requestPermission();
      if (!granted) return false;
    }
    try {
      final ok = await _channel.invokeMethod<bool>('open', {
        'lensDirection': lensDirection,
        if (targetWidth > 0 && targetHeight > 0) 'targetWidth': targetWidth,
        if (targetWidth > 0 && targetHeight > 0) 'targetHeight': targetHeight,
      }).timeout(_openTimeout);
      return ok ?? false;
    } catch (e) {
      debugPrint('[AndroidCameraBridge] 打开相机失败: $e');
      return false;
    }
  }

  /// 抓拍一张 JPEG。
  ///
  /// [sendShortEdge] > 0 时，原生侧会把返回的字节按短边缩放到该值（原图文件保持不变），
  /// 用于降低发送给视觉模型的延迟。
  static Future<AndroidCameraCapture> capturePhoto({int sendShortEdge = 0}) async {
    final raw = await _channel
        .invokeMethod<Map<dynamic, dynamic>>(
          'capturePhoto',
          {if (sendShortEdge > 0) 'sendShortEdge': sendShortEdge},
        )
        .timeout(_captureTimeout);
    final bytes = raw?['bytes'];
    final path = raw?['path'] as String? ?? '';
    if (bytes is! Uint8List || bytes.isEmpty) {
      throw Exception('Android 相机未返回有效图像数据');
    }
    return AndroidCameraCapture(bytes: bytes, path: path);
  }

  static Future<void> close() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('close').timeout(const Duration(seconds: 5));
    } catch (_) {}
  }

  /// 打开本应用在系统设置里的详情页（用于手动授予相机权限）。
  static Future<void> openAppSettings() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('openAppSettings').timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}
