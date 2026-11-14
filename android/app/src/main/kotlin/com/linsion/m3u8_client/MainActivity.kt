package com.linsion.m3u8_client

import android.Manifest
import android.app.Activity
import android.app.Dialog
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.UiModeManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.hardware.Camera
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.view.Window
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.EnumMap

@Suppress("DEPRECATION")
class MainActivity : FlutterActivity() {
    private val channelName = "com.linsion.m3u8_client/tv_platform"
    private val notifChannelName = "com.linsion.m3u8_client/notifications"
    private val qrChannelName = "com.linsion.m3u8_client/qr_scanner"
    private val telegramChannelId = "telegram_messages_channel"
    private var notificationsChannel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingQrScanResult: MethodChannel.Result? = null
    private var activeQrDialog: Dialog? = null
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, qrChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanCamera" -> startCameraQrScan(result)
                    "scanGallery" -> startGalleryQrScan(result)
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

    private fun startCameraQrScan(result: MethodChannel.Result) {
        pendingQrScanResult = result
        val granted = ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.CAMERA
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            showCameraQrScannerDialog()
        } else {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.CAMERA),
                9103
            )
        }
    }

    private fun startGalleryQrScan(result: MethodChannel.Result) {
        pendingQrScanResult = result
        launchGalleryPicker()
    }

    private fun launchGalleryPicker() {
        try {
            val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
            }
            startActivityForResult(Intent.createChooser(intent, "选择包含二维码的图片"), 9104)
        } catch (e: Exception) {
            finishQrScan(null)
        }
    }

    private fun finishQrScan(value: String?) {
        try {
            activeQrDialog?.dismiss()
        } catch (_: Exception) {}
        activeQrDialog = null
        val res = pendingQrScanResult
        pendingQrScanResult = null
        res?.success(value)
    }

    private fun buildQrReader(): MultiFormatReader {
        val hints = EnumMap<DecodeHintType, Any>(DecodeHintType::class.java)
        hints[DecodeHintType.POSSIBLE_FORMATS] = listOf(BarcodeFormat.QR_CODE)
        hints[DecodeHintType.CHARACTER_SET] = "UTF-8"
        hints[DecodeHintType.TRY_HARDER] = true
        return MultiFormatReader().apply { setHints(hints) }
    }

    private fun decodeQrFromBitmap(bitmap: Bitmap): String? {
        val width = bitmap.width
        val height = bitmap.height
        if (width <= 0 || height <= 0) return null
        val pixels = IntArray(width * height)
        bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
        val source = RGBLuminanceSource(width, height, pixels)
        val reader = buildQrReader()
        val candidates = listOf(
            BinaryBitmap(HybridBinarizer(source)),
            BinaryBitmap(GlobalHistogramBinarizer(source)),
            BinaryBitmap(HybridBinarizer(source.invert()))
        )
        for (bin in candidates) {
            try {
                val decoded = reader.decodeWithState(bin)
                if (!decoded.text.isNullOrBlank()) {
                    return decoded.text.trim()
                }
            } catch (_: Exception) {
                reader.reset()
            }
        }
        return null
    }

    private fun decodeQrFromUri(uri: Uri): String? {
        return try {
            val opts = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, opts)
            }
            var sampleSize = 1
            val maxDim = maxOf(opts.outWidth, opts.outHeight)
            while (maxDim / sampleSize > 1600) {
                sampleSize *= 2
            }
            val decodeOpts = BitmapFactory.Options().apply { inSampleSize = sampleSize }
            val bmp = contentResolver.openInputStream(uri)?.use {
                BitmapFactory.decodeStream(it, null, decodeOpts)
            } ?: return null
            val text = decodeQrFromBitmap(bmp)
            bmp.recycle()
            text
        } catch (_: Exception) {
            null
        }
    }

    private fun showCameraQrScannerDialog() {
        val dialog = Dialog(this, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
        dialog.requestWindowFeature(Window.FEATURE_NO_TITLE)
        activeQrDialog = dialog

        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
        }
        val surfaceView = SurfaceView(this)
        root.addView(
            surfaceView,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        )

        val d = resources.displayMetrics.density
        val frameSize = (260 * d).toInt()
        val finderBox = FrameLayout(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = 18 * d
                setStroke((2.5f * d).toInt(), Color.parseColor("#00D1FF"))
                setColor(Color.parseColor("#1800D1FF"))
            }
        }
        root.addView(
            finderBox,
            FrameLayout.LayoutParams(frameSize, frameSize).apply {
                gravity = Gravity.CENTER
            }
        )

        val topBar = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding((20 * d).toInt(), (48 * d).toInt(), (20 * d).toInt(), (16 * d).toInt())
        }
        val titleView = TextView(this).apply {
            text = "扫描代理订阅 / 节点二维码"
            setTextColor(Color.WHITE)
            textSize = 17f
            gravity = Gravity.CENTER
        }
        val subView = TextView(this).apply {
            text = "将订阅链接或节点二维码放入框内即可自动识别"
            setTextColor(Color.parseColor("#B0BEC5"))
            textSize = 13f
            gravity = Gravity.CENTER
            setPadding(0, (6 * d).toInt(), 0, 0)
        }
        topBar.addView(titleView)
        topBar.addView(subView)
        root.addView(
            topBar,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                gravity = Gravity.TOP
            }
        )

        val bottomBar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding((20 * d).toInt(), (16 * d).toInt(), (20 * d).toInt(), (44 * d).toInt())
        }
        val galleryBtn = Button(this).apply {
            text = "从相册选图识别"
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                cornerRadius = 22 * d
                setColor(Color.parseColor("#007ACC"))
            }
            setPadding((22 * d).toInt(), (10 * d).toInt(), (22 * d).toInt(), (10 * d).toInt())
            setOnClickListener {
                try {
                    dialog.dismiss()
                } catch (_: Exception) {}
                activeQrDialog = null
                launchGalleryPicker()
            }
        }
        val cancelBtn = Button(this).apply {
            text = "取消关闭"
            setTextColor(Color.WHITE)
            background = GradientDrawable().apply {
                cornerRadius = 22 * d
                setColor(Color.parseColor("#37474F"))
            }
            setPadding((22 * d).toInt(), (10 * d).toInt(), (22 * d).toInt(), (10 * d).toInt())
            setOnClickListener {
                finishQrScan(null)
            }
        }
        bottomBar.addView(galleryBtn)
        bottomBar.addView(
            cancelBtn,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                leftMargin = (16 * d).toInt()
            }
        )
        root.addView(
            bottomBar,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
            ).apply {
                gravity = Gravity.BOTTOM
            }
        )

        var camera: Camera? = null
        var isDecoding = false
        var scanCompleted = false
        val reader = buildQrReader()

        fun releaseCamera() {
            try {
                camera?.setPreviewCallback(null)
                camera?.stopPreview()
                camera?.release()
            } catch (_: Exception) {}
            camera = null
        }

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                try {
                    val cam = Camera.open()
                    camera = cam
                    cam.setDisplayOrientation(90)
                    val params = cam.parameters
                    val focusModes = params.supportedFocusModes
                    if (focusModes != null) {
                        if (focusModes.contains(Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE)) {
                            params.focusMode = Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE
                        } else if (focusModes.contains(Camera.Parameters.FOCUS_MODE_AUTO)) {
                            params.focusMode = Camera.Parameters.FOCUS_MODE_AUTO
                        }
                    }
                    try {
                        cam.parameters = params
                    } catch (_: Exception) {}
                    cam.setPreviewDisplay(holder)
                    cam.setPreviewCallback { data, c ->
                        if (isDecoding || scanCompleted || data == null) return@setPreviewCallback
                        val size = try {
                            c.parameters.previewSize
                        } catch (_: Exception) {
                            null
                        } ?: return@setPreviewCallback
                        isDecoding = true
                        Thread {
                            var foundText: String? = null
                            try {
                                val src = PlanarYUVLuminanceSource(
                                    data,
                                    size.width,
                                    size.height,
                                    0,
                                    0,
                                    size.width,
                                    size.height,
                                    false
                                )
                                val binList = listOf(
                                    BinaryBitmap(HybridBinarizer(src)),
                                    BinaryBitmap(HybridBinarizer(src.invert()))
                                )
                                for (bin in binList) {
                                    try {
                                        val res = reader.decodeWithState(bin)
                                        if (!res.text.isNullOrBlank()) {
                                            foundText = res.text.trim()
                                            break
                                        }
                                    } catch (_: Exception) {
                                        reader.reset()
                                    }
                                }
                            } catch (_: Exception) {
                            } finally {
                                if (foundText != null && !scanCompleted) {
                                    scanCompleted = true
                                    runOnUiThread {
                                        releaseCamera()
                                        finishQrScan(foundText)
                                    }
                                }
                                isDecoding = false
                            }
                        }.start()
                    }
                    cam.startPreview()
                } catch (_: Exception) {
                    releaseCamera()
                    finishQrScan(null)
                }
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {}

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                releaseCamera()
            }
        })

        dialog.setOnCancelListener {
            releaseCamera()
            finishQrScan(null)
        }
        dialog.setOnDismissListener {
            releaseCamera()
        }
        dialog.setContentView(root)
        dialog.show()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 9104) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri = data.data!!
                Thread {
                    val decoded = decodeQrFromUri(uri)
                    runOnUiThread {
                        finishQrScan(decoded ?: "")
                    }
                }.start()
            } else {
                finishQrScan(null)
            }
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
        } else if (requestCode == 9103) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            if (granted) {
                showCameraQrScannerDialog()
            } else {
                finishQrScan(null)
            }
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

    private fun isAndroidTvDevice(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
            return true
        }
        val pm = packageManager
        return pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            pm.hasSystemFeature("android.software.leanback_only") ||
            pm.hasSystemFeature("android.hardware.type.television") ||
            !pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
    }
}
