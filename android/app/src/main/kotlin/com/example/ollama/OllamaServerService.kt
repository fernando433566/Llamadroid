package com.example.ollama

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import java.io.File
import kotlin.concurrent.thread

/**
 * Foreground service that runs the bundled `ollama serve` process.
 *
 * Flutter starts it through MainActivity ("startServer") with the user's
 * settings as intent extras. The settings are also saved, so when Android
 * restarts the service by itself (START_STICKY, no extras) the server comes
 * back with the same configuration.
 *
 * Starting it again with the same settings does nothing; with different
 * settings the server is restarted.
 */
class OllamaServerService : Service() {

    /** Everything that changes how the server process is launched. */
    private data class ServerConfig(
        val maxLoadedModels: Int,      // < 0 means "no limit"
        val exposeToLan: Boolean,      // listen on 0.0.0.0 instead of localhost
        val computeMode: String,       // adaptive | gpu_only | cpu_only | forced | synergy | hybrid
        val forcedDevice: String,      // used when computeMode == "forced"
        val forceCpuSafe: Boolean,     // one-shot "run on CPU" recovery switch
        val rpcServers: String,        // "host:port,host:port" cluster workers
        val multimodalBackend: String, // where vision/audio projectors run
    )

    private val lock = Any()
    private var process: Process? = null
    private var activeConfig: ServerConfig? = null
    private var starting = false

    /** Bumped on every start/stop so a stale launcher thread can tell it lost. */
    private var generation = 0

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopServer()
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, createNotification())
        startServer(readConfig(intent))
        return START_STICKY
    }

    override fun onDestroy() {
        stopServer()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ---------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------

    /** Reads each setting from the intent if present, else from the last saved value. */
    private fun readConfig(intent: Intent?): ServerConfig {
        val prefs = getSharedPreferences(PREFS_NAME, MODE_PRIVATE)
        val editor = prefs.edit()

        fun int(key: String, default: Int): Int =
            if (intent?.hasExtra(key) == true) intent.getIntExtra(key, default).also { editor.putInt(key, it) }
            else prefs.getInt(key, default)

        fun bool(key: String, default: Boolean): Boolean =
            if (intent?.hasExtra(key) == true) intent.getBooleanExtra(key, default).also { editor.putBoolean(key, it) }
            else prefs.getBoolean(key, default)

        fun string(key: String, default: String): String =
            if (intent?.hasExtra(key) == true) (intent.getStringExtra(key) ?: default).also { editor.putString(key, it) }
            else prefs.getString(key, default) ?: default

        val config = ServerConfig(
            maxLoadedModels = int("maxLoadedModels", 1),
            exposeToLan = bool("exposeToLan", false),
            computeMode = string("computeMode", "adaptive"),
            forcedDevice = string("forcedDevice", "gpu"),
            // Not saved: after a crash-restart we want to try the GPU again.
            forceCpuSafe = intent?.getBooleanExtra("forceCpuSafe", false) ?: false,
            rpcServers = string("rpcServers", ""),
            multimodalBackend = string("multimodalBackendDevice", ""),
        )
        editor.apply()
        return config
    }

    /** True when every GPU must be hidden from llama.cpp and everything runs on the CPU. */
    private fun ServerConfig.gpuDisabled(): Boolean =
        DeviceQuirks.isEmulator() ||
            computeMode == "cpu_only" ||
            (computeMode == "forced" && forcedDevice != "gpu") ||
            forceCpuSafe

    /** Environment variables for `ollama serve`. */
    private fun buildEnvironment(config: ServerConfig, env: MutableMap<String, String>) {
        val nativeDir = File(applicationInfo.nativeLibraryDir)
        val cpuOnly = config.gpuDisabled()
        val qualcomm = DeviceQuirks.isQualcomm()
        val libraryPath = mutableListOf(nativeDir.absolutePath)

        env["HOME"] = filesDir.absolutePath
        env["GIN_MODE"] = "release" // no per-route debug spam in logcat
        env["OLLAMA_MODELS"] = File(filesDir, "models").apply { mkdirs() }.absolutePath
        env["OLLAMA_HOST"] = if (config.exposeToLan) "0.0.0.0:11434" else "127.0.0.1:11434"
        env["OLLAMA_NO_CLOUD"] = "1"
        env["OLLAMA_LOAD_TIMEOUT"] = "10m"
        env["OLLAMA_MAX_LOADED_MODELS"] =
            if (config.maxLoadedModels < 0) Int.MAX_VALUE.toString() else config.maxLoadedModels.toString()

        // Phones share one pool of RAM between CPU and GPU.
        env["OLLAMA_IGPU_ENABLE"] = "1"
        // Every parallel slot reserves its own KV cache. A phone serves one chat
        // at a time, so a single slot saves a lot of RAM.
        env["OLLAMA_NUM_PARALLEL"] = "1"
        // Flash attention kernels are still unreliable on mobile GPU drivers.
        env["OLLAMA_FLASH_ATTENTION"] = "0"

        // GPU backend choice:
        //  - Qualcomm Adreno: OpenCL. Adreno drivers fail to build llama.cpp's
        //    Vulkan pipelines (vkCreateComputePipeline -> ErrorUnknown), while
        //    the OpenCL backend is maintained by Qualcomm for these GPUs.
        //    libggml-opencl.so needs the phone's /vendor/lib64/libOpenCL.so.
        //  - Everything else (Mali, Xclipse, PowerVR...): Vulkan.
        //  - CPU-only modes: hide Vulkan and don't expose the OpenCL driver.
        if (cpuOnly || qualcomm) {
            env["GGML_VK_VISIBLE_DEVICES"] = "-1"
        }
        if (!cpuOnly && qualcomm) {
            libraryPath += "/vendor/lib64"
        }
        if (!cpuOnly && !qualcomm) {
            // Fall back to system memory if a device-local allocation is refused.
            env["GGML_VK_ALLOW_SYSMEM_FALLBACK"] = "1"
        }
        Log.i(TAG, "GPU backend: ${when { cpuOnly -> "none (CPU)"; qualcomm -> "OpenCL"; else -> "Vulkan" }}; " +
            "model=${Build.MODEL}; computeMode=${config.computeMode}")

        setOrRemove(env, "OLLAMA_RPC_SERVERS", config.rpcServers)

        // libmtmd can pin the vision/audio projector to a specific ggml device.
        val projectorDevice = when (config.multimodalBackend) {
            "LOCAL_CPU" -> "CPU"
            "LOCAL_GPU" -> when { cpuOnly -> "CPU"; qualcomm -> "GPUOpenCL"; else -> "Vulkan0" }
            "LOCAL_NPU" -> "HTP0"
            else -> config.multimodalBackend // a cluster worker, e.g. "RPC0"
        }
        setOrRemove(env, "MTMD_BACKEND_DEVICE", projectorDevice)

        // Snapdragon NPU (Hexagon) runtime, only present in HTP builds.
        val htpDir = File(filesDir, "snapdragon-htp")
        val hasHtp = File(nativeDir, "libggml-htp.so").exists() &&
            File(nativeDir, "libhtp_ops.so").exists() &&
            File(htpDir, "libhtp_ops_skel.so").exists()
        if (hasHtp) {
            env["DSP_LIBRARY_PATH"] = htpDir.absolutePath
            libraryPath += listOf("/vendor/lib64", "/system/lib64")
        }

        env["LD_LIBRARY_PATH"] = libraryPath.distinct().joinToString(":")
    }

    private fun setOrRemove(env: MutableMap<String, String>, key: String, value: String) {
        if (value.isNotBlank()) env[key] = value else env.remove(key)
    }

    // ---------------------------------------------------------------------
    // Process lifecycle
    // ---------------------------------------------------------------------

    private fun startServer(config: ServerConfig) {
        val myGeneration = synchronized(lock) {
            val running = starting || process?.isAlive == true
            if (running && activeConfig == config) {
                Log.i(TAG, "Server already running with this configuration")
                return
            }
            if (running) {
                Log.i(TAG, "Configuration changed; restarting server")
                process?.destroy()
                process = null
            }
            starting = true
            activeConfig = config
            ++generation
        }

        // Starting a process and reading its output blocks, so do it off the main thread.
        thread(name = "ollama-server") { runServer(config, myGeneration) }
    }

    private fun runServer(config: ServerConfig, myGeneration: Int) {
        val binary = File(applicationInfo.nativeLibraryDir, "libollama_exec.so")
        if (!binary.exists()) {
            Log.e(TAG, "Ollama binary not found at ${binary.absolutePath}")
            finish(myGeneration, null)
            return
        }

        var launched: Process? = null
        try {
            val builder = ProcessBuilder(binary.absolutePath, "serve")
                .directory(filesDir)
                .redirectErrorStream(true)
            buildEnvironment(config, builder.environment())

            Log.i(TAG, "Starting server; host=${builder.environment()["OLLAMA_HOST"]}")
            launched = builder.start()

            val stillWanted = synchronized(lock) {
                (generation == myGeneration).also { if (it) { process = launched; starting = false } }
            }
            if (!stillWanted) {
                launched.destroy()
                return
            }

            // Forward server output to logcat (tag "OllamaServer") until it exits.
            launched.inputStream.bufferedReader().useLines { lines ->
                lines.forEach { Log.i(SERVER_LOG_TAG, it) }
            }
            Log.i(TAG, "Server stopped with exit code ${launched.waitFor()}")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start server", e)
        }
        finish(myGeneration, launched)
    }

    /** Clears state after the server process ended, unless a newer start took over. */
    private fun finish(myGeneration: Int, ended: Process?) {
        val isCurrent = synchronized(lock) {
            (generation == myGeneration).also {
                if (it) {
                    if (process === ended) process = null
                    starting = false
                }
            }
        }
        if (isCurrent) stopSelf()
    }

    private fun stopServer() {
        val running = synchronized(lock) {
            generation++
            starting = false
            activeConfig = null
            process.also { process = null }
        }
        running?.destroy()
    }

    // ---------------------------------------------------------------------
    // Notification
    // ---------------------------------------------------------------------

    private fun createNotificationChannel() {
        val channel = NotificationChannel(CHANNEL_ID, "Ollama Server Channel", NotificationManager.IMPORTANCE_LOW)
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    private fun createNotification(): Notification {
        val stopIntent = Intent(this, OllamaServerService::class.java).setAction(ACTION_STOP)
        val stopPendingIntent = PendingIntent.getService(this, 0, stopIntent, PendingIntent.FLAG_IMMUTABLE)

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Ollama Server")
            .setContentText("Ollama is running in the background")
            .setSmallIcon(android.R.drawable.ic_media_play)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopPendingIntent)
            .build()
    }

    companion object {
        const val ACTION_STOP = "STOP"
        private const val TAG = "OllamaService"
        private const val SERVER_LOG_TAG = "OllamaServer"
        private const val PREFS_NAME = "ollama_server"
        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "ollama_server_channel"
    }
}

/** Device detection used to pick safe GPU settings. */
object DeviceQuirks {
    fun isEmulator(): Boolean =
        Build.FINGERPRINT.startsWith("generic") ||
            Build.FINGERPRINT.contains("emulator", ignoreCase = true) ||
            Build.MODEL.contains("Emulator", ignoreCase = true) ||
            Build.MODEL.contains("Android SDK built for", ignoreCase = true) ||
            Build.HARDWARE.contains("goldfish", ignoreCase = true) ||
            Build.HARDWARE.contains("ranchu", ignoreCase = true)

    fun isQualcomm(): Boolean {
        val soc = "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}"
        return Regex("qualcomm|qcom|qti|snapdragon|sm[0-9]{4}|kalama|pineapple", RegexOption.IGNORE_CASE)
            .containsMatchIn("$soc ${Build.HARDWARE} ${Build.BOARD} ${Build.DEVICE}")
    }
}
