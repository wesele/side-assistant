package com.sideassistant.side_assistant

import io.flutter.plugin.common.MethodChannel

/**
 * 原生顶部胶囊（Android 16 Live Update 通知）-> Flutter 的操作通道。
 *
 * MainActivity 在 configureFlutterEngine 时把 MethodChannel 挂到这里；
 * ListeningForegroundService 在通知操作按钮被点击时通过它回调 Dart。
 * Activity 被销毁后 channel 置空，操作会退化为“打开 App”。
 */
object FloatingCapsuleActionBridge {
    @Volatile
    var channel: MethodChannel? = null
}
