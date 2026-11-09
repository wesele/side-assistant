import 'dart:io';

import 'foundation_bridge.dart';
import 'method_channel_bridge.dart';

/// Android 顶部悬浮胶囊桥接。
///
/// Android 16 上胶囊由系统 Live Update 渲染（`ListeningForegroundService`
/// 的前台通知请求 promoted ongoing + shortCriticalText），Flutter 只负责：
///  - 把工作状态与话筒开关同步给原生侧；
///  - 接收通知操作按钮的回调（拍照问 AI / 话筒开关）。
class FloatingCapsuleService {
  static const PlatformMethodChannel _channel =
      PlatformMethodChannel('com.sideassistant.side_assistant/overlay');

  static bool get isSupported => !kIsWeb && Platform.isAndroid;

  static Future<void> Function(String action)? _actionHandler;

  /// 注册胶囊操作回调（captureAndAsk / toggleMic）。
  ///
  /// 重复调用会覆盖旧回调，方便设置热更新后重新绑定控制器。
  static void setActionHandler(
    Future<void> Function(String action)? handler,
  ) {
    _actionHandler = handler;
    if (!isSupported) return;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'captureAndAsk':
        case 'toggleMic':
          await _actionHandler?.call(call.method);
          return true;
        default:
          return null;
      }
    });

    if (handler != null) {
      _channel.invokeMethod('clientReady').catchError((_) {});
    }
  }

  /// 系统是否允许本应用把通知提升为 Live Update。
  ///
  /// ColorOS 上对应开关是「流体云显示实时活动」，默认关闭。
  static Future<bool> canPostPromoted() async {
    if (!isSupported) return false;
    try {
      return await _channel.invokeMethod<bool>('canPostPromoted') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统「实时活动 / 流体云」授权页。
  static Future<void> requestPromotion() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('requestPromotion');
    } catch (_) {}
  }

  /// 开关悬浮胶囊。开启时原生侧会确保前台服务运行，并在退到后台时
  /// 请求系统把通知提升为 Live Update 状态栏胶囊。
  static Future<void> setEnabled(
    bool enabled, {
    bool micListening = false,
    String status = '待机',
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('setEnabled', {
        'enabled': enabled,
        'micListening': micListening,
        'status': status,
      });
    } catch (_) {}
  }

  /// 同步胶囊状态：左侧图标表达话筒是否监听，右侧短文本（≤2 字）表达工作状态。
  static Future<void> update({
    required String status,
    required bool micListening,
    required bool enabled,
  }) async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('update', {
        'status': status,
        'micListening': micListening,
        'enabled': enabled,
      });
    } catch (_) {}
  }

  static Future<void> hide() async {
    if (!isSupported) return;
    try {
      await _channel.invokeMethod('hide');
    } catch (_) {}
  }
}
