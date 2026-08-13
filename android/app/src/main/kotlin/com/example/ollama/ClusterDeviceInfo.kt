package com.example.ollama

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.os.Build
import android.provider.Settings
import androidx.core.content.ContextCompat
import org.json.JSONObject

object ClusterDeviceInfo {
    fun asMap(
        context: Context,
        rpcPort: Int? = null,
        selectedComputeDevice: String? = null,
        rpcRunning: Boolean = false,
        sharedSensors: Boolean? = null
    ): Map<String, Any?> {
        val cameraManager = context.getSystemService(CameraManager::class.java)
        var frontCamera = false
        var rearCamera = false
        try {
            cameraManager?.cameraIdList?.forEach { id ->
                when (cameraManager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING)) {
                    CameraCharacteristics.LENS_FACING_FRONT -> frontCamera = true
                    CameraCharacteristics.LENS_FACING_BACK -> rearCamera = true
                }
            }
        } catch (_: Exception) {
            // A camera provider can be temporarily unavailable while the
            // device is booting. The next host refresh will query it again.
        }

        val remoteCameraAllowed = sharedSensors == null || (sharedSensors &&
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.CAMERA) ==
            PackageManager.PERMISSION_GRANTED)
        val remoteMicrophoneAllowed = sharedSensors == null || (sharedSensors &&
            ContextCompat.checkSelfPermission(context, android.Manifest.permission.RECORD_AUDIO) ==
            PackageManager.PERMISSION_GRANTED)
        val entities = mapOf(
            "compute" to true,
            "cameraFront" to (frontCamera && remoteCameraAllowed),
            "cameraRear" to (rearCamera && remoteCameraAllowed),
            "microphone" to (context.packageManager.hasSystemFeature(
                PackageManager.FEATURE_MICROPHONE
            ) && remoteMicrophoneAllowed),
            // Remote screen capture needs a MediaProjection grant and token
            // owned by an Activity on that worker. Do not advertise it until
            // that explicit pairing flow exists.
            "screen" to (sharedSensors == null)
        )
        val selected = selectedComputeDevice?.trim().orEmpty().ifEmpty { "auto" }
        val explicitSingleDevice = !selected.equals("auto", ignoreCase = true)
        return mapOf(
            "protocol" to 1,
            "app" to "ollama-android",
            "name" to deviceName(context),
            "type" to deviceType(context),
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "androidVersion" to Build.VERSION.RELEASE,
            "architecture" to Build.SUPPORTED_ABIS.firstOrNull(),
            "rpcPort" to rpcPort,
            "controlPort" to rpcPort?.plus(1),
            "rpcRunning" to rpcRunning,
            "selectedComputeDevice" to selected,
            // Exact RPC device indexing is only promised when the worker was
            // started with an explicit -d selection.
            "rpcDeviceCount" to 1,
            "singleDeviceGuaranteed" to explicitSingleDevice,
            "mediaCapture" to (sharedSensors == true),
            "entities" to entities
        )
    }

    fun asJson(
        context: Context,
        rpcPort: Int,
        selectedComputeDevice: String,
        rpcRunning: Boolean,
        sharedSensors: Boolean = false
    ): String = JSONObject(
        asMap(context, rpcPort, selectedComputeDevice, rpcRunning, sharedSensors)
    ).toString()

    private fun deviceName(context: Context): String {
        val configured = listOf("device_name", "bluetooth_name")
            .firstNotNullOfOrNull { key ->
                runCatching {
                    Settings.Global.getString(context.contentResolver, key)
                        ?.trim()
                        ?.takeIf { it.isNotEmpty() }
                }.getOrNull()
            }
        return configured ?: Build.MODEL.ifBlank { "Android device" }
    }

    private fun deviceType(context: Context): String {
        val uiMode = context.getSystemService(UiModeManager::class.java)
            ?.currentModeType
        return when (uiMode) {
            Configuration.UI_MODE_TYPE_TELEVISION,
            Configuration.UI_MODE_TYPE_DESK -> "desktop"
            else -> if (context.resources.configuration.smallestScreenWidthDp >= 600) {
                "tablet"
            } else {
                "phone"
            }
        }
    }
}
