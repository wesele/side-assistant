import 'dart:io';
import 'package:flutter/services.dart';

class ForegroundServiceBridge {
  static const MethodChannel _channel =
      MethodChannel('com.sideassistant.side_assistant/foreground_service');

  /// 启动 Android 前台常驻监听服务与 WakeLock
  static Future<void> start({
    required String title,
    required String content,
  }) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('startForeground', {
        'title': title,
        'content': content,
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
}
