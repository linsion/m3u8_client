package com.linsion.m3u8_client

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "com.linsion.m3u8_client/tv_platform"
    private val notifChannelName = "com.linsion.m3u8_client/notifications"
    private val telegramChannelId = "telegram_messages_channel"
    private var notificationsChannel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingTapPayload: Map<String, Any>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureTelegramNotificationChannel()
        extractNotificationTapIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        extractNotificationTapIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getPlatformTvInfo" -> {
                        val isTv = isAndroidTvDevice()
                        result.success(
                            mapOf(
                                "isTv" to isTv,
                                "platform" to if (isTv) "android_tv" else "android",
                                "supportsAirPlay" to false
                            )
                        )
                    }
                    else -> result.notImplemented()
                }
            }

        val nChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, notifChannelName)
        notificationsChannel = nChannel
        nChannel.setMethodCallHandler { call, result ->
            handleNotificationMethodCall(call, result)
        }
        pendingTapPayload?.let { payload ->
            pendingTapPayload = null
            nChannel.invokeMethod("onNotificationTapped", payload)
        }
    }

    private fun ensureTelegramNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val channel = NotificationChannel(
                telegramChannelId,
                "Telegram 消息通知",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "仅通知未静默的 Telegram 会话新消息"
                enableVibration(true)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun extractNotificationTapIntent(intent: Intent?) {
        if (intent?.action != "com.linsion.m3u8_client.OPEN_TG_NOTIFICATION") return
        val payload = mapOf(
            "key" to (intent.getStringExtra("tg_key") ?: ""),
            "accountId" to (intent.getStringExtra("tg_account_id") ?: "default"),
            "peer" to (intent.getStringExtra("tg_peer") ?: ""),
            "messageId" to intent.getIntExtra("tg_message_id", 0)
        )
        val ch = notificationsChannel
        if (ch != null) {
            ch.invokeMethod("onNotificationTapped", payload)
        } else {
            pendingTapPayload = payload
        }
    }

    private fun handleNotificationMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        when (call.method) {
            "requestPermission" -> {
                if (Build.VERSION.SDK_INT >= 33) {
                    val granted = ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.POST_NOTIFICATIONS
                    ) == PackageManager.PERMISSION_GRANTED
                    if (granted) {
                        result.success(true)
                    } else {
                        pendingPermissionResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            9102
                        )
                    }
                } else {
                    result.success(nm?.areNotificationsEnabled() ?: true)
                }
            }
            "getPermissionStatus" -> {
                if (Build.VERSION.SDK_INT >= 33) {
                    val granted = ContextCompat.checkSelfPermission(
                        this,
                        Manifest.permission.POST_NOTIFICATIONS
                    ) == PackageManager.PERMISSION_GRANTED
                    result.success(granted && (nm?.areNotificationsEnabled() ?: true))
                } else {
                    result.success(nm?.areNotificationsEnabled() ?: true)
                }
            }
            "showNotification" -> {
                if (nm == null) {
                    result.success(false)
                    return
                }
                ensureTelegramNotificationChannel()
                val key = call.argument<String>("key") ?: "default"
                val title = call.argument<String>("title") ?: "Telegram 新消息"
                val subtitle = call.argument<String>("subtitle") ?: ""
                val body = call.argument<String>("body") ?: ""
                val accountId = call.argument<String>("accountId") ?: "default"
                val peer = call.argument<String>("peer") ?: ""
                val messageId = call.argument<Int>("messageId") ?: 0

                val tapIntent = Intent(this, MainActivity::class.java).apply {
                    action = "com.linsion.m3u8_client.OPEN_TG_NOTIFICATION"
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                    putExtra("tg_key", key)
                    putExtra("tg_account_id", accountId)
                    putExtra("tg_peer", peer)
                    putExtra("tg_message_id", messageId)
                }
                val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val pendingIntent = PendingIntent.getActivity(
                    this,
                    key.hashCode(),
                    tapIntent,
                    piFlags
                )

                val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Notification.Builder(this, telegramChannelId)
                } else {
                    @Suppress("DEPRECATION")
                    Notification.Builder(this)
                }
                val displayTitle = if (subtitle.isNotEmpty()) "$title · $subtitle" else title
                builder.setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle(displayTitle)
                    .setContentText(body)
                    .setStyle(Notification.BigTextStyle().bigText(body))
                    .setAutoCancel(true)
                    .setContentIntent(pendingIntent)

                nm.notify(key.hashCode(), builder.build())
                result.success(true)
            }
            "dismissNotification" -> {
                val key = call.argument<String>("key") ?: ""
                if (key.isNotEmpty()) {
                    nm?.cancel(key.hashCode())
                }
                result.success(true)
            }
            "dismissAllNotifications" -> {
                nm?.cancelAll()
                result.success(true)
            }
            "setBadgeCount" -> {
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 9102) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            pendingPermissionResult?.success(granted)
            pendingPermissionResult = null
        }
    }

    private fun isAndroidTvDevice(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
            return true
        }
        val pm = packageManager
        return pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            pm.hasSystemFeature("android.hardware.type.television")
    }
}
