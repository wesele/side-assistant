package com.sideassistant.side_assistant

import android.Manifest
import android.app.ActivityManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.widget.Toast
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class ListeningForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null

    /** 话筒是否正在监听（决定前台服务类型与 WakeLock）。 */
    private var micListening = true

    /** 用户是否开启了顶部悬浮胶囊（Android 16 上由系统 Live Update 渲染）。 */
    private var capsuleEnabled = false

    /** App 是否在前台；胶囊只在最小化时显示。 */
    private var appForeground = true

    /** 胶囊右侧短状态（最多两个汉字），同时作为 Live Update 状态栏 chip 的 shortCriticalText。 */
    private var statusText = "待机"

    private var foregroundStarted = false

    /** 最近一次通知标题/内容，用于状态变化时重新构建通知。 */
    private var lastNotificationTitle = "随身智能助理"
    private var lastNotificationContent = ""

    companion object {
        const val CHANNEL_ID = "side_assistant_live_channel"
        const val CHANNEL_NAME = "随身智能助理实时状态"
        const val NOTIFICATION_ID = 1001

        const val ACTION_START = "ACTION_START"
        const val ACTION_UPDATE = "ACTION_UPDATE"
        const val ACTION_STOP = "ACTION_STOP"
        const val ACTION_SET_MIC_ACTIVE = "ACTION_SET_MIC_ACTIVE"
        const val ACTION_SET_CAPSULE_ENABLED = "ACTION_SET_CAPSULE_ENABLED"
        const val ACTION_APP_FOREGROUND = "ACTION_APP_FOREGROUND"
        const val ACTION_APP_BACKGROUND = "ACTION_APP_BACKGROUND"

        /** 通知展开后的操作按钮（Live Update 不允许自定义视图，只能用通知 Action）。 */
        const val ACTION_CAPSULE_CAPTURE = "ACTION_CAPSULE_CAPTURE"
        const val ACTION_CAPSULE_TOGGLE_MIC = "ACTION_CAPSULE_TOGGLE_MIC"
        const val ACTION_CAPSULE_OPEN_APP = "ACTION_CAPSULE_OPEN_APP"
        const val ACTION_CAPSULE_EXIT = "ACTION_CAPSULE_EXIT"

        /** 与 Flutter 侧 FloatingCapsuleService 约定的方法名。 */
        const val CAPSULE_ACTION_CAPTURE = "captureAndAsk"
        const val CAPSULE_ACTION_TOGGLE_MIC = "toggleMic"
        const val CAPSULE_ACTION_OPEN_APP = "openApp"

        const val EXTRA_TITLE = "EXTRA_TITLE"
        const val EXTRA_CONTENT = "EXTRA_CONTENT"
        const val EXTRA_ENABLE_CAMERA = "EXTRA_ENABLE_CAMERA"
        const val EXTRA_MIC_LISTENING = "EXTRA_MIC_LISTENING"
        const val EXTRA_CAPSULE_ENABLED = "EXTRA_CAPSULE_ENABLED"
        const val EXTRA_STATUS = "EXTRA_STATUS"
        const val EXTRA_ACTIVE = "EXTRA_ACTIVE"
        const val EXTRA_FOREGROUND = "EXTRA_FOREGROUND"

        const val PREFS_NAME = "side_assistant"
        const val PREF_CAPSULE_ENABLED = "floating_capsule_enabled"

        /** Android 16 Live Update 状态栏 chip 的短文本 extra。 */
        const val EXTRA_SHORT_CRITICAL_TEXT = "android.shortCriticalText"

        /** Android 16 Live Update 的“请求提升为常驻胶囊”extra。 */
        const val EXTRA_REQUEST_PROMOTED_ONGOING = "android.requestPromotedOngoing"

        @Volatile
        var isRunning: Boolean = false
            private set
    }

    /** 是否同时申报 camera 类型，允许退到后台后继续使用系统摄像头。 */
    private var enableCamera = false

    override fun onCreate() {
        super.onCreate()
        isRunning = true
        createNotificationChannel()
        capsuleEnabled = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(PREF_CAPSULE_ENABLED, false)
        appForeground = isAppForegroundNow()
    }

    private fun isAppForegroundNow(): Boolean {
        return try {
            val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val info = ActivityManager.RunningAppProcessInfo()
            ActivityManager.getMyMemoryState(info)
            info.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_VISIBLE
        } catch (_: Exception) {
            true
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // 系统重启服务时 intent 可能为 null：默认按“话筒关闭、仅胶囊”处理，
        // 避免在没有 Flutter 引擎时误报话筒正在录音。
        if (intent == null) {
            micListening = false
            statusText = "待机"
            startForegroundWithNotification("随身助理悬浮胶囊", "话筒已关闭")
            updateCapsuleVisibility()
            if (!capsuleEnabled) {
                stopSelf()
                return START_NOT_STICKY
            }
            return START_STICKY
        }

        when (intent.action ?: ACTION_START) {
            ACTION_STOP -> {
                releaseWakeLock()
                // 若此前由 startForegroundService() 启动但尚未完成 startForeground()，
                // 在 stopSelf() 前必须先补调一次 startForeground()，否则 Android 14+ 会抛出
                // ForegroundServiceDidNotStartInTimeException 导致主进程崩溃。
                if (!foregroundStarted) {
                    try {
                        startForegroundWithNotification("随身助理", "正在停止服务...")
                    } catch (_: Exception) {
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_REMOVE)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(true)
                }
                foregroundStarted = false
                isRunning = false
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_UPDATE -> {
                readState(intent)
                val title = intent.getStringExtra(EXTRA_TITLE)
                val content = intent.getStringExtra(EXTRA_CONTENT)
                if (!foregroundStarted) {
                    startForegroundWithNotification(
                        title ?: "随身智能助理",
                        content ?: "正在运行...",
                    )
                } else if (title != null || content != null) {
                    updateNotification(
                        title ?: lastNotificationTitle,
                        content ?: lastNotificationContent,
                    )
                } else {
                    updateCapsuleVisibility()
                }
            }
            ACTION_SET_MIC_ACTIVE -> {
                val active = intent.getBooleanExtra(EXTRA_ACTIVE, true)
                micListening = active
                capsuleEnabled = intent.getBooleanExtra(EXTRA_CAPSULE_ENABLED, capsuleEnabled)
                statusText = intent.getStringExtra(EXTRA_STATUS) ?: statusText
                if (active) {
                    acquireWakeLock()
                    startForegroundWithNotification(
                        "随身助理后台运行中",
                        "低功耗待机中，可随时说“晓漫”唤醒",
                    )
                } else {
                    releaseWakeLock()
                    if (!capsuleEnabled) {
                        if (!foregroundStarted) {
                            try {
                                startForegroundWithNotification("随身助理", "正在停止服务...")
                            } catch (_: Exception) {
                            }
                        }
                        stopForegroundCompat()
                        isRunning = false
                        stopSelf()
                        return START_NOT_STICKY
                    }
                    startForegroundWithNotification("随身助理悬浮胶囊", "话筒已关闭")
                }
                updateCapsuleVisibility()
            }
            ACTION_SET_CAPSULE_ENABLED -> {
                capsuleEnabled = intent.getBooleanExtra(EXTRA_CAPSULE_ENABLED, false)
                micListening = intent.getBooleanExtra(EXTRA_MIC_LISTENING, micListening)
                statusText = intent.getStringExtra(EXTRA_STATUS) ?: statusText
                getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putBoolean(PREF_CAPSULE_ENABLED, capsuleEnabled)
                    .apply()
                if (capsuleEnabled) {
                    if (micListening) {
                        acquireWakeLock()
                    } else {
                        releaseWakeLock()
                    }
                    if (!foregroundStarted) {
                        startForegroundWithNotification(
                            if (micListening) "随身助理后台运行中" else "随身助理悬浮胶囊",
                            if (micListening) "低功耗待机中，可随时说“晓漫”唤醒" else "话筒已关闭",
                        )
                    }
                    updateCapsuleVisibility()
                } else {
                    updateCapsuleVisibility()
                    if (!micListening) {
                        if (!foregroundStarted) {
                            try {
                                startForegroundWithNotification("随身助理", "正在停止服务...")
                            } catch (_: Exception) {
                            }
                        }
                        stopForegroundCompat()
                        isRunning = false
                        stopSelf()
                        return START_NOT_STICKY
                    }
                }
            }
            ACTION_APP_FOREGROUND -> {
                appForeground = true
                ensureForegroundStarted()
                updateCapsuleVisibility()
            }
            ACTION_APP_BACKGROUND -> {
                appForeground = false
                ensureForegroundStarted()
                updateCapsuleVisibility()
            }
            ACTION_CAPSULE_CAPTURE -> {
                handleCapsuleAction(CAPSULE_ACTION_CAPTURE)
                return START_STICKY
            }
            ACTION_CAPSULE_TOGGLE_MIC -> {
                handleCapsuleAction(CAPSULE_ACTION_TOGGLE_MIC)
                return START_STICKY
            }
            ACTION_CAPSULE_OPEN_APP -> {
                handleCapsuleAction(CAPSULE_ACTION_OPEN_APP)
                return START_STICKY
            }
            ACTION_CAPSULE_EXIT -> {
                exitApp()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                readState(intent)
                if (micListening) {
                    acquireWakeLock()
                } else {
                    releaseWakeLock()
                }
                val title = intent.getStringExtra(EXTRA_TITLE)
                    ?: if (micListening) "随身助理正在后台监听" else "随身助理悬浮胶囊"
                val content = intent.getStringExtra(EXTRA_CONTENT)
                    ?: if (micListening) "可随时说“晓漫”唤醒" else "话筒已关闭"
                startForegroundWithNotification(title, content)
                updateCapsuleVisibility()
            }
        }
        return START_STICKY
    }

    private fun readState(intent: Intent) {
        enableCamera = intent.getBooleanExtra(EXTRA_ENABLE_CAMERA, enableCamera)
        micListening = intent.getBooleanExtra(EXTRA_MIC_LISTENING, micListening)
        capsuleEnabled = intent.getBooleanExtra(EXTRA_CAPSULE_ENABLED, capsuleEnabled)
        statusText = intent.getStringExtra(EXTRA_STATUS) ?: statusText
    }

    private fun handleCapsuleAction(action: String) {
        when (action) {
            CAPSULE_ACTION_OPEN_APP -> launchApp()
            CAPSULE_ACTION_CAPTURE,
            CAPSULE_ACTION_TOGGLE_MIC -> {
                val channel = FloatingCapsuleActionBridge.channel
                if (channel == null) {
                    launchApp()
                    Toast.makeText(this, "已打开 App，请在主界面操作", Toast.LENGTH_SHORT).show()
                } else {
                    try {
                        channel.invokeMethod(action, null)
                    } catch (_: Exception) {
                        launchApp()
                    }
                }
            }
        }
    }

    private fun launchApp() {
        try {
            val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
                ?: Intent(this, MainActivity::class.java)
            launchIntent.flags =
                Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            startActivity(launchIntent)
        } catch (_: Exception) {
        }
    }

    private fun ensureForegroundStarted() {
        if (foregroundStarted || (!micListening && !capsuleEnabled)) return
        startForegroundWithNotification(
            if (micListening) "随身助理后台运行中" else "随身助理悬浮胶囊",
            if (micListening) "低功耗待机中，可随时说“晓漫”唤醒" else "话筒已关闭",
        )
    }

    /**
     * 重新构建通知，让系统按当前前后台状态决定是否把通知提升为
     * Android 16 Live Update（状态栏胶囊）。
     */
    private fun updateCapsuleVisibility() {
        if (!foregroundStarted) return
        updateNotification(lastNotificationTitle, lastNotificationContent)
    }

    private fun hasCameraPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.CAMERA,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun acquireWakeLock() {
        try {
            if (wakeLock == null) {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "SideAssistant:ListeningWakeLock"
                ).apply {
                    setReferenceCounted(false)
                    acquire()
                }
            } else if (wakeLock?.isHeld == false) {
                wakeLock?.acquire()
            }
        } catch (_: Exception) {}
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {}
        wakeLock = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "保持随身智能助理在后台或熄屏状态下持续语音交互"
                setShowBadge(false)
                setSound(null, null)
                enableVibration(false)
            }
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    /**
     * 胶囊状态短标签：最多两个汉字。
     *
     * Flutter 侧现在会直接传“待机/倾听/思考/播报/失败”，这里再兜底一次，
     * 兼容旧版本传过来的“等待输入/正在倾听”等长文本。
     */
    private fun capsuleStatusLabel(): String {
        val raw = statusText.trim()
        return when {
            raw.contains("失败") -> "失败"
            raw.contains("倾听") || raw.contains("聆听") -> "倾听"
            raw.contains("思考") || raw.contains("发送") || raw.contains("生成") -> "思考"
            raw.contains("播") || raw.contains("回答") -> "播报"
            raw.contains("待机") || raw.contains("等待") || raw.contains("输入") -> "待机"
            else -> raw.take(2).ifEmpty { "待机" }
        }
    }

    private fun buildNotification(
        title: String,
        content: String,
    ): Notification {
        // Android 16 Live Update：胶囊只在 App 退到后台且用户开启开关时请求提升。
        val promoted = capsuleEnabled && !appForeground
        val statusLabel = capsuleStatusLabel()
        val displayTitle = "随身助理 - $statusLabel"

        lastNotificationTitle = displayTitle
        lastNotificationContent = content

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
            ?: Intent(this, MainActivity::class.java)
        launchIntent.flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP

        val contentPendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            pendingIntentFlags(),
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(displayTitle)
            // 展开后第二行只放操作按钮，不再显示长段说明文字。
            .setContentText(if (promoted) "" else content)
            // 非弹出状态左侧图标直接表达话筒是否在监听：
            // 有斜线 = 未监听，无斜线 = 监听中。
            .setSmallIcon(
                if (micListening) R.drawable.ic_mic_small else R.drawable.ic_mic_off_small
            )
            .setColor(0xFF00796B.toInt())
            .setContentIntent(contentPendingIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .addAction(
                R.drawable.ic_camera_small,
                "拍照",
                servicePendingIntent(ACTION_CAPSULE_CAPTURE, 1),
            )
            // 开关麦不再用“开麦/关麦”文字区分，固定标题“话筒”，
            // 由图标是否带斜线表达当前状态。
            .addAction(
                if (micListening) R.drawable.ic_mic_small else R.drawable.ic_mic_off_small,
                "话筒",
                servicePendingIntent(ACTION_CAPSULE_TOGGLE_MIC, 2),
            )
            .addAction(
                R.drawable.ic_close_small,
                "关闭",
                servicePendingIntent(ACTION_CAPSULE_EXIT, 3),
            )

        val notification = builder.build()
        // NotificationCompat 1.13 还没有 setRequestPromotedOngoing / setShortCriticalText，
        // 直接写平台读取的 extras（与 Google Maps 的 Live Update 通知一致）。
        notification.extras.putBoolean(EXTRA_REQUEST_PROMOTED_ONGOING, promoted)
        if (promoted) {
            // 胶囊右侧最多两个汉字，例如“待机/倾听/思考/播报”。
            notification.extras.putCharSequence(EXTRA_SHORT_CRITICAL_TEXT, statusLabel)
        }
        return notification
    }

    /**
     * 关闭胶囊并退出 App。
     *
     * 胶囊是前台服务通知，仅 finish Activity 会留下服务；这里先撤掉前台服务
     * 与通知，再结束进程，确保话筒、摄像头和 WakeLock 都立即释放。
     */
    private fun exitApp() {
        try {
            releaseWakeLock()
            stopForegroundCompat()
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.cancel(NOTIFICATION_ID)
            stopSelf()
        } catch (_: Exception) {
        }
        try {
            android.os.Process.killProcess(android.os.Process.myPid())
        } catch (_: Exception) {
            System.exit(0)
        }
    }

    private fun servicePendingIntent(action: String, requestCode: Int): PendingIntent {
        val intent = Intent(this, ListeningForegroundService::class.java).apply {
            this.action = action
        }
        return PendingIntent.getService(this, requestCode, intent, pendingIntentFlags())
    }

    private fun pendingIntentFlags(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
    }

    private fun startForegroundWithNotification(title: String, content: String) {
        val notification = buildNotification(title, content)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var types = 0
            if (micListening) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            // 只有拿到 CAMERA 运行时权限才申报 camera 类型，否则 Android 14+ 会抛 SecurityException。
            // 胶囊模式下也要保留 camera 类型，才能从悬浮窗直接后台抓拍。
            if (enableCamera || hasCameraPermission()) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            if (!micListening && Build.VERSION.SDK_INT >= 34) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            }

            if (types != 0) {
                try {
                    startForeground(NOTIFICATION_ID, notification, types)
                    foregroundStarted = true
                    return
                } catch (e: Exception) {
                    // 后台启动 / 权限状态变化导致申报类型被拒时降级。
                    if (micListening) {
                        enableCamera = false
                        val micOnly = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                        try {
                            startForeground(NOTIFICATION_ID, notification, micOnly)
                            foregroundStarted = true
                            return
                        } catch (_: Exception) {
                        }
                    }
                }
            }
        }
        try {
            startForeground(NOTIFICATION_ID, notification)
            foregroundStarted = true
        } catch (_: Exception) {
            foregroundStarted = false
            stopSelf()
        }
    }

    private fun stopForegroundCompat() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        foregroundStarted = false
    }

    private fun updateNotification(title: String, content: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification(title, content))
    }

    override fun onDestroy() {
        isRunning = false
        releaseWakeLock()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
