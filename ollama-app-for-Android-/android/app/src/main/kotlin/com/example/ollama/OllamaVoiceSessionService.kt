package com.example.ollama

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.service.voice.VoiceInteractionSession
import android.service.voice.VoiceInteractionSessionService
import android.util.Log
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.ProgressBar
import android.widget.TextView
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream

object AssistantContextStore {
    @Volatile
    private var screenshotPath: String? = null

    fun storeScreenshot(path: String) {
        screenshotPath = path
        MainActivity.notifyAssistantScreenshotAvailable()
    }

    fun consumeScreenshot(): String? {
        val path = screenshotPath
        screenshotPath = null
        return path
    }

    fun hasScreenshot(): Boolean = screenshotPath?.let { File(it).isFile } == true
}

class OllamaVoiceSessionService : VoiceInteractionSessionService() {
    override fun onNewSession(args: Bundle?): VoiceInteractionSession =
        OllamaVoiceSession(this)
}

class OllamaVoiceSession(context: android.content.Context) : VoiceInteractionSession(context) {
    private var panel: View? = null
    private var statusText: TextView? = null
    private var progress: ProgressBar? = null

    override fun onCreate() {
        super.onCreate()
        activeSession = this
        setUiEnabled(true)
    }

    override fun onCreateContentView(): View {
        val density = context.resources.displayMetrics.density
        fun dp(value: Int): Int = (value * density).toInt()

        val root = FrameLayout(context).apply {
            setBackgroundColor(Color.TRANSPARENT)
        }
        val surfaceColor = if (
            (context.resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
            android.content.res.Configuration.UI_MODE_NIGHT_YES
        ) Color.rgb(42, 42, 46) else Color.WHITE
        val foregroundColor = if (surfaceColor == Color.WHITE) Color.BLACK else Color.WHITE
        val panelBackground = GradientDrawable().apply {
            color = android.content.res.ColorStateList.valueOf(surfaceColor)
            cornerRadius = dp(32).toFloat()
        }
        val controls = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = panelBackground
            elevation = dp(14).toFloat()
            setPadding(dp(12), dp(8), dp(8), dp(8))
        }
        panel = controls

        controls.addView(ImageView(context).apply {
            setImageResource(R.mipmap.ic_launcher)
            contentDescription = "Ollama"
        }, LinearLayout.LayoutParams(dp(64), dp(64)))

        progress = ProgressBar(context).apply {
            isIndeterminate = true
        }
        controls.addView(progress, LinearLayout.LayoutParams(dp(30), dp(30)).apply {
            marginStart = dp(12)
            marginEnd = dp(8)
        })

        statusText = TextView(context).apply {
            text = "Escuchando…"
            setTextColor(foregroundColor)
            textSize = 16f
            maxLines = 2
        }
        controls.addView(statusText, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))

        controls.addView(ImageButton(context).apply {
            setImageResource(R.drawable.ic_assistant_add_context)
            setColorFilter(foregroundColor)
            setBackgroundColor(Color.TRANSPARENT)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(14), dp(14), dp(14), dp(14))
            contentDescription = "Share screen or camera"
            setOnClickListener { showMediaMenu(this) }
        }, LinearLayout.LayoutParams(dp(52), dp(52)))

        controls.addView(ImageButton(context).apply {
            setImageResource(R.drawable.ic_assistant_stop)
            setColorFilter(foregroundColor)
            setBackgroundColor(Color.TRANSPARENT)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(14), dp(14), dp(14), dp(14))
            contentDescription = "Detener asistente"
            setOnClickListener {
                MainActivity.notifyAssistantStopRequested()
                updateState("Detenido", false)
            }
        }, LinearLayout.LayoutParams(dp(52), dp(52)))

        controls.addView(ImageButton(context).apply {
            setImageResource(R.drawable.ic_assistant_close)
            setColorFilter(foregroundColor)
            setBackgroundColor(Color.TRANSPARENT)
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(14), dp(14), dp(14), dp(14))
            contentDescription = "Cerrar asistente"
            setOnClickListener {
                MainActivity.notifyAssistantStopRequested()
                hide()
                // Closing is a terminal action, unlike a temporary system
                // hide. Remove the transparent Flutter host as well so it
                // cannot remain the focused task above the user's app.
                AssistantOverlayActivity.finishActive()
            }
        }, LinearLayout.LayoutParams(dp(52), dp(52)))

        root.addView(controls, FrameLayout.LayoutParams(
            dp(420),
            dp(80),
            Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
        ).apply {
            leftMargin = dp(16)
            rightMargin = dp(16)
            bottomMargin = dp(24)
        })
        return root
    }

    private fun showMediaMenu(anchor: View) {
        val density = context.resources.displayMetrics.density
        fun dp(value: Int): Int = (value * density).toInt()
        val dark =
            (context.resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                android.content.res.Configuration.UI_MODE_NIGHT_YES
        val surfaceColor = if (dark) Color.rgb(42, 42, 46) else Color.WHITE
        val foregroundColor = if (dark) Color.WHITE else Color.BLACK
        val outlineColor = if (dark) Color.rgb(82, 82, 88) else Color.rgb(222, 222, 228)

        val menu = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = GradientDrawable().apply {
                color = android.content.res.ColorStateList.valueOf(surfaceColor)
                cornerRadius = dp(24).toFloat()
                setStroke(dp(1).coerceAtLeast(1), outlineColor)
            }
            clipToOutline = true
            setPadding(dp(6), dp(6), dp(6), dp(6))
        }

        lateinit var popup: PopupWindow
        fun action(icon: Int, label: String, onClick: () -> Unit) {
            val row = LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                gravity = Gravity.CENTER_VERTICAL
                setPadding(dp(14), 0, dp(16), 0)
                isClickable = true
                isFocusable = true
                val selectable = android.util.TypedValue()
                if (context.theme.resolveAttribute(
                        android.R.attr.selectableItemBackground,
                        selectable,
                        true
                    ) && selectable.resourceId != 0
                ) {
                    setBackgroundResource(selectable.resourceId)
                }
                setOnClickListener {
                    popup.dismiss()
                    onClick()
                }
            }
            row.addView(ImageView(context).apply {
                setImageResource(icon)
                setColorFilter(foregroundColor)
                scaleType = ImageView.ScaleType.CENTER_INSIDE
                contentDescription = label
            }, LinearLayout.LayoutParams(dp(24), dp(24)))
            row.addView(TextView(context).apply {
                text = label
                setTextColor(foregroundColor)
                textSize = 15f
                gravity = Gravity.CENTER_VERTICAL
            }, LinearLayout.LayoutParams(0, dp(52), 1f).apply {
                marginStart = dp(14)
            })
            menu.addView(
                row,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    dp(52)
                )
            )
        }

        action(R.drawable.ic_assistant_screen_share, "Share screen") {
            shareCurrentScreen()
        }
        action(R.drawable.ic_assistant_camera_front, "Front camera") {
            captureCamera(front = true)
        }
        action(R.drawable.ic_assistant_camera_rear, "Rear camera") {
            captureCamera(front = false)
        }

        popup = PopupWindow(
            menu,
            dp(248),
            ViewGroup.LayoutParams.WRAP_CONTENT,
            true
        ).apply {
            setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
            isOutsideTouchable = true
            isClippingEnabled = true
            elevation = dp(16).toFloat()
            animationStyle = android.R.style.Animation_Dialog
        }
        popup.showAtLocation(
            anchor.rootView,
            Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL,
            0,
            dp(116)
        )
    }

    private fun shareCurrentScreen() {
        if (!AssistantContextStore.hasScreenshot()) {
            updateState("Screen capture is not available", false)
            return
        }
        updateState("Attaching screen…", true)
        MainActivity.notifyAssistantScreenShareRequested()
    }

    private fun captureCamera(front: Boolean) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            updateState("Enable camera permission in Ollama settings", false)
            return
        }
        updateState(if (front) "Capturing front camera…" else "Capturing rear camera…", true)
        Thread {
            try {
                val bytes = ClusterMediaCapture.captureJpeg(context, front)
                val directory = File(context.cacheDir, "assistant-camera").apply { mkdirs() }
                val destination = File(
                    directory,
                    "${if (front) "front" else "rear"}-${System.currentTimeMillis()}.jpg"
                )
                FileOutputStream(destination).use { it.write(bytes) }
                MainActivity.notifyAssistantCameraCaptured(destination.absolutePath, front)
            } catch (error: Throwable) {
                Log.e("OllamaAssistant", "External camera capture failed", error)
                context.mainExecutor.execute {
                    updateState("Camera capture failed: ${error.message ?: "unknown error"}", false)
                }
            }
        }.start()
    }

    override fun onComputeInsets(outInsets: Insets) {
        super.onComputeInsets(outInsets)
        outInsets.contentInsets.set(0, 0, 0, 0)
        outInsets.touchableInsets = Insets.TOUCHABLE_INSETS_REGION
        val visiblePanel = panel
        if (visiblePanel == null || !visiblePanel.isLaidOut) {
            outInsets.touchableRegion.setEmpty()
            return
        }
        val location = IntArray(2)
        visiblePanel.getLocationInWindow(location)
        outInsets.touchableRegion.set(
            location[0],
            location[1],
            location[0] + visiblePanel.width,
            location[1] + visiblePanel.height
        )
    }

    override fun onShow(args: Bundle?, showFlags: Int) {
        super.onShow(args, showFlags)
        setKeepAwake(true)
        updateState("Escuchando…", true)
        val launch = Intent(context, AssistantOverlayActivity::class.java).apply {
            action = Intent.ACTION_ASSIST
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        context.startActivity(launch)
    }

    override fun onHandleScreenshot(screenshot: Bitmap?) {
        super.onHandleScreenshot(screenshot)
        if (screenshot == null) return
        try {
            val directory = File(context.cacheDir, "assistant")
            directory.mkdirs()
            directory.listFiles()?.forEach { it.delete() }
            val destination = File(directory, "screen-${System.currentTimeMillis()}.jpg")
            FileOutputStream(destination).use {
                screenshot.compress(Bitmap.CompressFormat.JPEG, 88, it)
            }
            AssistantContextStore.storeScreenshot(destination.absolutePath)
            Log.i("OllamaAssistant", "Context screenshot captured: ${destination.length()} bytes")
            Log.i("OllamaAssistant", "Context screenshot captured: ${destination.length()} bytes")
        } finally {
            screenshot.recycle()
        }
    }

    override fun onBackPressed() {
        Log.i("OllamaAssist", "SESSION onBackPressed")
        super.onBackPressed()
    }

    override fun onHide() {
        Log.i("OllamaAssist", "SESSION onHide (overlay kept alive)")
        // Do NOT finish the Flutter overlay here: keeping it alive preserves the
        // assistant's session history, the loaded model connection, and the
        // method channel, so the next assistant invocation resumes context.
        setKeepAwake(false)
        super.onHide()
    }

    override fun onDestroy() {
        Log.i("OllamaAssist", "SESSION onDestroy")
        val ownsActiveOverlay = activeSession === this
        if (ownsActiveOverlay) {
            activeSession = null
            // A superseded session can be destroyed after Android has already
            // created its replacement. Only the active session owns the
            // current Flutter host and is allowed to release it.
            AssistantOverlayActivity.finishActive()
        }
        super.onDestroy()
    }

    private fun updateState(label: String, busy: Boolean) {
        statusText?.text = label
        progress?.visibility = if (busy) View.VISIBLE else View.INVISIBLE
    }

    companion object {
        @Volatile
        private var activeSession: OllamaVoiceSession? = null

        fun updateActiveState(label: String, busy: Boolean) {
            activeSession?.updateState(label, busy)
        }
    }
}
