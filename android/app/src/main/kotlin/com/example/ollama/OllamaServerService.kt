package com.example.ollama

import android.app.*
import android.content.Intent
import android.os.IBinder
import android.os.Build
import androidx.core.app.NotificationCompat
import java.io.File
import android.util.Log
import kotlin.concurrent.thread

class OllamaServerService : Service() {
    private val processLock = Any()
    private var process: Process? = null
    private var processGeneration = 0
    private var processStarting = false
    private var activeConfiguration: String? = null
    private val NOTIFICATION_ID = 1
    private val CHANNEL_ID = "ollama_server_channel"

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == "STOP") {
            stopServer()
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, createNotification())
        val servicePreferences = getSharedPreferences("ollama_server", MODE_PRIVATE)
        val maxLoadedModels = if (intent?.hasExtra("maxLoadedModels") == true) {
            intent.getIntExtra("maxLoadedModels", 1).also {
                servicePreferences.edit().putInt("maxLoadedModels", it).apply()
            }
        } else {
            servicePreferences.getInt("maxLoadedModels", 1)
        }
        val exposeToLan = if (intent?.hasExtra("exposeToLan") == true) {
            intent.getBooleanExtra("exposeToLan", false).also {
                servicePreferences.edit().putBoolean("exposeToLan", it).apply()
            }
        } else {
            servicePreferences.getBoolean("exposeToLan", false)
        }
        val computeMode = if (intent?.hasExtra("computeMode") == true) {
            (intent.getStringExtra("computeMode") ?: "adaptive").also {
                servicePreferences.edit().putString("computeMode", it).apply()
            }
        } else {
            servicePreferences.getString("computeMode", "adaptive") ?: "adaptive"
        }
        val forceCpuSafe = intent?.getBooleanExtra("forceCpuSafe", false) ?: false
        val forcedDevice = intent?.getStringExtra("forcedDevice") ?: "gpu"
        val rpcServers = if (intent?.hasExtra("rpcServers") == true) {
            (intent.getStringExtra("rpcServers") ?: "").also {
                servicePreferences.edit().putString("rpcServers", it).apply()
            }
        } else {
            servicePreferences.getString("rpcServers", "") ?: ""
        }
        val multimodalBackendDevice =
            if (intent?.hasExtra("multimodalBackendDevice") == true) {
                (intent.getStringExtra("multimodalBackendDevice") ?: "").also {
                    servicePreferences.edit().putString("multimodalBackendDevice", it).apply()
                }
            } else {
                servicePreferences.getString("multimodalBackendDevice", "") ?: ""
            }
        val synergyCpuPercent = intent?.getIntExtra("synergyCpuPercent", 50) ?: 50
        val synergyGpuPercent = intent?.getIntExtra("synergyGpuPercent", 50) ?: 50
        val synergyNpuPercent = intent?.getIntExtra("synergyNpuPercent", 0) ?: 0
        startServer(maxLoadedModels, exposeToLan, computeMode, forcedDevice, forceCpuSafe, rpcServers,
            multimodalBackendDevice,
            synergyCpuPercent, synergyGpuPercent, synergyNpuPercent)

        return START_STICKY
    }

    private fun startServer(
        maxLoadedModels: Int,
        exposeToLan: Boolean,
        computeMode: String,
        forcedDevice: String,
        forceCpuSafe: Boolean,
        rpcServers: String,
        multimodalBackendDevice: String,
        synergyCpuPercent: Int,
        synergyGpuPercent: Int,
        synergyNpuPercent: Int
    ) {
        val disableVulkan = isAndroidEmulator() ||
            computeMode == "cpu_only" ||
            (computeMode == "forced" && forcedDevice != "gpu") ||
            forceCpuSafe ||
            (computeMode != "gpu_only" && hasKnownUnstableVulkanDriver())
        val configuration = "$maxLoadedModels:$exposeToLan:$computeMode:$forcedDevice:$disableVulkan:$rpcServers:" +
            "$multimodalBackendDevice:" +
            "$synergyCpuPercent:$synergyGpuPercent:$synergyNpuPercent"
        val generation = synchronized(processLock) {
            if ((processStarting || process?.isAlive == true) &&
                activeConfiguration == configuration) {
                Log.i("OllamaService", "Server is already running with the requested configuration")
                return
            }
            if (processStarting || process?.isAlive == true) {
                Log.i("OllamaService", "Restarting server because its configuration changed")
                process?.destroy()
                process = null
            }
            processStarting = true
            processGeneration += 1
            activeConfiguration = configuration
            processGeneration
        }
        thread {
            var startedProcess: Process? = null
            try {
                val nativeDir = File(applicationInfo.nativeLibraryDir)
                val ollamaBin = File(nativeDir, "libollama_exec.so")
                
                if (!ollamaBin.exists()) {
                    Log.e("OllamaService", "Ollama binary not found at ${ollamaBin.absolutePath}")
                    synchronized(processLock) {
                        if (processGeneration == generation) processStarting = false
                    }
                    stopSelf()
                    return@thread
                }

                val pb = ProcessBuilder(ollamaBin.absolutePath, "serve")
                pb.directory(filesDir)
                pb.redirectErrorStream(true)
                
                val modelsDir = File(filesDir, "models").apply { mkdirs() }
                val env = pb.environment()
                env["OLLAMA_MODELS"] = modelsDir.absolutePath
                env["OLLAMA_HOST"] = if (exposeToLan) "0.0.0.0:11434" else "127.0.0.1:11434"
                env["OLLAMA_NO_CLOUD"] = "1"
                env["OLLAMA_IGPU_ENABLE"] = "1"
                // Mobile devices share RAM between CPU and GPU. The user can
                // choose a strict resident-model limit or an effectively
                // unlimited value from Flutter settings.
                env["OLLAMA_MAX_LOADED_MODELS"] = if (maxLoadedModels < 0) {
                    Int.MAX_VALUE.toString()
                } else {
                    maxLoadedModels.toString()
                }
                // Prefer Vulkan layer offload on real phones, but avoid flash
                // attention kernels that are still unreliable on some Android
                // Vulkan drivers. The server retries failed GPU loads on CPU.
                env["OLLAMA_FLASH_ATTENTION"] = "0"
                env["OLLAMA_LOAD_TIMEOUT"] = "10m"
                if (!disableVulkan && isQualcommSoc()) {
                    // Adreno GPUs share physical memory with the CPU. Let the
                    // Vulkan allocator use system memory if a device-local
                    // allocation is rejected by the Android driver.
                    env["GGML_VK_ALLOW_SYSMEM_FALLBACK"] = "1"
                    if (hasKnownUnstableVulkanDriver()) {
                        // Conservative override for explicit GPU diagnostics
                        // on affected Tab S8 firmware. Adaptive mode stays on
                        // CPU until that driver can complete a model load.
                        env["GGML_VK_DISABLE_ASYNC"] = "1"
                        env["GGML_VK_DISABLE_COOPMAT"] = "1"
                        env["GGML_VK_DISABLE_COOPMAT2"] = "1"
                    }
                    Log.i("OllamaService", "Enabled Qualcomm/Adreno Vulkan compatibility profile")
                }
                if (rpcServers.isNotBlank()) {
                    env["OLLAMA_RPC_SERVERS"] = rpcServers
                } else {
                    env.remove("OLLAMA_RPC_SERVERS")
                }
                val resolvedMultimodalBackend = when (multimodalBackendDevice) {
                    "LOCAL_CPU" -> "CPU"
                    "LOCAL_GPU" -> if (disableVulkan) "CPU" else "Vulkan0"
                    "LOCAL_NPU" -> "HTP0"
                    else -> multimodalBackendDevice
                }
                if (resolvedMultimodalBackend.isNotBlank()) {
                    // libmtmd supports selecting a concrete ggml device by
                    // name. This keeps native audio/vision projection on the
                    // selected host or exact RPC worker instead of relying on
                    // whichever GPU happens to register first.
                    env["MTMD_BACKEND_DEVICE"] = resolvedMultimodalBackend
                } else {
                    env.remove("MTMD_BACKEND_DEVICE")
                }
                if (computeMode == "synergy") {
                    env["OLLAMA_SYNERGY_CPU_PERCENT"] = synergyCpuPercent.coerceIn(0, 100).toString()
                    env["OLLAMA_SYNERGY_GPU_PERCENT"] = synergyGpuPercent.coerceIn(0, 100).toString()
                    env["OLLAMA_SYNERGY_NPU_PERCENT"] = synergyNpuPercent.coerceIn(0, 100).toString()
                }
                if (disableVulkan) {
                    // The Android emulator exposes SwiftShader as a Vulkan GPU.
                    // llama.cpp can discover it, but model allocation crashes in
                    // the emulator driver. Keep real devices on Vulkan and use
                    // the reliable CPU backend only in virtual devices.
                    env["GGML_VK_VISIBLE_DEVICES"] = "-1"
                    Log.i(
                        "OllamaService",
                        "Vulkan disabled for stable CPU inference; model=${Build.MODEL}; computeMode=$computeMode"
                    )
                }
                val htpDir = File(filesDir, "snapdragon-htp")
                val htpRuntimePresent = File(nativeDir, "libggml-htp.so").exists() &&
                    File(nativeDir, "libhtp_ops.so").exists() &&
                    File(htpDir, "libhtp_ops_skel.so").exists()
                if (htpRuntimePresent) {
                    // FastRPC loads the Hexagon skeleton through this path.
                    // Vendor library paths are required for libcdsprpc.so on
                    // Qualcomm firmware and are only added for an HTP build.
                    env["DSP_LIBRARY_PATH"] = htpDir.absolutePath
                    env["LD_LIBRARY_PATH"] =
                        "${nativeDir.absolutePath}:/vendor/lib64:/system/lib64"
                } else {
                    env["LD_LIBRARY_PATH"] = nativeDir.absolutePath
                }
                env["HOME"] = filesDir.absolutePath
                
                Log.i(
                    "OllamaService",
                    "Starting server from ${ollamaBin.absolutePath}; host=${env["OLLAMA_HOST"]}; maxLoadedModels=${env["OLLAMA_MAX_LOADED_MODELS"]}"
                )
                val launchedProcess = pb.start()
                startedProcess = launchedProcess
                val accepted = synchronized(processLock) {
                    if (processGeneration == generation) {
                        process = launchedProcess
                        processStarting = false
                        true
                    } else {
                        false
                    }
                }
                if (!accepted) {
                    launchedProcess.destroy()
                    return@thread
                }

                launchedProcess.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { Log.i("OllamaServer", it) }
                }
                
                val exitCode = launchedProcess.waitFor()
                Log.i("OllamaService", "Server stopped with exit code $exitCode")
                val shouldStop = synchronized(processLock) {
                    if (processGeneration == generation && process === launchedProcess) {
                        process = null
                        true
                    } else {
                        false
                    }
                }
                if (shouldStop) stopSelf()
            } catch (e: Exception) {
                Log.e("OllamaService", "Failed to start server", e)
                val shouldStop = synchronized(processLock) {
                    if (processGeneration == generation) {
                        if (process === startedProcess) process = null
                        processStarting = false
                        true
                    } else {
                        false
                    }
                }
                if (shouldStop) stopSelf()
            }
        }
    }

    private fun stopServer() {
        val running = synchronized(processLock) {
            processGeneration += 1
            processStarting = false
            val current = process
            process = null
            current
        }
        running?.destroy()
    }

    override fun onDestroy() {
        stopServer()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun isAndroidEmulator(): Boolean {
        return Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("emulator", ignoreCase = true) ||
            Build.MODEL.contains("Emulator", ignoreCase = true) ||
            Build.MODEL.contains("Android SDK built for", ignoreCase = true) ||
            Build.HARDWARE.contains("goldfish", ignoreCase = true) ||
            Build.HARDWARE.contains("ranchu", ignoreCase = true)
    }

    private fun isQualcommSoc(): Boolean {
        val soc = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}"
        } else {
            ""
        }
        return Regex(
            "qualcomm|qcom|snapdragon|sm[0-9]{4}|kalama|pineapple",
            RegexOption.IGNORE_CASE
        ).containsMatchIn("$soc ${Build.HARDWARE} ${Build.BOARD} ${Build.DEVICE}")
    }

    /**
     * Samsung's Android 16 firmware for the Tab S8 family currently crashes
     * the bundled llama.cpp Vulkan backend while allocating model tensors,
     * even for a request with zero GPU layers. Adaptive mode therefore starts
     * on CPU on these devices instead of returning a misleading Request Fail.
     * GPU-only remains available as an explicit diagnostic/override.
     */
    private fun hasKnownUnstableVulkanDriver(): Boolean {
        val normalizedModel = Build.MODEL.uppercase().replace("_", "-")
        return Build.MANUFACTURER.equals("samsung", ignoreCase = true) &&
            (normalizedModel.startsWith("SM-X700") ||
                normalizedModel.startsWith("SM-X800") ||
                normalizedModel.startsWith("SM-X900"))
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val serviceChannel = NotificationChannel(
                CHANNEL_ID,
                "Ollama Server Channel",
                NotificationManager.IMPORTANCE_LOW
            )
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(serviceChannel)
        }
    }

    private fun createNotification(): Notification {
        val stopIntent = Intent(this, OllamaServerService::class.java).apply {
            action = "STOP"
        }
        val stopPendingIntent = PendingIntent.getService(
            this, 0, stopIntent,
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Ollama Server")
            .setContentText("Ollama is running in the background")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPendingIntent)
            .build()
    }
}
