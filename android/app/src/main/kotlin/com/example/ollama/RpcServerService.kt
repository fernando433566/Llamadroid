package com.example.ollama

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.io.File
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketException
import java.security.MessageDigest
import kotlin.concurrent.thread

class RpcServerService : Service() {
    private val processLock = Any()
    private var process: Process? = null
    private var generation = 0
    @Volatile private var controlServer: ServerSocket? = null
    @Volatile private var shareMedia = false
    @Volatile private var mediaToken = ""

    override fun onCreate() {
        super.onCreate()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "llama.cpp RPC worker", NotificationManager.IMPORTANCE_LOW)
            )
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopWorker()
            stopSelf()
            return START_NOT_STICKY
        }

        val port = intent?.getIntExtra("port", DEFAULT_PORT)
            ?.coerceIn(1, 65535) ?: DEFAULT_PORT
        val device = intent?.getStringExtra("device")?.trim().orEmpty()
        val useCache = intent?.getBooleanExtra("useCache", false) ?: false
        shareMedia = intent?.getBooleanExtra("shareMedia", false) ?: false
        mediaToken = intent?.getStringExtra("mediaToken")?.trim().orEmpty()
        promoteToForeground(port)
        startWorker(port, device, useCache)
        return START_STICKY
    }

    private fun startWorker(port: Int, device: String, useCache: Boolean) {
        val currentGeneration = synchronized(processLock) {
            generation += 1
            process?.destroy()
            process = null
            stopControlServer()
            generation
        }
        thread(name = "llama-rpc-worker") {
            val nativeDir = File(applicationInfo.nativeLibraryDir)
            val binary = File(nativeDir, "libggml_rpc_server_exec.so")
            if (!binary.exists()) {
                updateState(false, "RPC worker binary is missing")
                stopSelf()
                return@thread
            }

            val stagedVendorOpenCl = if (hasKnownUnstableAdrenoDriver()) {
                stageVendorOpenCl()
            } else null
            val args = mutableListOf(binary.absolutePath, "-H", "0.0.0.0", "-p", port.toString())
            val requestedDevice = device.takeUnless {
                it.isEmpty() || it.equals("auto", ignoreCase = true)
            }
            val fallbackDevice = if (
                requestedDevice == null &&
                hasKnownUnstableAdrenoDriver() &&
                stagedVendorOpenCl != null &&
                File(nativeDir, "libggml-opencl.so").exists()
            ) "GPUOpenCL" else null
            (requestedDevice ?: fallbackDevice)?.let {
                args.addAll(listOf("-d", it))
            }
            if (useCache) args.add("-c")

            try {
                val builder = ProcessBuilder(args)
                    .directory(filesDir)
                    .redirectErrorStream(true)
                builder.environment().apply {
                    this["LD_LIBRARY_PATH"] = listOfNotNull(
                        stagedVendorOpenCl?.parentFile?.absolutePath,
                        nativeDir.absolutePath
                    ).joinToString(":")
                    this["HOME"] = filesDir.absolutePath
                    this["LLAMA_CACHE"] = File(filesDir, "rpc-cache").apply { mkdirs() }.absolutePath
                    if (isQualcommSoc()) {
                        this["GGML_VK_ALLOW_SYSMEM_FALLBACK"] = "1"
                        if (hasKnownUnstableAdrenoDriver()) {
                            this["GGML_VK_DISABLE_ASYNC"] = "1"
                            this["GGML_VK_DISABLE_COOPMAT"] = "1"
                            this["GGML_VK_DISABLE_COOPMAT2"] = "1"
                            this["GGML_VK_DISABLE_BUFFER_DEVICE_ADDRESS"] = "1"
                            this["GGML_VK_DISABLE_SUBGROUP_ARITHMETIC"] = "1"
                        }
                    }
                }
                val launched = builder.start()
                val accepted = synchronized(processLock) {
                    if (generation == currentGeneration) {
                        process = launched
                        true
                    } else false
                }
                if (!accepted) {
                    launched.destroy()
                    return@thread
                }
                startControlServer(port, requestedDevice ?: fallbackDevice ?: "auto")
                updateState(true, null, port)
                launched.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { Log.i("LlamaRpcWorker", it) }
                }
                val exitCode = launched.waitFor()
                Log.i("LlamaRpcWorker", "RPC worker stopped with exit code $exitCode")
                val ownsGeneration = synchronized(processLock) {
                    if (generation == currentGeneration && process === launched) {
                        process = null
                        true
                    } else {
                        false
                    }
                }
                if (!ownsGeneration) return@thread
                stopControlServer()
                updateState(false, if (exitCode == 0) null else "RPC worker exited with code $exitCode", port)
                stopSelf()
            } catch (error: Exception) {
                val ownsGeneration = synchronized(processLock) {
                    generation == currentGeneration
                }
                if (!ownsGeneration) {
                    Log.d("LlamaRpcWorker", "Previous RPC worker stopped during replacement")
                    return@thread
                }
                Log.e("LlamaRpcWorker", "Unable to start RPC worker", error)
                stopControlServer()
                updateState(false, error.message ?: "Unable to start RPC worker", port)
                stopSelf()
            }
        }
    }

    private fun stopWorker() {
        synchronized(processLock) {
            generation += 1
            process?.destroy()
            process = null
            stopControlServer()
        }
        updateState(false, null)
    }

    private fun updateState(running: Boolean, error: String?, port: Int = DEFAULT_PORT) {
        getSharedPreferences(PREFERENCES, MODE_PRIVATE).edit()
            .putBoolean("running", running)
            .putInt("port", port)
            .putString("error", error)
            .apply()
    }

    private fun notification(port: Int): Notification {
        val stopIntent = Intent(this, RpcServerService::class.java).apply { action = ACTION_STOP }
        val stopAction = PendingIntent.getService(
            this,
            2,
            stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("llama.cpp RPC worker")
            .setContentText(
                if (shareMedia) {
                    "Compute and paired media exposed to the trusted LAN on port $port"
                } else {
                    "Compute exposed to the trusted LAN on port $port"
                }
            )
            .setSmallIcon(android.R.drawable.ic_menu_share)
            .setOngoing(true)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopAction)
            .build()
    }

    private fun promoteToForeground(port: Int) {
        val notification = notification(port)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            var types = 0
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            }
            if (shareMedia && hasPermission(android.Manifest.permission.CAMERA)) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
            }
            if (shareMedia && hasPermission(android.Manifest.permission.RECORD_AUDIO)) {
                types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
            }
            if (types != 0) {
                startForeground(NOTIFICATION_ID, notification, types)
                return
            }
        }
        startForeground(NOTIFICATION_ID, notification)
    }

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED

    private fun startControlServer(rpcPort: Int, selectedDevice: String) {
        stopControlServer()
        val controlPort = rpcPort + 1
        thread(name = "ollama-cluster-control") {
            try {
                val server = ServerSocket(controlPort)
                controlServer = server
                Log.i("LlamaRpcWorker", "Cluster metadata available on 0.0.0.0:$controlPort")
                while (!server.isClosed) {
                    val client = server.accept()
                    thread(name = "ollama-cluster-control-client") {
                        client.use { socket ->
                            handleControlClient(socket, rpcPort, selectedDevice)
                        }
                    }
                }
            } catch (error: SocketException) {
                if (controlServer?.isClosed != true) {
                    Log.w("LlamaRpcWorker", "Cluster metadata socket stopped", error)
                }
            } catch (error: Exception) {
                Log.w("LlamaRpcWorker", "Unable to expose cluster metadata", error)
            }
        }
    }

    private fun handleControlClient(socket: Socket, rpcPort: Int, selectedDevice: String) {
        try {
            socket.soTimeout = 3_000
            val reader = socket.getInputStream().bufferedReader(Charsets.UTF_8)
            val requestLine = reader.readLine().orEmpty()
            val requestParts = requestLine.split(' ')
            val method = requestParts.getOrNull(0).orEmpty()
            val path = requestParts.getOrNull(1).orEmpty().substringBefore('?')
            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = reader.readLine() ?: break
                if (line.isEmpty()) break
                val separator = line.indexOf(':')
                if (separator > 0) {
                    headers[line.substring(0, separator).trim().lowercase()] =
                        line.substring(separator + 1).trim()
                }
            }

            if (method == "GET" && path == "/v1/device") {
                val payload = ClusterDeviceInfo.asJson(
                    this,
                    rpcPort,
                    selectedDevice,
                    process?.isAlive == true,
                    shareMedia
                ).toByteArray(Charsets.UTF_8)
                writeResponse(socket, "200 OK", "application/json; charset=utf-8", payload)
                return
            }
            if (method != "POST" || path !in setOf(
                    "/v1/camera/front",
                    "/v1/camera/rear",
                    "/v1/audio"
                )) {
                writeJsonError(socket, "404 Not Found", "not found")
                return
            }
            if (!shareMedia) {
                writeJsonError(socket, "403 Forbidden", "remote media is disabled")
                return
            }
            if (!validMediaToken(headers["x-ollama-cluster-token"].orEmpty())) {
                writeJsonError(socket, "401 Unauthorized", "invalid cluster media key")
                return
            }
            promoteToForeground(rpcPort)
            when (path) {
                "/v1/camera/front", "/v1/camera/rear" -> {
                    val bytes = ClusterMediaCapture.captureJpeg(
                        this,
                        front = path.endsWith("/front")
                    )
                    writeResponse(socket, "200 OK", "image/jpeg", bytes)
                }
                "/v1/audio" -> {
                    val bytes = ClusterMediaCapture.captureSpeechPcm(this)
                    if (bytes.isEmpty()) {
                        writeResponse(socket, "204 No Content", "application/octet-stream", bytes)
                    } else {
                        writeResponse(
                            socket,
                            "200 OK",
                            "application/octet-stream",
                            bytes,
                            mapOf(
                                "X-Audio-Format" to "pcm_s16le",
                                "X-Sample-Rate" to "16000"
                            )
                        )
                    }
                }
            }
        } catch (error: Throwable) {
            Log.w("LlamaRpcWorker", "Cluster media request failed", error)
            runCatching {
                writeJsonError(
                    socket,
                    "500 Internal Server Error",
                    error.message ?: "media capture failed"
                )
            }
        }
    }

    private fun validMediaToken(candidate: String): Boolean {
        if (mediaToken.length < 8 || candidate.isEmpty()) return false
        return MessageDigest.isEqual(
            mediaToken.toByteArray(Charsets.UTF_8),
            candidate.toByteArray(Charsets.UTF_8)
        )
    }

    private fun writeJsonError(socket: Socket, status: String, message: String) {
        val escaped = org.json.JSONObject.quote(message)
        writeResponse(
            socket,
            status,
            "application/json; charset=utf-8",
            "{\"error\":$escaped}".toByteArray(Charsets.UTF_8)
        )
    }

    private fun writeResponse(
        socket: Socket,
        status: String,
        contentType: String,
        bytes: ByteArray,
        extraHeaders: Map<String, String> = emptyMap()
    ) {
        val output = socket.getOutputStream()
        val headers = buildString {
            append("HTTP/1.1 $status\r\n")
            append("Content-Type: $contentType\r\n")
            append("Content-Length: ${bytes.size}\r\n")
            append("Cache-Control: no-store\r\n")
            extraHeaders.forEach { (name, value) -> append("$name: $value\r\n") }
            append("Connection: close\r\n\r\n")
        }.toByteArray(Charsets.UTF_8)
        output.write(headers)
        output.write(bytes)
        output.flush()
    }

    private fun stopControlServer() {
        try {
            controlServer?.close()
        } catch (_: Exception) {
        } finally {
            controlServer = null
        }
    }

    override fun onDestroy() {
        stopWorker()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun isQualcommSoc(): Boolean {
        val soc = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}"
        } else ""
        return Regex(
            "qualcomm|qcom|snapdragon|sm[0-9]{4}|kalama|pineapple",
            RegexOption.IGNORE_CASE
        ).containsMatchIn("$soc ${Build.HARDWARE} ${Build.BOARD} ${Build.DEVICE}")
    }

    private fun hasKnownUnstableAdrenoDriver(): Boolean {
        val model = Build.MODEL.uppercase().replace("_", "-")
        return Build.MANUFACTURER.equals("samsung", ignoreCase = true) &&
            (model.startsWith("SM-X700") ||
                model.startsWith("SM-X800") ||
                model.startsWith("SM-X900"))
    }

    private fun stageVendorOpenCl(): File? {
        val source = listOf(
            File("/vendor/lib64/libOpenCL.so"),
            File("/system/vendor/lib64/libOpenCL.so")
        ).firstOrNull { it.isFile && it.canRead() } ?: return null
        return try {
            val directory = File(noBackupFilesDir, "opencl").apply { mkdirs() }
            val target = File(directory, "libOpenCL.so")
            if (!target.isFile || target.length() != source.length()) {
                val pending = File(directory, "libOpenCL.so.tmp")
                source.inputStream().use { input ->
                    pending.outputStream().use { output -> input.copyTo(output) }
                }
                if (target.exists()) target.delete()
                if (!pending.renameTo(target)) {
                    pending.copyTo(target, overwrite = true)
                    pending.delete()
                }
            }
            target.setReadable(true, true)
            target
        } catch (error: Exception) {
            Log.w("LlamaRpcWorker", "Unable to stage the device OpenCL library", error)
            null
        }
    }

    companion object {
        const val ACTION_STOP = "com.example.ollama.STOP_RPC_WORKER"
        const val PREFERENCES = "llama_rpc_worker"
        const val DEFAULT_PORT = 50052
        private const val CHANNEL_ID = "llama_rpc_worker_channel"
        private const val NOTIFICATION_ID = 2
    }
}
