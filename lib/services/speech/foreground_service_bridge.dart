import 'dart:io';
import '../../core/platform/method_channel_bridge.dart';

class ForegroundServiceBridge {
  static const PlatformMethodChannel _channel = PlatformMethodChannel(
      'com.sideassistant.side_assistant/foreground_service');

  static const PlatformMethodChannel _cameraChannel =
      PlatformMethodChannel('com.sideassistant.side_assistant/camera');

  /// 启动 Android 前台常驻监听服务与 WakeLock。
  ///
  /// 会顺带确保 CAMERA 权限：拿到权限时前台服务同时申报 camera 类型，
  /// 这样 App 退到后台后仍可用系统摄像头拍照；拿不到则只申报 microphone 类型。
  static Future<void> start({
    required String title,
    required String content,
    bool micListening = true,
    bool capsuleEnabled = false,
    String status = '待机',
  }) async {
    if (!Platform.isAndroid) return;
    final enableCamera = await _ensureCameraPermission();
    try {
      await _channel.invokeMethod('startForeground', {
        'title': title,
        'content': content,
        'enableCamera': enableCamera,
        'micListening': micListening,
        'capsuleEnabled': capsuleEnabled,
        'status': status,
      });
    } catch (_) {}
  }

  /// 话筒开始/停止监听，但服务可能因悬浮胶囊继续保留。
  static Future<void> setMicActive(
    bool active, {
    bool capsuleEnabled = false,
    String status = '待机',
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('setMicActive', {
        'active': active,
        'capsuleEnabled': capsuleEnabled,
        'status': status,
      });
    } catch (_) {}
  }

  /// 动态更新前台服务通知栏文本
  static Future<void> update({
    required String title,
    required String content,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('updateNotification', {
        'title': title,
        'content': content,
      });
    } catch (_) {}
  }

  /// 停止 Android 前台常驻服务并释放 WakeLock
  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('stopForeground');
    } catch (_) {}
  }

  static Future<bool> _ensureCameraPermission() async {
    try {
      final has =
          await _cameraChannel.invokeMethod<bool>('hasPermission') ?? false;
      if (has) return true;
      final granted = await _cameraChannel
          .invokeMethod<bool>('requestPermission')
          .timeout(const Duration(seconds: 30));
      return granted ?? false;
    } catch (_) {
      return false;
    }
  }
}
