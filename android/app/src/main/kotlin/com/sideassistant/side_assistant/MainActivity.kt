package com.sideassistant.side_assistant

import android.Manifest
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.content.ContentValues
import android.os.Environment
import android.provider.MediaStore
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val FOREGROUND_CHANNEL = "com.sideassistant.side_assistant/foreground_service"
    private val CAMERA_CHANNEL = "com.sideassistant.side_assistant/camera"
    private val AUDIO_DEVICES_CHANNEL = "com.sideassistant.side_assistant/audio_devices"
    private val OVERLAY_CHANNEL = "com.sideassistant.side_assistant/overlay"
    private val FILE_LAUNCHER_CHANNEL = "com.sideassistant.side_assistant/file_launcher"
    private val PCM_PLAYER_CHANNEL = "com.sideassistant.side_assistant/pcm_player"
    private val CAMERA_PERMISSION_REQUEST = 102

    private lateinit var backgroundCamera: BackgroundCameraController
    private val pcmStreamPlayer by lazy { PcmStreamPlayerController(applicationContext) }
    private var pendingCameraPermissionResult: MethodChannel.Result? = null
    private var overlayChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        backgroundCamera = BackgroundCameraController(applicationContext)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 101)
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FOREGROUND_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForeground" -> {
                    val title = call.argument<String>("title") ?: "随身助理正在后台监听"
                    val content = call.argument<String>("content") ?: "可随时说“晓漫”唤醒"
                    val enableCamera = call.argument<Boolean>("enableCamera") ?: false
                    val micListening = call.argument<Boolean>("micListening") ?: true
                    val capsuleEnabled = call.argument<Boolean>("capsuleEnabled") ?: false
                    val status = call.argument<String>("status") ?: "待机"
                    val intent = Intent(this, ListeningForegroundService::class.java).apply {
                        action = ListeningForegroundService.ACTION_START
                        putExtra(ListeningForegroundService.EXTRA_TITLE, title)
                        putExtra(ListeningForegroundService.EXTRA_CONTENT, content)
                        putExtra(ListeningForegroundService.EXTRA_ENABLE_CAMERA, enableCamera)
                        putExtra(ListeningForegroundService.EXTRA_MIC_LISTENING, micListening)
                        putExtra(ListeningForegroundService.EXTRA_CAPSULE_ENABLED, capsuleEnabled)
                        putExtra(ListeningForegroundService.EXTRA_STATUS, status)
                    }
                    startServiceCompat(intent, foreground = true)
                    MicToggleWidgetProvider.updateAll(this, micListening)
                    result.success(true)
                }
                "setMicActive" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    val capsuleEnabled = call.argument<Boolean>("capsuleEnabled") ?: false
                    val status = call.argument<String>("status") ?: "待机"
                    if (active || ListeningForegroundService.isRunning || capsuleEnabled) {
                        val intent = Intent(this, ListeningForegroundService::class.java).apply {
                            action = ListeningForegroundService.ACTION_SET_MIC_ACTIVE
                            putExtra(ListeningForegroundService.EXTRA_ACTIVE, active)
                            putExtra(ListeningForegroundService.EXTRA_CAPSULE_ENABLED, capsuleEnabled)
                            putExtra(ListeningForegroundService.EXTRA_STATUS, status)
                        }
                        startServiceCompat(intent, foreground = active || capsuleEnabled)
                    }
                    MicToggleWidgetProvider.updateAll(this, active)
                    result.success(true)
                }
                "updateNotification" -> {
                    val title = call.argument<String>("title") ?: "随身智能助理"
                    val content = call.argument<String>("content") ?: ""
                    val intent = Intent(this, ListeningForegroundService::class.java).apply {
                        action = ListeningForegroundService.ACTION_UPDATE
                        putExtra(ListeningForegroundService.EXTRA_TITLE, title)
                        putExtra(ListeningForegroundService.EXTRA_CONTENT, content)
                    }
                    startService(intent)
                    result.success(true)
                }
                "stopForeground" -> {
                    if (ListeningForegroundService.isRunning) {
                        val intent = Intent(this, ListeningForegroundService::class.java).apply {
                            action = ListeningForegroundService.ACTION_STOP
                        }
                        startService(intent)
                    }
                    MicToggleWidgetProvider.updateAll(this, false)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CHANNEL)
        overlayChannel = channel
        FloatingCapsuleActionBridge.channel = channel
        MicToggleWidgetProvider.updateAll(this)
        handleWidgetIntent(intent)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Android 16 Live Update 由系统状态栏渲染，不需要悬浮窗权限。
                // ColorOS 上对应开关是「流体云显示实时活动」，默认关闭，需要引导用户开启。
                "canPostPromoted" -> {
                    val allowed = if (Build.VERSION.SDK_INT >= 36) {
                        try {
                            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                            nm.canPostPromotedNotifications()
                        } catch (_: Exception) {
                            false
                        }
                    } else {
                        false
                    }
                    result.success(allowed)
                }
                "requestPromotion" -> {
                    try {
                        val intent = Intent(Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS).apply {
                            putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        // 部分 ROM 没有实现 AOSP 的 promotion 设置页，退回应用通知设置。
                        try {
                            val fallback = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                                putExtra(Settings.EXTRA_APP_PACKAGE, packageName)
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(fallback)
                            result.success(true)
                        } catch (e2: Exception) {
                            result.error(
                                "promotion_settings_failed",
                                e2.message ?: "无法打开实时活动设置页",
                                null
                            )
                        }
                    }
                }
                "setEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    val micListening = call.argument<Boolean>("micListening") ?: false
                    getSharedPreferences(ListeningForegroundService.PREFS_NAME, Context.MODE_PRIVATE)
                        .edit()
                        .putBoolean(ListeningForegroundService.PREF_CAPSULE_ENABLED, enabled)
                        .apply()
                    FloatingCapsuleActionBridge.onDartReady()
                    MicToggleWidgetProvider.updateAll(this, micListening)
                    if (!enabled && !ListeningForegroundService.isRunning) {
                        result.success(true)
                        return@setMethodCallHandler
                    }
                    val intent = Intent(this, ListeningForegroundService::class.java).apply {
                        action = ListeningForegroundService.ACTION_SET_CAPSULE_ENABLED
                        putExtra(ListeningForegroundService.EXTRA_CAPSULE_ENABLED, enabled)
                        putExtra(
                            ListeningForegroundService.EXTRA_MIC_LISTENING,
                            micListening
                        )
                        putExtra(
                            ListeningForegroundService.EXTRA_STATUS,
                            call.argument<String>("status") ?: "待机"
                        )
                    }
                    startServiceCompat(intent, foreground = enabled)
                    result.success(true)
                }
                "update" -> {
                    val micListening = call.argument<Boolean>("micListening") ?: false
                    FloatingCapsuleActionBridge.onDartReady()
                    MicToggleWidgetProvider.updateAll(this, micListening)
                    if (ListeningForegroundService.isRunning) {
                        val intent = Intent(this, ListeningForegroundService::class.java).apply {
                            action = ListeningForegroundService.ACTION_UPDATE
                            putExtra(
                                ListeningForegroundService.EXTRA_STATUS,
                                call.argument<String>("status") ?: "待机"
                            )
                            putExtra(
                                ListeningForegroundService.EXTRA_MIC_LISTENING,
                                micListening
                            )
                            putExtra(
                                ListeningForegroundService.EXTRA_CAPSULE_ENABLED,
                                call.argument<Boolean>("enabled") ?: false
                            )
                        }
                        startService(intent)
                    }
                    result.success(true)
                }
                "clientReady" -> {
                    FloatingCapsuleActionBridge.onDartReady()
                    result.success(true)
                }
                "hide" -> {
                    if (ListeningForegroundService.isRunning) {
                        val intent = Intent(this, ListeningForegroundService::class.java).apply {
                            action = ListeningForegroundService.ACTION_APP_FOREGROUND
                        }
                        startService(intent)
                    }
                    result.success(true)
                }
                "setAppForeground" -> {
                    setAppForeground(call.argument<Boolean>("foreground") ?: true)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CAMERA_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "hasPermission" -> result.success(backgroundCamera.hasPermission())
                "requestPermission" -> requestCameraPermission(result)
                "open" -> {
                    val lensDirection = call.argument<String>("lensDirection") ?: "back"
                    val targetWidth = call.argument<Int>("targetWidth") ?: 0
                    val targetHeight = call.argument<Int>("targetHeight") ?: 0
                    backgroundCamera.open(lensDirection, targetWidth, targetHeight) { openResult ->
                        openResult.fold(
                            onSuccess = { result.success(true) },
                            onFailure = { e ->
                                result.error(
                                    "camera_open_failed",
                                    e.message ?: "无法打开系统摄像头",
                                    null
                                )
                            }
                        )
                    }
                }
                "getSupportedResolutions" -> {
                    val lensDirection = call.argument<String>("lensDirection") ?: "back"
                    backgroundCamera.getSupportedResolutions(lensDirection) { resolutionResult ->
                        resolutionResult.fold(
                            onSuccess = { result.success(it) },
                            onFailure = { e ->
                                result.error(
                                    "camera_resolutions_failed",
                                    e.message ?: "读取摄像头支持的分辨率失败",
                                    null
                                )
                            }
                        )
                    }
                }
                "capturePhoto" -> {
                    val sendShortEdge = call.argument<Int>("sendShortEdge") ?: 0
                    backgroundCamera.capture(sendShortEdge) { captureResult ->
                        captureResult.fold(
                            onSuccess = { shot ->
                                result.success(
                                    mapOf(
                                        "bytes" to shot.jpegBytes,
                                        "path" to shot.file.absolutePath
                                    )
                                )
                            },
                            onFailure = { e ->
                                result.error(
                                    "camera_capture_failed",
                                    e.message ?: "后台拍照失败",
                                    null
                                )
                            }
                        )
                    }
                }
                "close" -> {
                    backgroundCamera.close()
                    result.success(true)
                }
                "openAppSettings" -> {
                    try {
                        val intent = Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.fromParts("package", packageName, null)
                        ).apply {
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("open_settings_failed", e.message ?: "无法打开系统设置", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_DEVICES_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "listInputDevices" -> {
                    try {
                        result.success(listAudioInputDevices())
                    } catch (e: Exception) {
                        result.error("audio_devices_failed", e.message ?: "读取录音设备失败", null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PCM_PLAYER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "feed" -> {
                    val bytes = call.argument<ByteArray>("bytes")
                    val sampleRate = call.argument<Int>("sampleRate") ?: 24000
                    if (bytes != null && bytes.isNotEmpty()) {
                        pcmStreamPlayer.feed(bytes, sampleRate)
                        result.success(true)
                    } else {
                        result.success(false)
                    }
                }
                "stop" -> {
                    pcmStreamPlayer.stopImmediate()
                    result.success(true)
                }
                "isPlaying" -> {
                    result.success(pcmStreamPlayer.isPlaying())
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, FILE_LAUNCHER_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "openImage" -> {
                    val path = call.argument<String>("path") ?: ""
                    if (path.isEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val file = File(path)
                        if (!file.exists()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        val uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.fileprovider",
                            file
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "image/*")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                "saveAndShareHtml" -> {
                    val fileName = call.argument<String>("fileName") ?: "chat_history.html"
                    val htmlContent = call.argument<String>("htmlContent") ?: ""
                    try {
                        val bytes = htmlContent.toByteArray(Charsets.UTF_8)
                        var savedPath = ""

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val values = ContentValues().apply {
                                put(MediaStore.Downloads.DISPLAY_NAME, fileName)
                                put(MediaStore.Downloads.MIME_TYPE, "text/html")
                                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
                            }
                            val resolver = contentResolver
                            val downloadUri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                            if (downloadUri != null) {
                                resolver.openOutputStream(downloadUri)?.use { out ->
                                    out.write(bytes)
                                    out.flush()
                                }
                                savedPath = "Download/$fileName"
                            }
                        } else {
                            @Suppress("DEPRECATION")
                            val downloadsDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)
                            if (!downloadsDir.exists()) downloadsDir.mkdirs()
                            val outFile = File(downloadsDir, fileName)
                            outFile.writeBytes(bytes)
                            savedPath = outFile.absolutePath
                        }

                        // 同时写一份到 cache 供系统分享/打开面板通过 FileProvider 读取
                        val shareFile = File(cacheDir, fileName)
                        shareFile.writeBytes(bytes)
                        if (savedPath.isEmpty()) {
                            savedPath = shareFile.absolutePath
                        }

                        try {
                            val shareUri = FileProvider.getUriForFile(
                                this,
                                "$packageName.fileprovider",
                                shareFile
                            )
                            val shareIntent = Intent(Intent.ACTION_SEND).apply {
                                type = "text/html"
                                putExtra(Intent.EXTRA_STREAM, shareUri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            val chooser = Intent.createChooser(shareIntent, "导出对话历史 HTML").apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(chooser)
                        } catch (_: Exception) {
                        }

                        result.success(savedPath)
                    } catch (e: Exception) {
                        result.error("export_html_failed", e.message ?: "导出 HTML 失败", null)
                    }
                }
                "openUrl" -> {
                    val url = call.argument<String>("url")?.trim() ?: ""
                    if (url.isEmpty()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    try {
                        val normalized = if (url.contains("://")) url else "https://$url"
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(normalized)).apply {
                            addCategory(Intent.CATEGORY_BROWSABLE)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 枚举可用录音输入设备（手机麦克风 / 蓝牙耳机麦克风 / 有线耳机等）。
     *
     * 只用 type + productName 生成名字，**故意不读取 [AudioDeviceInfo.getAddress]**：
     * Android 12+ 上蓝牙设备地址需要 BLUETOOTH_CONNECT 运行时权限，缺权限时会抛
     * SecurityException（record 插件的 listInputDevices 就会拼 address，所以在接蓝牙
     * 耳机的场景下并不可用）。
     *
     * 过滤规则与 record_android 的 DeviceUtils 保持一致（只要输入源，排除
     * TELEPHONY=18 / REMOTE_SUBMIX=25 / ECHO_REFERENCE=28），这样返回的 id 能被
     * 插件原样匹配回同一个 AudioDeviceInfo。
     */
    private fun listAudioInputDevices(): List<Map<String, Any>> {
        val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        return audioManager.getDevices(AudioManager.GET_DEVICES_INPUTS)
            .asSequence()
            .filter { it.isSource && it.type != 18 && it.type != 25 && it.type != 28 }
            .map { device ->
                mapOf<String, Any>(
                    "id" to device.id.toString(),
                    "label" to audioInputDeviceLabel(device),
                    "type" to device.type,
                    "bluetooth" to (device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                        device.type == AudioDeviceInfo.TYPE_BLE_HEADSET),
                )
            }
            .toList()
    }

    private fun audioInputDeviceLabel(device: AudioDeviceInfo): String {
        val name = try {
            device.productName?.toString().orEmpty()
        } catch (_: Exception) {
            ""
        }
        // 蓝牙设备的 address 是 MAC，读取需要 BLUETOOTH_CONNECT 权限，直接跳过；
        // 其它设备（内置麦的 address 是 "bottom"/"back" 这类位置标识）读取是安全的。
        val address = try {
            if (device.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO ||
                device.type == AudioDeviceInfo.TYPE_BLE_HEADSET
            ) {
                ""
            } else {
                device.address.orEmpty()
            }
        } catch (_: Exception) {
            ""
        }
        // 手机上通常有底部主麦和背面降噪麦两个内置输入，productName 都是机型名，
        // 只能靠 address 区分，否则下拉框里会出现两个一模一样的“手机麦克风”。
        val builtinLabel = when {
            address.contains("back", ignoreCase = true) ||
                name.contains("Back", ignoreCase = true) -> "手机后置麦克风"
            address.contains("bottom", ignoreCase = true) -> "手机麦克风（底部主麦）"
            else -> "手机麦克风"
        }
        return when (device.type) {
            AudioDeviceInfo.TYPE_BUILTIN_MIC -> builtinLabel

            AudioDeviceInfo.TYPE_BLUETOOTH_SCO ->
                "蓝牙耳机麦克风（SCO${if (name.isNotEmpty()) " · $name" else ""}）"

            AudioDeviceInfo.TYPE_BLE_HEADSET ->
                "蓝牙 LE 耳机麦克风（${name.ifEmpty { "LE Audio" }}）"

            AudioDeviceInfo.TYPE_WIRED_HEADSET -> "有线耳机麦克风（$name）"
            AudioDeviceInfo.TYPE_USB_HEADSET -> "USB 耳机麦克风（$name）"
            AudioDeviceInfo.TYPE_USB_DEVICE -> "USB 音频设备（$name）"
            AudioDeviceInfo.TYPE_HEARING_AID -> "助听器麦克风（$name）"
            31 -> "模拟底座麦克风（$name）" // TYPE_DOCK_ANALOG（API 34 起）
            else -> if (name.isNotEmpty()) "$name（type=${device.type}）" else "录音设备（type=${device.type}）"
        }
    }

    private fun startServiceCompat(intent: Intent, foreground: Boolean) {
        try {
            if (foreground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (_: Exception) {
        }
    }

    private fun setAppForeground(foreground: Boolean) {
        if (!ListeningForegroundService.isRunning) return
        try {
            val intent = Intent(this, ListeningForegroundService::class.java).apply {
                action = if (foreground) {
                    ListeningForegroundService.ACTION_APP_FOREGROUND
                } else {
                    ListeningForegroundService.ACTION_APP_BACKGROUND
                }
            }
            startService(intent)
        } catch (_: Exception) {
        }
    }

    override fun onResume() {
        super.onResume()
        setAppForeground(true)
    }

    override fun onPause() {
        super.onPause()
        setAppForeground(false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleWidgetIntent(intent)
    }

    private fun handleWidgetIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.getStringExtra(MicToggleWidgetProvider.EXTRA_PENDING_ACTION)
            ?: if (intent.action == MicToggleWidgetProvider.ACTION_WIDGET_TOGGLE_MIC) "toggleMic" else null
        if (!action.isNullOrEmpty()) {
            intent.removeExtra(MicToggleWidgetProvider.EXTRA_PENDING_ACTION)
            if (intent.action == MicToggleWidgetProvider.ACTION_WIDGET_TOGGLE_MIC) {
                intent.action = null
            }
            FloatingCapsuleActionBridge.queueOrSendAction(action)
        }
    }

    override fun onDestroy() {
        pcmStreamPlayer.dispose()
        if (FloatingCapsuleActionBridge.channel === overlayChannel) {
            FloatingCapsuleActionBridge.channel = null
        }
        overlayChannel = null
        if (!ListeningForegroundService.isRunning) {
            MicToggleWidgetProvider.updateAll(this, false)
        } else {
            MicToggleWidgetProvider.updateAll(this)
        }
        super.onDestroy()
    }

    private fun requestCameraPermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        if (pendingCameraPermissionResult != null) {
            result.error("permission_pending", "正在请求相机权限，请稍候", null)
            return
        }

        // 只自动弹一次系统授权框；用户拒绝后引导去系统设置手动开启。
        val prefs = getSharedPreferences("side_assistant", Context.MODE_PRIVATE)
        if (prefs.getBoolean("camera_permission_requested", false)) {
            result.success(false)
            return
        }
        prefs.edit().putBoolean("camera_permission_requested", true).apply()

        pendingCameraPermissionResult = result
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.CAMERA),
            CAMERA_PERMISSION_REQUEST
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == CAMERA_PERMISSION_REQUEST) {
            val granted =
                grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingCameraPermissionResult?.success(granted)
            pendingCameraPermissionResult = null
        }
    }
}
