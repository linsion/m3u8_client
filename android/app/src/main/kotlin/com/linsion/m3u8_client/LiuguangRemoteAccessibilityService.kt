package com.linsion.m3u8_client

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Bitmap
import android.graphics.Path
import android.os.Build
import android.os.Bundle
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class LiuguangRemoteAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: LiuguangRemoteAccessibilityService? = null
    }

    private val screenshotExecutor = Executors.newSingleThreadExecutor()

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {}

    override fun onInterrupt() {}

    override fun onDestroy() {
        if (instance === this) {
            instance = null
        }
        super.onDestroy()
    }

    fun performTap(x: Float, y: Float, durationMs: Long = 45L): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        return try {
            val path = Path().apply { moveTo(x.coerceAtLeast(1f), y.coerceAtLeast(1f)) }
            val stroke = GestureDescription.StrokeDescription(path, 0L, durationMs)
            val gesture = GestureDescription.Builder().addStroke(stroke).build()
            dispatchGesture(gesture, null, null)
        } catch (_: Exception) {
            false
        }
    }

    fun performDoubleTap(x: Float, y: Float): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        return try {
            val safeX = x.coerceAtLeast(1f)
            val safeY = y.coerceAtLeast(1f)
            val p1 = Path().apply { moveTo(safeX, safeY) }
            val p2 = Path().apply { moveTo(safeX, safeY) }
            val s1 = GestureDescription.StrokeDescription(p1, 0L, 40L)
            val s2 = GestureDescription.StrokeDescription(p2, 95L, 40L)
            val gesture = GestureDescription.Builder().addStroke(s1).addStroke(s2).build()
            dispatchGesture(gesture, null, null)
        } catch (_: Exception) {
            false
        }
    }

    fun performSwipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long = 180L): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return false
        return try {
            val path = Path().apply {
                moveTo(x1.coerceAtLeast(1f), y1.coerceAtLeast(1f))
                lineTo(x2.coerceAtLeast(1f), y2.coerceAtLeast(1f))
            }
            val stroke = GestureDescription.StrokeDescription(path, 0L, durationMs.coerceIn(40L, 1500L))
            val gesture = GestureDescription.Builder().addStroke(stroke).build()
            dispatchGesture(gesture, null, null)
        } catch (_: Exception) {
            false
        }
    }

    fun performSystemAction(actionName: String): Boolean {
        return when (actionName.lowercase()) {
            "back", "escape", "esc" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "home", "win", "show_desktop", "win+d" -> performGlobalAction(GLOBAL_ACTION_HOME)
            "recents", "alt+tab", "cmd+tab", "mission_control", "win+tab" ->
                performGlobalAction(GLOBAL_ACTION_RECENTS)
            "notifications" -> performGlobalAction(GLOBAL_ACTION_NOTIFICATIONS)
            else -> false
        }
    }

    fun injectFocusedText(text: String): Boolean {
        return try {
            val root = rootInActiveWindow ?: return false
            val focused = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: return false
            val args = Bundle().apply {
                putCharSequence(
                    AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                    text
                )
            }
            focused.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
        } catch (_: Exception) {
            false
        }
    }

    fun captureSystemScreenJpeg(
        maxWidth: Int,
        quality: Int,
        onComplete: (Map<String, Any>?) -> Unit
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                takeScreenshot(
                    Display.DEFAULT_DISPLAY,
                    screenshotExecutor,
                    object : TakeScreenshotCallback {
                        override fun onSuccess(screenshot: ScreenshotResult) {
                            try {
                                val hwBuffer = screenshot.hardwareBuffer
                                val colorSpace = screenshot.colorSpace
                                val hwBmp = Bitmap.wrapHardwareBuffer(hwBuffer, colorSpace)
                                hwBuffer.close()
                                if (hwBmp == null) {
                                    onComplete(null)
                                    return
                                }
                                val swBmp = hwBmp.copy(Bitmap.Config.ARGB_8888, false)
                                hwBmp.recycle()
                                if (swBmp == null) {
                                    onComplete(null)
                                    return
                                }
                                val srcW = swBmp.width
                                val srcH = swBmp.height
                                val targetMaxW = maxWidth.coerceIn(360, 2560)
                                val scale = (targetMaxW.toFloat() / srcW.coerceAtLeast(1)).coerceAtMost(1f)
                                val dstW = (srcW * scale).toInt().coerceAtLeast(1)
                                val dstH = (srcH * scale).toInt().coerceAtLeast(1)
                                val scaled = if (dstW != srcW || dstH != srcH) {
                                    Bitmap.createScaledBitmap(swBmp, dstW, dstH, true).also {
                                        if (it !== swBmp) swBmp.recycle()
                                    }
                                } else {
                                    swBmp
                                }
                                val bos = ByteArrayOutputStream()
                                scaled.compress(
                                    Bitmap.CompressFormat.JPEG,
                                    quality.coerceIn(30, 95),
                                    bos
                                )
                                scaled.recycle()
                                onComplete(
                                    mapOf(
                                        "bytes" to bos.toByteArray(),
                                        "width" to dstW,
                                        "height" to dstH
                                    )
                                )
                            } catch (_: Exception) {
                                onComplete(null)
                            }
                        }

                        override fun onFailure(errorCode: Int) {
                            onComplete(null)
                        }
                    }
                )
                return
            } catch (_: Exception) {}
        }
        onComplete(null)
    }
}
