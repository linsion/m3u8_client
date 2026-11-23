package com.linsion.m3u8_client

import android.Manifest
import android.app.Activity
import android.app.Dialog
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.UiModeManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.Shader
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.hardware.Camera
import android.media.MediaMetadata
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.os.SystemClock
import android.view.Gravity
import android.view.KeyEvent
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.AspectRatioFrameLayout
import androidx.media3.ui.PlayerView
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.MultiFormatWriter
import com.google.zxing.PlanarYUVLuminanceSource
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.GlobalHistogramBinarizer
import com.google.zxing.common.HybridBinarizer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.util.EnumMap

@Suppress("DEPRECATION")
class MainActivity : FlutterActivity() {
    private val channelName = "com.linsion.m3u8_client/tv_platform"
    private val notifChannelName = "com.linsion.m3u8_client/notifications"
    private val qrChannelName = "com.linsion.m3u8_client/qr_scanner"
    private val mediaSessionChannelName = "com.linsion.m3u8_client/media_session"
    private val telegramChannelId = "telegram_messages_channel"
    private val musicChannelId = "cloud_music_playback_channel"
    private val musicNotificationId = 880102
    private var notificationsChannel: MethodChannel? = null
    private var mediaSessionChannel: MethodChannel? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingQrScanResult: MethodChannel.Result? = null
    private var activeQrDialog: Dialog? = null
    private var activeExoDialog: Dialog? = null
    private var activeExoPlayer: ExoPlayer? = null
    private var pendingTapPayload: Map<String, Any>? = null

    private var mediaSession: MediaSession? = null
    private var mediaControlReceiver: BroadcastReceiver? = null
    private var musicWakeLock: PowerManager.WakeLock? = null
    private var cachedAlbumArtBitmap: Bitmap? = null
    private var cachedTrackTitle: String = ""

    companion object {
        private const val ACTION_MEDIA_PREV = "com.linsion.m3u8_client.MEDIA_PREV"
        private const val ACTION_MEDIA_TOGGLE = "com.linsion.m3u8_client.MEDIA_TOGGLE"
        private const val ACTION_MEDIA_NEXT = "com.linsion.m3u8_client.MEDIA_NEXT"
        private const val ACTION_MEDIA_STOP = "com.linsion.m3u8_client.MEDIA_STOP"
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        ensureTelegramNotificationChannel()
        ensureMusicNotificationChannel()
        registerMediaControlReceiver()
        extractNotificationTapIntent(intent)
    }

    override fun onDestroy() {
        dismissNativeExoPlayerDialog()
        clearLockScreenMediaSession()
        unregisterMediaControlReceiver()
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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
                    "openNativeExoPlayer" -> {
                        val url = call.argument<String>("url") ?: ""
                        val title = call.argument<String>("title") ?: "视频播放"
                        val startPosMs = (call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0L)
                        val rawHeaders = call.argument<Map<String, Any>>("headers") ?: emptyMap()
                        val headers = mutableMapOf<String, String>()
                        for ((k, v) in rawHeaders) {
                            val ks = k.trim()
                            val vs = v.toString().trim()
                            if (ks.isNotEmpty() && vs.isNotEmpty()) {
                                headers[ks] = vs
                            }
                        }
                        showNativeExoPlayerDialog(url, title, headers, startPosMs, result)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, qrChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "scanCamera" -> startCameraQrScan(result)
                    "scanGallery" -> startGalleryQrScan(result)
                    "generateQrPng" -> {
                        val content = call.argument<String>("content") ?: ""
                        val size = (call.argument<Int>("size") ?: 360).coerceIn(120, 800)
                        result.success(generateQrPngBytes(content, size))
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

        val mChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, mediaSessionChannelName)
        mediaSessionChannel = mChannel
        mChannel.setMethodCallHandler { call, result ->
            handleMediaSessionMethodCall(call, result)
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

    private fun generateQrPngBytes(content: String, size: Int): ByteArray? {
        if (content.isBlank()) return null
        return try {
            val hints = EnumMap<EncodeHintType, Any>(EncodeHintType::class.java)
            hints[EncodeHintType.CHARACTER_SET] = "UTF-8"
            hints[EncodeHintType.MARGIN] = 1
            val matrix = MultiFormatWriter().encode(content, BarcodeFormat.QR_CODE, size, size, hints)
            val w = matrix.width
            val h = matrix.height
            val pixels = IntArray(w * h)
            for (y in 0 until h) {
                val offset = y * w
                for (x in 0 until w) {
                    pixels[offset + x] = if (matrix.get(x, y)) Color.BLACK else Color.WHITE
                }
            }
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            bmp.setPixels(pixels, 0, w, 0, 0, w, h)
            val bos = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 100, bos)
            bos.toByteArray()
        } catch (_: Exception) {
            null
        }
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

    private fun ensureMusicNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val channel = NotificationChannel(
                musicChannelId,
                "流光云端音乐播放",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "用于锁屏音乐播放器与通知栏媒体控制"
                setShowBadge(false)
                enableVibration(false)
                setSound(null, null)
                lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun registerMediaControlReceiver() {
        if (mediaControlReceiver != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    ACTION_MEDIA_PREV -> sendMediaCommandToFlutter("previous")
                    ACTION_MEDIA_TOGGLE -> sendMediaCommandToFlutter("togglePlayPause")
                    ACTION_MEDIA_NEXT -> sendMediaCommandToFlutter("next")
                    ACTION_MEDIA_STOP -> {
                        clearLockScreenMediaSession()
                        sendMediaCommandToFlutter("stop")
                    }
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(ACTION_MEDIA_PREV)
            addAction(ACTION_MEDIA_TOGGLE)
            addAction(ACTION_MEDIA_NEXT)
            addAction(ACTION_MEDIA_STOP)
        }
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(receiver, filter)
        }
        mediaControlReceiver = receiver
    }

    private fun unregisterMediaControlReceiver() {
        try {
            mediaControlReceiver?.let { unregisterReceiver(it) }
        } catch (_: Exception) {}
        mediaControlReceiver = null
    }

    private fun sendMediaCommandToFlutter(action: String, positionMs: Long? = null) {
        runOnUiThread {
            val payload = mutableMapOf<String, Any>("action" to action)
            if (positionMs != null) {
                payload["positionMs"] = positionMs
            }
            mediaSessionChannel?.invokeMethod("onMediaCommand", payload)
        }
    }

    private fun ensureMediaSessionInitialized(): MediaSession {
        var session = mediaSession
        if (session != null) return session
        session = MediaSession(this, "LiuguangCloudMusicSession").apply {
            setFlags(
                MediaSession.FLAG_HANDLES_MEDIA_BUTTONS or
                    MediaSession.FLAG_HANDLES_TRANSPORT_CONTROLS
            )
            setCallback(object : MediaSession.Callback() {
                override fun onPlay() {
                    sendMediaCommandToFlutter("play")
                }

                override fun onPause() {
                    sendMediaCommandToFlutter("pause")
                }

                override fun onSkipToNext() {
                    sendMediaCommandToFlutter("next")
                }

                override fun onSkipToPrevious() {
                    sendMediaCommandToFlutter("previous")
                }

                override fun onStop() {
                    clearLockScreenMediaSession()
                    sendMediaCommandToFlutter("stop")
                }

                override fun onSeekTo(pos: Long) {
                    sendMediaCommandToFlutter("seek", pos)
                }
            })
            isActive = true
        }
        mediaSession = session
        return session
    }

    private fun updateMusicWakeLock(isPlaying: Boolean) {
        try {
            if (isPlaying) {
                if (musicWakeLock == null) {
                    val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager
                    musicWakeLock = pm?.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK,
                        "m3u8_client:CloudMusicWakeLock"
                    )?.apply {
                        setReferenceCounted(false)
                    }
                }
                if (musicWakeLock?.isHeld == false) {
                    musicWakeLock?.acquire(6 * 60 * 60 * 1000L)
                }
            } else {
                if (musicWakeLock?.isHeld == true) {
                    musicWakeLock?.release()
                }
            }
        } catch (_: Exception) {}
    }

    private fun clearLockScreenMediaSession() {
        updateMusicWakeLock(false)
        cachedTrackTitle = ""
        cachedAlbumArtBitmap = null
        try {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            nm?.cancel(musicNotificationId)
        } catch (_: Exception) {}
        try {
            mediaSession?.isActive = false
            mediaSession?.release()
        } catch (_: Exception) {}
        mediaSession = null
    }

    private fun handleMediaSessionMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "updateMediaSession" -> {
                val title = call.argument<String>("title") ?: "流光云端音乐"
                val artist = call.argument<String>("artist") ?: "流光播放器"
                val album = call.argument<String>("album") ?: ""
                val isPlaying = call.argument<Boolean>("isPlaying") ?: false
                val positionMs = (call.argument<Number>("positionMs")?.toLong() ?: 0L).coerceAtLeast(0L)
                val durationMs = (call.argument<Number>("durationMs")?.toLong() ?: 0L).coerceAtLeast(0L)
                val speed = (call.argument<Number>("speed")?.toFloat() ?: 1.0f).coerceAtLeast(0.25f)
                val coverBytes = call.argument<ByteArray>("coverBytes")

                if (title != cachedTrackTitle) {
                    cachedTrackTitle = title
                    cachedAlbumArtBitmap = null
                }
                if (coverBytes != null && coverBytes.isNotEmpty()) {
                    try {
                        val decoded = BitmapFactory.decodeByteArray(coverBytes, 0, coverBytes.size)
                        if (decoded != null) {
                            cachedAlbumArtBitmap = decoded
                        }
                    } catch (_: Exception) {}
                }
                if (cachedAlbumArtBitmap == null) {
                    try {
                        cachedAlbumArtBitmap = generateVinylCoverBitmap(title, artist, album)
                    } catch (_: Exception) {
                        try {
                            cachedAlbumArtBitmap = BitmapFactory.decodeResource(resources, R.mipmap.ic_launcher)
                        } catch (_: Exception) {}
                    }
                }

                updateMusicWakeLock(isPlaying)
                ensureMusicNotificationChannel()
                val session = ensureMediaSessionInitialized()
                session.isActive = true

                val metaBuilder = MediaMetadata.Builder()
                    .putString(MediaMetadata.METADATA_KEY_TITLE, title)
                    .putString(MediaMetadata.METADATA_KEY_ARTIST, artist)
                    .putString(MediaMetadata.METADATA_KEY_ALBUM, album)
                if (durationMs > 0L) {
                    metaBuilder.putLong(MediaMetadata.METADATA_KEY_DURATION, durationMs)
                }
                cachedAlbumArtBitmap?.let { bmp ->
                    metaBuilder.putBitmap(MediaMetadata.METADATA_KEY_ALBUM_ART, bmp)
                    metaBuilder.putBitmap(MediaMetadata.METADATA_KEY_DISPLAY_ICON, bmp)
                }
                session.setMetadata(metaBuilder.build())

                val actions = PlaybackState.ACTION_PLAY or
                    PlaybackState.ACTION_PAUSE or
                    PlaybackState.ACTION_PLAY_PAUSE or
                    PlaybackState.ACTION_SKIP_TO_NEXT or
                    PlaybackState.ACTION_SKIP_TO_PREVIOUS or
                    PlaybackState.ACTION_STOP or
                    PlaybackState.ACTION_SEEK_TO
                val stateCode = if (isPlaying) {
                    PlaybackState.STATE_PLAYING
                } else {
                    PlaybackState.STATE_PAUSED
                }
                val pbState = PlaybackState.Builder()
                    .setActions(actions)
                    .setState(
                        stateCode,
                        positionMs,
                        if (isPlaying) speed else 0f,
                        SystemClock.elapsedRealtime()
                    )
                    .build()
                session.setPlaybackState(pbState)

                val piFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
                val openAppIntent = Intent(this, MainActivity::class.java).apply {
                    flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
                }
                val contentPendingIntent = PendingIntent.getActivity(
                    this,
                    880100,
                    openAppIntent,
                    piFlags
                )

                fun buildBroadcastPendingIntent(action: String, reqCode: Int): PendingIntent {
                    val i = Intent(action).apply { setPackage(packageName) }
                    return PendingIntent.getBroadcast(this, reqCode, i, piFlags)
                }

                val prevAction = Notification.Action.Builder(
                    android.R.drawable.ic_media_previous,
                    "上一首",
                    buildBroadcastPendingIntent(ACTION_MEDIA_PREV, 880101)
                ).build()
                val toggleAction = Notification.Action.Builder(
                    if (isPlaying) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
                    if (isPlaying) "暂停" else "播放",
                    buildBroadcastPendingIntent(ACTION_MEDIA_TOGGLE, 880102)
                ).build()
                val nextAction = Notification.Action.Builder(
                    android.R.drawable.ic_media_next,
                    "下一首",
                    buildBroadcastPendingIntent(ACTION_MEDIA_NEXT, 880103)
                ).build()
                val stopAction = Notification.Action.Builder(
                    android.R.drawable.ic_menu_close_clear_cancel,
                    "退出",
                    buildBroadcastPendingIntent(ACTION_MEDIA_STOP, 880104)
                ).build()

                val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    Notification.Builder(this, musicChannelId)
                } else {
                    @Suppress("DEPRECATION")
                    Notification.Builder(this)
                }

                val subtitleLine = if (album.isNotEmpty()) "$artist · $album" else artist
                builder.setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle(title)
                    .setContentText(subtitleLine)
                    .setSubText("流光云端音乐")
                    .setVisibility(Notification.VISIBILITY_PUBLIC)
                    .setContentIntent(contentPendingIntent)
                    .setDeleteIntent(buildBroadcastPendingIntent(ACTION_MEDIA_STOP, 880105))
                    .setOngoing(isPlaying)
                    .setOnlyAlertOnce(true)
                    .setShowWhen(false)
                    .addAction(prevAction)
                    .addAction(toggleAction)
                    .addAction(nextAction)
                    .addAction(stopAction)
                    .setStyle(
                        Notification.MediaStyle()
                            .setMediaSession(session.sessionToken)
                            .setShowActionsInCompactView(0, 1, 2)
                    )
                cachedAlbumArtBitmap?.let { bmp ->
                    builder.setLargeIcon(bmp)
                }

                val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
                nm?.notify(musicNotificationId, builder.build())
                result.success(true)
            }
            "clearMediaSession" -> {
                clearLockScreenMediaSession()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun generateVinylCoverBitmap(title: String, artist: String, album: String): Bitmap {
        val size = 512
        val bmp = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        val hash = kotlin.math.abs((title + artist).hashCode())
        val palettes = arrayOf(
            intArrayOf(Color.rgb(20, 88, 172), Color.rgb(10, 30, 72)),
            intArrayOf(Color.rgb(108, 40, 168), Color.rgb(36, 15, 66)),
            intArrayOf(Color.rgb(18, 132, 122), Color.rgb(10, 46, 52)),
            intArrayOf(Color.rgb(174, 56, 82), Color.rgb(56, 18, 36)),
            intArrayOf(Color.rgb(184, 108, 26), Color.rgb(56, 34, 12))
        )
        val pair = palettes[hash % palettes.size]
        val bgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            shader = LinearGradient(
                0f, 0f, size.toFloat(), size.toFloat(),
                pair[0], pair[1], Shader.TileMode.CLAMP
            )
        }
        canvas.drawRect(0f, 0f, size.toFloat(), size.toFloat(), bgPaint)

        val cx = size / 2f
        val cy = 210f
        val discPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(235, 20, 22, 28)
            style = Paint.Style.FILL
        }
        canvas.drawCircle(cx, cy, 142f, discPaint)

        val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(38, 255, 255, 255)
            style = Paint.Style.STROKE
            strokeWidth = 2.5f
        }
        canvas.drawCircle(cx, cy, 142f, ringPaint)
        for (r in intArrayOf(116, 94, 72)) {
            ringPaint.color = Color.argb(20, 255, 255, 255)
            ringPaint.strokeWidth = 1.5f
            canvas.drawCircle(cx, cy, r.toFloat(), ringPaint)
        }

        val labelPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = pair[0]
            style = Paint.Style.FILL
        }
        canvas.drawCircle(cx, cy, 48f, labelPaint)

        val holePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(15, 16, 20)
            style = Paint.Style.FILL
        }
        canvas.drawCircle(cx, cy, 9f, holePaint)

        val titlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = 30f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textAlign = Paint.Align.CENTER
        }
        val cleanTitle = if (title.length > 16) title.substring(0, 15) + "…" else title
        canvas.drawText(cleanTitle, cx, 412f, titlePaint)

        val subPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.argb(215, 235, 238, 245)
            textSize = 20f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.NORMAL)
            textAlign = Paint.Align.CENTER
        }
        val rawSub = if (artist.isNotEmpty()) artist else album
        val cleanSub = if (rawSub.length > 22) rawSub.substring(0, 21) + "…" else rawSub
        canvas.drawText(cleanSub, cx, 452f, subPaint)

        return bmp
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

    private fun dismissNativeExoPlayerDialog() {
        try {
            activeExoPlayer?.stop()
            activeExoPlayer?.release()
        } catch (_: Exception) {}
        activeExoPlayer = null
        try {
            activeExoDialog?.dismiss()
        } catch (_: Exception) {}
        activeExoDialog = null
    }

    @androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
    private fun showNativeExoPlayerDialog(
        streamUrl: String,
        title: String,
        headers: Map<String, String>,
        startPositionMs: Long,
        result: MethodChannel.Result
    ) {
        if (streamUrl.isBlank()) {
            result.success(mapOf("positionMs" to startPositionMs, "error" to "Empty stream URL"))
            return
        }
        dismissNativeExoPlayerDialog()

        var resultSubmitted = false
        fun finishWithCurrentPos(err: String? = null) {
            if (resultSubmitted) return
            resultSubmitted = true
            val pos = try {
                activeExoPlayer?.currentPosition?.coerceAtLeast(0L) ?: startPositionMs
            } catch (_: Exception) {
                startPositionMs
            }
            val map = mutableMapOf<String, Any>("positionMs" to pos)
            if (!err.isNullOrBlank()) {
                map["error"] = err
            }
            result.success(map)
        }

        try {
            val ua = headers["User-Agent"]
                ?: headers["user-agent"]
                ?: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 115Browser/27.0.5.7"
            val httpFactory = DefaultHttpDataSource.Factory()
                .setUserAgent(ua)
                .setAllowCrossProtocolRedirects(true)
                .setConnectTimeoutMs(20000)
                .setReadTimeoutMs(30000)
                .setDefaultRequestProperties(headers)
            val dataSourceFactory = DefaultDataSource.Factory(this, httpFactory)

            val renderersFactory = DefaultRenderersFactory(this)
                .setExtensionRendererMode(DefaultRenderersFactory.EXTENSION_RENDERER_MODE_PREFER)
                .setEnableDecoderFallback(true)

            val loadControl = DefaultLoadControl.Builder()
                .setBufferDurationsMs(
                    15000, // minBufferMs
                    90000, // maxBufferMs
                    1500,  // bufferForPlaybackMs
                    3000   // bufferForPlaybackAfterRebufferMs
                )
                .setTargetBufferBytes(96 * 1024 * 1024)
                .setPrioritizeTimeOverSizeThresholds(true)
                .build()

            val exoPlayer = ExoPlayer.Builder(this, renderersFactory)
                .setMediaSourceFactory(DefaultMediaSourceFactory(dataSourceFactory))
                .setLoadControl(loadControl)
                .setSeekBackIncrementMs(15000)
                .setSeekForwardIncrementMs(15000)
                .build()
            activeExoPlayer = exoPlayer

            val dialog = Dialog(this, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
            activeExoDialog = dialog
            dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

            val root = FrameLayout(this).apply {
                setBackgroundColor(Color.BLACK)
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            }

            val playerView = PlayerView(this).apply {
                player = exoPlayer
                useController = true
                resizeMode = AspectRatioFrameLayout.RESIZE_MODE_FIT
                setShowBuffering(PlayerView.SHOW_BUFFERING_ALWAYS)
                controllerShowTimeoutMs = 4000
                isFocusable = true
                isFocusableInTouchMode = true
                layoutParams = FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )
            }
            root.addView(playerView)

            // Top bar with video title, aspect ratio toggle, and Exit button
            val topBar = LinearLayout(this).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(36, 24, 36, 20)
                background = GradientDrawable(
                    GradientDrawable.Orientation.TOP_BOTTOM,
                    intArrayOf(Color.argb(210, 0, 0, 0), Color.TRANSPARENT)
                )
                layoutParams = FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    Gravity.TOP
                )
            }

            val badgeView = TextView(this).apply {
                text = "ExoPlayer 零拷贝硬解"
                textSize = 11.5f
                setTextColor(Color.WHITE)
                typeface = Typeface.DEFAULT_BOLD
                setPadding(18, 6, 18, 6)
                background = GradientDrawable().apply {
                    setColor(Color.rgb(2, 132, 199))
                    cornerRadius = 12f
                }
            }
            topBar.addView(badgeView)

            val titleView = TextView(this).apply {
                text = "  $title"
                textSize = 15f
                setTextColor(Color.WHITE)
                typeface = Typeface.DEFAULT_BOLD
                maxLines = 1
                layoutParams = LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f)
            }
            topBar.addView(titleView)

            val closeBtn = Button(this).apply {
                text = "退出全屏硬解"
                textSize = 12.5f
                setTextColor(Color.WHITE)
                setBackgroundColor(Color.argb(175, 45, 55, 72))
                setPadding(24, 8, 24, 8)
                setOnClickListener {
                    finishWithCurrentPos()
                    dismissNativeExoPlayerDialog()
                }
            }
            topBar.addView(closeBtn)
            root.addView(topBar)

            playerView.setControllerVisibilityListener(
                PlayerView.ControllerVisibilityListener { visibility ->
                    topBar.visibility = visibility
                }
            )

            dialog.setOnKeyListener { _, keyCode, event ->
                if (event.action == KeyEvent.ACTION_DOWN) {
                    when (keyCode) {
                        KeyEvent.KEYCODE_BACK, KeyEvent.KEYCODE_ESCAPE -> {
                            if (playerView.isControllerFullyVisible) {
                                playerView.hideController()
                                true
                            } else {
                                finishWithCurrentPos()
                                dismissNativeExoPlayerDialog()
                                true
                            }
                        }
                        KeyEvent.KEYCODE_DPAD_CENTER,
                        KeyEvent.KEYCODE_ENTER,
                        KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE -> {
                            if (!playerView.isControllerFullyVisible) {
                                if (exoPlayer.isPlaying) {
                                    exoPlayer.pause()
                                } else {
                                    exoPlayer.play()
                                }
                                playerView.showController()
                                true
                            } else {
                                false
                            }
                        }
                        KeyEvent.KEYCODE_DPAD_LEFT -> {
                            if (!playerView.isControllerFullyVisible) {
                                exoPlayer.seekBack()
                                playerView.showController()
                                true
                            } else {
                                false
                            }
                        }
                        KeyEvent.KEYCODE_DPAD_RIGHT -> {
                            if (!playerView.isControllerFullyVisible) {
                                exoPlayer.seekForward()
                                playerView.showController()
                                true
                            } else {
                                false
                            }
                        }
                        KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN -> {
                            if (!playerView.isControllerFullyVisible) {
                                playerView.showController()
                                true
                            } else {
                                false
                            }
                        }
                        else -> false
                    }
                } else {
                    false
                }
            }

            dialog.setOnDismissListener {
                finishWithCurrentPos()
                dismissNativeExoPlayerDialog()
            }

            exoPlayer.addListener(object : Player.Listener {
                override fun onPlayerError(error: PlaybackException) {
                    val errMsg = error.localizedMessage ?: "ExoPlayer 播放异常 (${error.errorCodeName})"
                    titleView.text = "  ⚠️ $errMsg"
                }
            })

            dialog.setContentView(root)
            dialog.show()
            playerView.requestFocus()

            val mediaUri = if (streamUrl.startsWith("/")) {
                Uri.fromFile(java.io.File(streamUrl))
            } else {
                Uri.parse(streamUrl)
            }
            val mediaItem = MediaItem.fromUri(mediaUri)
            exoPlayer.setMediaItem(mediaItem)
            if (startPositionMs > 1000L) {
                exoPlayer.seekTo(startPositionMs)
            }
            exoPlayer.prepare()
            exoPlayer.playWhenReady = true
        } catch (e: Exception) {
            dismissNativeExoPlayerDialog()
            finishWithCurrentPos(e.localizedMessage ?: e.toString())
        }
    }
}
