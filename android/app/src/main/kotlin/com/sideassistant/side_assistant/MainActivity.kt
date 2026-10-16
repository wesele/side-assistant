package com.sideassistant.side_assistant

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.sideassistant.side_assistant/foreground_service"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 101)
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startForeground" -> {
                    val title = call.argument<String>("title") ?: "随身助理正在后台监听"
                    val content = call.argument<String>("content") ?: "可随时说“晓漫”唤醒"
                    val intent = Intent(this, ListeningForegroundService::class.java).apply {
                        action = ListeningForegroundService.ACTION_START
                        putExtra(ListeningForegroundService.EXTRA_TITLE, title)
                        putExtra(ListeningForegroundService.EXTRA_CONTENT, content)
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
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
                    val intent = Intent(this, ListeningForegroundService::class.java).apply {
                        action = ListeningForegroundService.ACTION_STOP
                    }
                    startService(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
