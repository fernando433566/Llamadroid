package com.example.ollama

import android.util.Log
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.Gravity
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivityLaunchConfigs

/**
 * Invisible Flutter host for the assistant runtime.
 *
 * The visible controls live in [OllamaVoiceSession], whose system-owned
 * window exposes only the panel as touchable without blocking the app
 * underneath. Keeping this activity non-touchable lets Flutter, plugins and
 * the existing method channel continue running while the user uses the screen.
 *
 * The overlay is deliberately not finished when the voice session hides; it
 * stays alive so the assistant retains its conversation history (persisted in
 * preferences) across invocations, matching the in-app assistant behavior.
 */
class AssistantOverlayActivity : MainActivity() {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun getInitialRoute(): String = "/assistant-overlay"

    override fun getBackgroundMode(): FlutterActivityLaunchConfigs.BackgroundMode =
        FlutterActivityLaunchConfigs.BackgroundMode.transparent

    override fun onCreate(savedInstanceState: Bundle?) {
        activeOverlay = this
        super.onCreate(savedInstanceState)
        configureInvisibleRuntimeWindow()
    }

    override fun onPostResume() {
        super.onPostResume()
        configureInvisibleRuntimeWindow()
        // This activity only hosts Flutter and must not become a transparent,
        // full-screen task above the app the user was using. The system-owned
        // VoiceInteractionSession remains visible after this task is moved
        // behind it, while taps outside its small touchable panel reach the
        // original foreground application.
        mainHandler.postDelayed({
            if (!isFinishing && !isDestroyed) moveTaskToBack(true)
        }, 350L)
    }

    private fun configureInvisibleRuntimeWindow() {
        window.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window.clearFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND)
        window.addFlags(
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
        )
        window.attributes = window.attributes.apply {
            alpha = 0f
            gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
            width = WindowManager.LayoutParams.MATCH_PARENT
            height = WindowManager.LayoutParams.MATCH_PARENT
            dimAmount = 0f
        }
    }

    override fun onPause() { Log.e("OllamaAssist", "OVERLAY onPause"); super.onPause() }
    override fun onStop() { Log.e("OllamaAssist", "OVERLAY onStop"); super.onStop() }
    override fun onDestroy() {
        Log.e("OllamaAssist", "OVERLAY onDestroy finishing=$isFinishing")
        mainHandler.removeCallbacksAndMessages(null)
        if (activeOverlay === this) activeOverlay = null
        super.onDestroy()
    }

    companion object {
        @Volatile
        private var activeOverlay: AssistantOverlayActivity? = null

        fun finishActive() {
            activeOverlay?.runOnUiThread { activeOverlay?.finish() }
        }
    }
}
