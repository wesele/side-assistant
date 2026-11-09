package com.sideassistant.side_assistant

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel

/**
 * 原生（顶部胶囊 / 桌面组件）-> Flutter 的操作通道。
 *
 * MainActivity 在 configureFlutterEngine 时把 MethodChannel 挂到这里；
 * ListeningForegroundService 与 MicToggleWidgetProvider 在触发操作时通过它回调 Dart。
 * Activity 被销毁后 channel 置空。
 */
object FloatingCapsuleActionBridge {
    @Volatile
    var channel: MethodChannel? = null
        set(value) {
            field = value
            if (value == null) {
                isDartReady = false
            }
        }

    @Volatile
    var isDartReady: Boolean = false
        private set

    @Volatile
    private var pendingAction: String? = null

    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    fun isEngineAlive(): Boolean = channel != null

    fun sendAction(action: String): Boolean {
        val ch = channel ?: return false
        mainHandler.post {
            try {
                ch.invokeMethod(action, null)
            } catch (_: Exception) {}
        }
        return true
    }

    fun queuePendingAction(action: String) {
        pendingAction = action
    }

    fun queueOrSendAction(action: String) {
        if (channel != null && isDartReady) {
            sendAction(action)
        } else {
            queuePendingAction(action)
        }
    }

    fun onDartReady() {
        isDartReady = true
        flushPendingAction()
    }

    fun flushPendingAction() {
        val action = pendingAction ?: return
        val ch = channel ?: return
        if (!isDartReady) return
        pendingAction = null
        mainHandler.post {
            try {
                ch.invokeMethod(action, null)
            } catch (_: Exception) {}
        }
    }
}
