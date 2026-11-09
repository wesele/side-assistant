package com.sideassistant.side_assistant

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import android.view.View
import android.widget.RemoteViews

/**
 * 1x1 语音监听桌面快捷开关小部件。
 *
 * 视觉风格对齐 Android / HyperOS 主屏幕图标规范（Squircle 圆角矩形 + 底部标签），
 * 包含 App 存活状态指示器（右上角绿点在线 / 灰点离线）与麦克风监听状态切换。
 *
 * 点击逻辑（兼顾 Android 12+ 广播启动 Activity 限制与后台无感切换）：
 *  - 引擎在线时（Flutter 与原生通道存活）：通过 Broadcast PendingIntent 触发
 *    MicToggleWidgetProvider.onReceive，直接在后台通过 FloatingCapsuleActionBridge
 *    派发 'toggleMic' 事件，无需拉起主界面；
 *  - 引擎离线时（冷启动或进程被杀）：直接生成指向 MainActivity 的 Activity
 *    PendingIntent，由 Launcher 以前台交互身份拉起主界面（彻底绕过 Android 12+
 *    trampoline 限制），并携带 EXTRA_PENDING_ACTION，待 Dart 端注册就绪后补发。
 */
class MicToggleWidgetProvider : AppWidgetProvider() {

    enum class WidgetState {
        ALIVE_LISTENING,
        ALIVE_STANDBY,
        OFFLINE
    }

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray
    ) {
        super.onUpdate(context, appWidgetManager, appWidgetIds)
        val state = resolveCurrentState(context)
        for (appWidgetId in appWidgetIds) {
            updateWidget(context, appWidgetManager, appWidgetId, state)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action == ACTION_TOGGLE_MIC) {
            handleToggle(context)
        }
    }

    private fun handleToggle(context: Context) {
        if (FloatingCapsuleActionBridge.isEngineAlive()) {
            FloatingCapsuleActionBridge.sendAction("toggleMic")
        } else {
            FloatingCapsuleActionBridge.queuePendingAction("toggleMic")
            try {
                val launchIntent = Intent(context, MainActivity::class.java).apply {
                    action = ACTION_WIDGET_TOGGLE_MIC
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra(EXTRA_PENDING_ACTION, "toggleMic")
                }
                context.startActivity(launchIntent)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to start MainActivity from widget broadcast: ${e.message}")
            }
            updateAll(context)
        }
    }

    companion object {
        private const val TAG = "MicToggleWidget"
        const val PREFS_NAME = "mic_widget_prefs"
        const val PREF_KEY_LISTENING = "listening"

        const val ACTION_TOGGLE_MIC = "com.sideassistant.side_assistant.ACTION_TOGGLE_MIC"
        const val ACTION_WIDGET_TOGGLE_MIC = "com.sideassistant.side_assistant.ACTION_WIDGET_TOGGLE_MIC"
        const val EXTRA_PENDING_ACTION = "extra_pending_action"

        private const val REQUEST_CODE_TOGGLE_BROADCAST = 2001
        private const val REQUEST_CODE_TOGGLE_ACTIVITY = 2002

        fun isAppAlive(): Boolean {
            return FloatingCapsuleActionBridge.isEngineAlive() || ListeningForegroundService.isRunning
        }

        fun getPersistedListening(context: Context): Boolean {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            if (!ListeningForegroundService.isRunning) {
                if (prefs.getBoolean(PREF_KEY_LISTENING, false)) {
                    prefs.edit().putBoolean(PREF_KEY_LISTENING, false).apply()
                }
                return false
            }
            return prefs.getBoolean(PREF_KEY_LISTENING, false)
        }

        fun resolveCurrentState(context: Context, listening: Boolean? = null): WidgetState {
            if (!isAppAlive()) {
                return WidgetState.OFFLINE
            }
            val isListening = listening ?: getPersistedListening(context)
            return if (isListening) WidgetState.ALIVE_LISTENING else WidgetState.ALIVE_STANDBY
        }

        fun updateAll(context: Context, listening: Boolean? = null) {
            val isListening = if (listening != null) {
                context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(PREF_KEY_LISTENING, listening)
                    .apply()
                listening
            } else {
                getPersistedListening(context)
            }

            val state = resolveCurrentState(context, isListening)

            val appWidgetManager = AppWidgetManager.getInstance(context) ?: return
            val componentName = ComponentName(context, MicToggleWidgetProvider::class.java)
            val appWidgetIds = try {
                appWidgetManager.getAppWidgetIds(componentName)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to get widget ids: ${e.message}")
                return
            }
            if (appWidgetIds == null || appWidgetIds.isEmpty()) return

            for (appWidgetId in appWidgetIds) {
                updateWidget(context, appWidgetManager, appWidgetId, state)
            }
        }

        fun updateWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int,
            state: WidgetState
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_mic_toggle)

            when (state) {
                WidgetState.ALIVE_LISTENING -> {
                    views.setViewVisibility(R.id.widget_mic_halo, View.VISIBLE)
                    views.setImageViewResource(R.id.widget_mic_icon, R.drawable.ic_widget_mic_active)
                    views.setImageViewResource(R.id.widget_light_bar, R.drawable.widget_bar_alive)
                    views.setContentDescription(
                        R.id.widget_mic_toggle_root,
                        context.getString(R.string.widget_mic_toggle_on)
                    )
                }
                WidgetState.ALIVE_STANDBY -> {
                    views.setViewVisibility(R.id.widget_mic_halo, View.GONE)
                    views.setImageViewResource(R.id.widget_mic_icon, R.drawable.ic_widget_mic_inactive)
                    views.setImageViewResource(R.id.widget_light_bar, R.drawable.widget_bar_alive)
                    views.setContentDescription(
                        R.id.widget_mic_toggle_root,
                        context.getString(R.string.widget_mic_toggle_off)
                    )
                }
                WidgetState.OFFLINE -> {
                    views.setViewVisibility(R.id.widget_mic_halo, View.GONE)
                    views.setImageViewResource(R.id.widget_mic_icon, R.drawable.ic_widget_mic_dead)
                    views.setImageViewResource(R.id.widget_light_bar, R.drawable.widget_bar_offline)
                    views.setContentDescription(
                        R.id.widget_mic_toggle_root,
                        context.getString(R.string.widget_mic_toggle_offline)
                    )
                }
            }

            val pendingIntent = if (FloatingCapsuleActionBridge.isEngineAlive()) {
                val intent = Intent(context, MicToggleWidgetProvider::class.java).apply {
                    action = ACTION_TOGGLE_MIC
                }
                PendingIntent.getBroadcast(
                    context,
                    REQUEST_CODE_TOGGLE_BROADCAST,
                    intent,
                    pendingIntentFlags()
                )
            } else {
                val intent = Intent(context, MainActivity::class.java).apply {
                    action = ACTION_WIDGET_TOGGLE_MIC
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                    putExtra(EXTRA_PENDING_ACTION, "toggleMic")
                }
                PendingIntent.getActivity(
                    context,
                    REQUEST_CODE_TOGGLE_ACTIVITY,
                    intent,
                    pendingIntentFlags()
                )
            }

            views.setOnClickPendingIntent(R.id.widget_mic_toggle_root, pendingIntent)
            appWidgetManager.updateAppWidget(appWidgetId, views)
        }

        private fun pendingIntentFlags(): Int {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        }
    }
}
