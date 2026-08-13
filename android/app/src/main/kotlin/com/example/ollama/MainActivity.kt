package com.example.ollama

import android.app.ActivityManager
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.media.MediaMetadataRetriever
import android.opengl.EGL14
import android.opengl.GLES20
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.util.Base64
import android.util.Xml
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.StringReader
import java.nio.charset.StandardCharsets
import java.util.zip.ZipFile
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.text.PDFTextStripper
import kotlin.concurrent.thread

open class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.ollama/server"
    private var methodChannel: MethodChannel? = null
    private var assistantController: AssistantPlatformController? = null
    private var assistantInvocationPending = false
    private var pendingRpcWorkerStart: PendingRpcWorkerStart? = null
    private var pendingRpcWorkerResult: MethodChannel.Result? = null
    private var pendingAssistantCameraPermissionResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        activeActivity = this
        assistantInvocationPending = isAssistantIntent(intent)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel = channel
        assistantController = AssistantPlatformController(this, channel)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialAssistantInvocation" -> {
                    val pending = assistantInvocationPending
                    assistantInvocationPending = false
                    result.success(pending)
                }
                "getSystemThemeSeed" -> {
                    val accentId = resources.getIdentifier(
                        "system_accent1_500",
                        "color",
                        "android"
                    )
                    val color = if (accentId != 0) {
                        runCatching { getColor(accentId) }.getOrNull()
                    } else null
                    result.success(color)
                }
                "consumeAssistantScreenshot" ->
                    result.success(AssistantContextStore.consumeScreenshot())
                "requestAssistantCameraPermission" -> {
                    if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) ==
                        PackageManager.PERMISSION_GRANTED
                    ) {
                        result.success(true)
                    } else if (pendingAssistantCameraPermissionResult != null) {
                        result.error(
                            "CAMERA_PERMISSION_PENDING",
                            "A camera permission request is already active",
                            null
                        )
                    } else {
                        pendingAssistantCameraPermissionResult = result
                        requestPermissions(
                            arrayOf(Manifest.permission.CAMERA),
                            REQUEST_ASSISTANT_CAMERA
                        )
                    }
                }
                "setAssistantVoiceSessionActive" -> {
                    val active = call.argument<Boolean>("active") ?: false
                    assistantVoiceSessionActive = active
                    result.success(true)
                }
                "finishAssistantOverlay" -> {
                    finish()
                    result.success(true)
                }
                "updateAssistantPanelState" -> {
                    OllamaVoiceSession.updateActiveState(
                        call.argument<String>("label") ?: "Ollama",
                        call.argument<Boolean>("busy") ?: false
                    )
                    result.success(true)
                }
                "startServer" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 101)
                    }
                    val maxLoadedModels = call.argument<Int>("maxLoadedModels") ?: 1
                    val exposeToLan = call.argument<Boolean>("exposeToLan") ?: false
                    val computeMode = call.argument<String>("computeMode") ?: "adaptive"
                    val forcedDevice = call.argument<String>("forcedDevice") ?: "gpu"
                    val forceCpuSafe = call.argument<Boolean>("forceCpuSafe") ?: false
                    val rpcServers = call.argument<String>("rpcServers") ?: ""
                    val multimodalBackendDevice =
                        call.argument<String>("multimodalBackendDevice") ?: ""
                    val synergyCpuPercent = call.argument<Int>("synergyCpuPercent") ?: 50
                    val synergyGpuPercent = call.argument<Int>("synergyGpuPercent") ?: 50
                    val synergyNpuPercent = call.argument<Int>("synergyNpuPercent") ?: 0
                    val intent = Intent(this, OllamaServerService::class.java).apply {
                        putExtra("maxLoadedModels", maxLoadedModels)
                        putExtra("exposeToLan", exposeToLan)
                        putExtra("computeMode", computeMode)
                        putExtra("forcedDevice", forcedDevice)
                        putExtra("forceCpuSafe", forceCpuSafe)
                        putExtra("rpcServers", rpcServers)
                        putExtra("multimodalBackendDevice", multimodalBackendDevice)
                        putExtra("synergyCpuPercent", synergyCpuPercent)
                        putExtra("synergyGpuPercent", synergyGpuPercent)
                        putExtra("synergyNpuPercent", synergyNpuPercent)
                    }
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O) {
                        startForegroundService(intent)
                    } else {
                        startService(intent)
                    }
                    result.success(true)
                }
                "stopServer" -> {
                    val intent = Intent(this, OllamaServerService::class.java)
                    intent.action = "STOP"
                    startService(intent)
                    result.success(true)
                }
                "startRpcWorker" -> {
                    val request = PendingRpcWorkerStart(
                        port = call.argument<Int>("port") ?: RpcServerService.DEFAULT_PORT,
                        device = call.argument<String>("device") ?: "auto",
                        useCache = call.argument<Boolean>("useCache") ?: false,
                        shareMedia = call.argument<Boolean>("shareMedia") ?: false,
                        mediaToken = call.argument<String>("mediaToken")?.trim().orEmpty()
                    )
                    val missingPermissions = mutableListOf<String>()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                        ContextCompat.checkSelfPermission(
                            this,
                            Manifest.permission.POST_NOTIFICATIONS
                        ) != PackageManager.PERMISSION_GRANTED
                    ) {
                        missingPermissions.add(Manifest.permission.POST_NOTIFICATIONS)
                    }
                    if (request.shareMedia) {
                        listOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)
                            .filterTo(missingPermissions) {
                                ContextCompat.checkSelfPermission(this, it) !=
                                    PackageManager.PERMISSION_GRANTED
                            }
                    }
                    if (missingPermissions.isNotEmpty()) {
                        if (pendingRpcWorkerResult != null) {
                            result.error("RPC_START_PENDING", "Ya hay un inicio de worker pendiente", null)
                        } else {
                            pendingRpcWorkerStart = request
                            pendingRpcWorkerResult = result
                            requestPermissions(
                                missingPermissions.toTypedArray(),
                                REQUEST_CLUSTER_MEDIA
                            )
                        }
                    } else {
                        launchRpcWorker(request)
                        result.success(true)
                    }
                }
                "stopRpcWorker" -> {
                    startService(Intent(this, RpcServerService::class.java).apply {
                        action = RpcServerService.ACTION_STOP
                    })
                    result.success(true)
                }
                "getRpcWorkerStatus" -> {
                    val state = getSharedPreferences(RpcServerService.PREFERENCES, MODE_PRIVATE)
                    @Suppress("DEPRECATION")
                    val serviceActive = getSystemService(ActivityManager::class.java)
                        .getRunningServices(Int.MAX_VALUE)
                        .any { it.service.className == RpcServerService::class.java.name }
                    val reportedRunning = state.getBoolean("running", false)
                    if (reportedRunning && !serviceActive) {
                        state.edit().putBoolean("running", false).apply()
                    }
                    result.success(mapOf(
                        "running" to (reportedRunning && serviceActive),
                        "port" to state.getInt("port", RpcServerService.DEFAULT_PORT),
                        "error" to state.getString("error", null)
                    ))
                }
                "getComputeCapabilities" -> {
                    val vulkan = packageManager.hasSystemFeature(
                        android.content.pm.PackageManager.FEATURE_VULKAN_HARDWARE_LEVEL
                    )
                    val soc = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        "${Build.SOC_MANUFACTURER} ${Build.SOC_MODEL}".trim()
                    } else {
                        Build.HARDWARE
                    }
                    val identity = "$soc ${Build.HARDWARE} ${Build.BOARD} ${Build.DEVICE}"
                    val gpuRenderer = detectGpuRenderer()
                    val adrenoDetected = gpuRenderer?.contains("adreno", ignoreCase = true) == true
                    val snapdragonDetected = Regex(
                        "snapdragon|qualcomm|qcom|sm[0-9]{4}|kalama|pineapple",
                        RegexOption.IGNORE_CASE
                    ).containsMatchIn(identity) || adrenoDetected
                    val snapdragonHtpEligible = snapdragonDetected && Regex(
                        "sm(8550|8650|8750|8850)|snapdragon\\s*8\\s*(gen\\s*[2-9]|elite)|kalama|pineapple",
                        RegexOption.IGNORE_CASE
                    ).containsMatchIn(identity)
                    val npuDetected = Regex(
                        "tensor|exynos|snapdragon|qualcomm|qti|qcom|sm[0-9]{4}|mediatek|dimensity|kirin",
                        RegexOption.IGNORE_CASE
                    ).containsMatchIn(identity)
                    val htpVersion = when {
                        Regex("sm8450|sm8475", RegexOption.IGNORE_CASE)
                            .containsMatchIn(identity) -> "v69"
                        Regex("sm8550", RegexOption.IGNORE_CASE)
                            .containsMatchIn(identity) -> "v73"
                        Regex("sm8650", RegexOption.IGNORE_CASE)
                            .containsMatchIn(identity) -> "v75"
                        Regex("sm8750|sm8850", RegexOption.IGNORE_CASE)
                            .containsMatchIn(identity) -> "v79+"
                        else -> null
                    }
                    val nativeDir = File(applicationInfo.nativeLibraryDir)
                    val rpcBackend = File(nativeDir, "libggml-rpc.so").exists() &&
                        File(nativeDir, "libggml_rpc_server_exec.so").exists()
                    val fastRpcAvailable = File("/vendor/lib64/libcdsprpc.so").exists() ||
                        File("/vendor/lib64/libadsprpc.so").exists()
                    val htpHostLibraries = File(nativeDir, "libggml-htp.so").exists() &&
                        File(nativeDir, "libhtp_ops.so").exists()
                    val htpDspSkeleton = File(
                        File(filesDir, "snapdragon-htp"), "libhtp_ops_skel.so"
                    ).exists() || File(nativeDir, "libhtp_ops_skel.so").exists()
                    val htpBackend = snapdragonHtpEligible && fastRpcAvailable &&
                        htpHostLibraries && htpDspSkeleton
                    val htpReason = when {
                        htpBackend ->
                            "Backend Snapdragon HTP experimental disponible. Solo admite GGUF convertido para HMX/HVX y modelos pequeños compatibles."
                        !snapdragonDetected ->
                            "No se ha detectado un SoC Snapdragon/Qualcomm."
                        !snapdragonHtpEligible -> if (htpVersion != null)
                            "HTP $htpVersion inferior a v73 mínima. La GPU Adreno puede seguir usando Vulkan."
                        else
                            "Snapdragon detectado, pero el backend requiere Snapdragon 8 Gen 2 o posterior (HTP v73+)."
                        !fastRpcAvailable ->
                            "Hardware HTP elegible, pero el firmware no expone libcdsprpc.so/libadsprpc.so a la aplicación."
                        !htpHostLibraries || !htpDspSkeleton ->
                            "Hardware HTP elegible y FastRPC presente, pero el APK no contiene un backend HTP compatible y su biblioteca DSP."
                        else -> "Backend HTP no disponible."
                    }
                    result.success(mapOf(
                        "cpu" to true,
                        "gpu" to vulkan,
                        "gpuRenderer" to (gpuRenderer ?: "No identificado"),
                        "adrenoDetected" to adrenoDetected,
                        "snapdragonDetected" to snapdragonDetected,
                        "snapdragonHtpEligible" to snapdragonHtpEligible,
                        "fastRpcAvailable" to fastRpcAvailable,
                        "npuDetected" to npuDetected,
                        "htpVersion" to htpVersion,
                        "htpMinimumVersion" to "v73",
                        "npuBackend" to htpBackend,
                        "htpBackend" to htpBackend,
                        "htpReason" to htpReason,
                        "htpModelFormat" to
                            "F16/Q4_0/Q8_0/IQ4_NL convertido con layout HMX/HVX; menos de 4B recomendado",
                        "rpcBackend" to rpcBackend,
                        "soc" to soc,
                        "reason" to htpReason
                    ))
                }
                "getClusterHostInfo" -> {
                    result.success(ClusterDeviceInfo.asMap(this))
                }
                "getMemoryInfo" -> {
                    val memory = ActivityManager.MemoryInfo()
                    getSystemService(ActivityManager::class.java)
                        .getMemoryInfo(memory)
                    result.success(mapOf(
                        "totalBytes" to memory.totalMem,
                        "availableBytes" to memory.availMem,
                        "thresholdBytes" to memory.threshold,
                        "lowMemory" to memory.lowMemory
                    ))
                }
                "setKeepScreenOn" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(true)
                }
                "extractVideoFrames" -> {
                    val path = call.argument<String>("path")
                    val count = (call.argument<Int>("count") ?: 3).coerceIn(1, 8)
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_PATH", "A video path is required", null)
                        return@setMethodCallHandler
                    }
                    thread {
                        val retriever = MediaMetadataRetriever()
                        try {
                            retriever.setDataSource(path)
                            val durationMs = retriever
                                .extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)
                                ?.toLongOrNull() ?: 0L
                            val frames = mutableListOf<String>()
                            for (index in 1..count) {
                                val positionUs = if (durationMs > 0) {
                                    durationMs * 1000L * index / (count + 1)
                                } else {
                                    index * 1_000_000L
                                }
                                val bitmap = retriever.getFrameAtTime(
                                    positionUs,
                                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC
                                ) ?: continue
                                val output = ByteArrayOutputStream()
                                bitmap.compress(android.graphics.Bitmap.CompressFormat.JPEG, 85, output)
                                bitmap.recycle()
                                frames.add(Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP))
                                output.close()
                            }
                            runOnUiThread { result.success(frames) }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error("VIDEO_FRAMES", error.message, null)
                            }
                        } finally {
                            retriever.release()
                        }
                    }
                }
                "processPdf" -> {
                    val path = call.argument<String>("path")
                    val renderPages = call.argument<Boolean>("renderPages") ?: false
                    val maxPages = (call.argument<Int>("maxPages") ?: 6).coerceIn(1, 12)
                    if (path.isNullOrBlank() || !File(path).isFile) {
                        result.error("INVALID_PDF", "A readable PDF path is required", null)
                        return@setMethodCallHandler
                    }
                    thread {
                        try {
                            val source = File(path)
                            if (renderPages) {
                                val encodedPages = mutableListOf<String>()
                                var pageCount = 0
                                ParcelFileDescriptor.open(
                                    source, ParcelFileDescriptor.MODE_READ_ONLY
                                ).use { descriptor ->
                                    PdfRenderer(descriptor).use { renderer ->
                                        pageCount = renderer.pageCount
                                        val count = minOf(renderer.pageCount, maxPages)
                                        for (index in 0 until count) {
                                            renderer.openPage(index).use { page ->
                                                val scale = minOf(2.0, 1600.0 / page.width.toDouble())
                                                val width = (page.width * scale).toInt().coerceAtLeast(1)
                                                val height = (page.height * scale).toInt().coerceAtLeast(1)
                                                val bitmap = Bitmap.createBitmap(
                                                    width, height, Bitmap.Config.ARGB_8888
                                                )
                                                bitmap.eraseColor(Color.WHITE)
                                                page.render(
                                                    bitmap, null, null,
                                                    PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY
                                                )
                                                val output = ByteArrayOutputStream()
                                                bitmap.compress(Bitmap.CompressFormat.JPEG, 84, output)
                                                bitmap.recycle()
                                                encodedPages.add(Base64.encodeToString(
                                                    output.toByteArray(), Base64.NO_WRAP
                                                ))
                                                output.close()
                                            }
                                        }
                                    }
                                }
                                PDFBoxResourceLoader.init(applicationContext)
                                val extracted = PDDocument.load(source).use { document ->
                                    extractPdfTextByPage(document, 300)
                                }
                                val clipped = if (extracted.length > 2_000_000) {
                                    extracted.take(2_000_000) +
                                        "\n\n[Document indexed up to 2000000 characters]"
                                } else extracted
                                runOnUiThread { result.success(mapOf(
                                    "pageCount" to pageCount,
                                    "images" to encodedPages,
                                    "text" to clipped
                                )) }
                            } else {
                                PDFBoxResourceLoader.init(applicationContext)
                                PDDocument.load(source).use { document ->
                                    val extracted = extractPdfTextByPage(document, 300)
                                    val clipped = if (extracted.length > 2_000_000) {
                                        extracted.take(2_000_000) +
                                            "\n\n[Document indexed up to 2000000 characters]"
                                    } else extracted
                                    runOnUiThread { result.success(mapOf(
                                        "pageCount" to document.numberOfPages,
                                        "images" to emptyList<String>(),
                                        "text" to clipped
                                    )) }
                                }
                            }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error("PDF_PROCESSING", error.message, null)
                            }
                        }
                    }
                }
                "processDocument" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank() || !File(path).isFile) {
                        result.error("INVALID_DOCUMENT", "A readable document path is required", null)
                        return@setMethodCallHandler
                    }
                    thread {
                        try {
                            val source = File(path)
                            val extension = source.extension.lowercase()
                            val extracted = when (extension) {
                                "docx", "xlsx", "pptx", "odt", "ods", "odp", "epub" ->
                                    extractZippedDocument(source, extension)
                                "rtf" -> extractRtfDocument(source.readText())
                                "doc", "xls", "ppt" ->
                                    extractLegacyDocumentStrings(source.readBytes())
                                else -> source.readText(Charsets.UTF_8)
                            }.trim()
                            val clipped = if (extracted.length > 2_000_000) {
                                extracted.take(2_000_000) +
                                    "\n\n[Document indexed up to 2000000 characters]"
                            } else extracted
                            runOnUiThread { result.success(mapOf(
                                "text" to clipped,
                                "format" to extension,
                                "size" to source.length()
                            )) }
                        } catch (error: Exception) {
                            runOnUiThread {
                                result.error("DOCUMENT_PROCESSING", error.message, null)
                            }
                        }
                    }
                }
                else -> {
                    @Suppress("UNCHECKED_CAST")
                    val arguments = (call.arguments as? Map<String, Any?>) ?: emptyMap()
                    if (assistantController?.handle(call.method, arguments, result) != true) {
                        result.notImplemented()
                    }
                }
            }
        }
    }

    private fun launchRpcWorker(request: PendingRpcWorkerStart) {
        val workerIntent = Intent(this, RpcServerService::class.java).apply {
            putExtra("port", request.port)
            putExtra("device", request.device)
            putExtra("useCache", request.useCache)
            putExtra("shareMedia", request.shareMedia)
            putExtra("mediaToken", request.mediaToken)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(workerIntent)
        } else {
            startService(workerIntent)
        }
    }

    private data class PendingRpcWorkerStart(
        val port: Int,
        val device: String,
        val useCache: Boolean,
        val shareMedia: Boolean,
        val mediaToken: String
    )

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (isAssistantIntent(intent)) {
            assistantInvocationPending = true
            methodChannel?.invokeMethod("assistantInvoked", null)
            assistantInvocationPending = false
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CLUSTER_MEDIA) {
            val request = pendingRpcWorkerStart
            val result = pendingRpcWorkerResult
            pendingRpcWorkerStart = null
            pendingRpcWorkerResult = null
            if (request != null && result != null) {
                try {
                    launchRpcWorker(request)
                    result.success(true)
                } catch (error: Throwable) {
                    result.error("RPC_START_FAILED", error.message, null)
                }
            }
            return
        }
        if (requestCode == REQUEST_ASSISTANT_CAMERA) {
            val result = pendingAssistantCameraPermissionResult
            pendingAssistantCameraPermissionResult = null
            result?.success(
                grantResults.isNotEmpty() &&
                    grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            )
            return
        }
        assistantController?.onRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onDestroy() {
        assistantController?.destroy()
        assistantController = null
        methodChannel = null
        if (activeActivity === this) activeActivity = null
        super.onDestroy()
    }

    private fun isAssistantIntent(intent: Intent?): Boolean =
        intent?.action == Intent.ACTION_ASSIST || intent?.action == Intent.ACTION_VOICE_COMMAND

    private fun extractPdfTextByPage(document: PDDocument, maxPages: Int): String {
        val pages = minOf(document.numberOfPages, maxPages)
        return buildString {
            for (pageNumber in 1..pages) {
                val pageText = PDFTextStripper().apply {
                    startPage = pageNumber
                    endPage = pageNumber
                    sortByPosition = true
                }.getText(document).trim()
                if (pageText.isNotEmpty()) {
                    if (isNotEmpty()) append("\n\n")
                    append("[PDF page ").append(pageNumber).append("]\n")
                    append(pageText)
                }
            }
        }
    }

    private fun extractZippedDocument(source: File, extension: String): String {
        val accepted: (String) -> Boolean = when (extension) {
            "docx" -> { name ->
                name == "word/document.xml" ||
                    Regex("word/(header|footer)[0-9]+\\.xml").matches(name) ||
                    name == "word/footnotes.xml" || name == "word/endnotes.xml"
            }
            "pptx" -> { name ->
                Regex("ppt/(slides/slide|notesSlides/notesSlide)[0-9]+\\.xml")
                    .matches(name)
            }
            "xlsx" -> { name ->
                name == "xl/sharedStrings.xml" ||
                    Regex("xl/worksheets/sheet[0-9]+\\.xml").matches(name)
            }
            "odt", "ods", "odp" -> { name -> name == "content.xml" }
            "epub" -> { name ->
                name.endsWith(".xhtml", true) ||
                    name.endsWith(".html", true) || name.endsWith(".htm", true)
            }
            else -> { _ -> false }
        }
        val sections = mutableListOf<String>()
        ZipFile(source).use { archive ->
            archive.entries().asSequence()
                .filter { !it.isDirectory && accepted(it.name.replace('\\', '/')) }
                .sortedBy { naturalDocumentOrder(it.name.replace('\\', '/')) }
                .forEach { entry ->
                    val raw = archive.getInputStream(entry).bufferedReader(
                        StandardCharsets.UTF_8
                    ).use { it.readText() }
                    val text = markupToText(raw)
                    if (text.isNotBlank()) sections.add(text)
                }
        }
        return sections.joinToString("\n\n")
    }

    private fun naturalDocumentOrder(name: String): String =
        name.replace(Regex("([0-9]+)")) { match ->
            match.value.padStart(10, '0')
        }

    private fun markupToText(raw: String): String {
        val output = StringBuilder()
        val parser = Xml.newPullParser().apply {
            setFeature("http://xmlpull.org/v1/doc/features.html#process-namespaces", true)
            setInput(StringReader(raw))
        }
        var event = parser.eventType
        while (event != org.xmlpull.v1.XmlPullParser.END_DOCUMENT) {
            when (event) {
                org.xmlpull.v1.XmlPullParser.TEXT -> output.append(parser.text)
                org.xmlpull.v1.XmlPullParser.START_TAG -> when (parser.name.lowercase()) {
                    "br" -> output.append('\n')
                    "tab" -> output.append('\t')
                }
                org.xmlpull.v1.XmlPullParser.END_TAG -> when (parser.name.lowercase()) {
                    "p", "div", "li", "tr", "h", "h1", "h2", "h3", "h4", "h5", "h6" ->
                        output.append('\n')
                }
            }
            event = parser.next()
        }
        return output.toString().replace(Regex("[ \\t]+\n"), "\n")
            .replace(Regex("\n{3,}"), "\n\n").trim()
    }

    private fun extractRtfDocument(raw: String): String = raw
        .replace(Regex("\\\\'[0-9a-fA-F]{2}")) { match ->
            val value = match.value.takeLast(2).toInt(16)
            value.toChar().toString()
        }
        .replace(Regex("\\\\(par|line)\\b"), "\n")
        .replace(Regex("\\\\tab\\b"), "\t")
        .replace(Regex("\\\\[a-zA-Z]+-?[0-9]* ?"), "")
        .replace(Regex("[{}]"), "")
        .replace(Regex("\n{3,}"), "\n\n")

    private fun extractLegacyDocumentStrings(bytes: ByteArray): String {
        val ascii = StringBuilder()
        val sections = mutableListOf<String>()
        fun flush() {
            if (ascii.length >= 4) sections.add(ascii.toString())
            ascii.clear()
        }
        for (byte in bytes) {
            val value = byte.toInt() and 0xff
            if (value == 9 || value == 10 || value == 13 || value in 32..126 || value in 160..255) {
                ascii.append(value.toChar())
            } else {
                flush()
            }
        }
        flush()
        return sections.joinToString("\n")
    }

    private fun notifyScreenshotAvailable() {
        methodChannel?.invokeMethod("assistantScreenshotAvailable", null)
    }

    /**
     * Android does not expose the Vulkan renderer name through PackageManager.
     * A tiny off-screen GLES context gives us the same vendor identity (for
     * example "Adreno (TM) 740") without rendering a visible surface.
     */
    private fun detectGpuRenderer(): String? {
        val display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        if (display == EGL14.EGL_NO_DISPLAY) return null
        var surface = EGL14.EGL_NO_SURFACE
        var context = EGL14.EGL_NO_CONTEXT
        return try {
            if (!EGL14.eglInitialize(display, IntArray(2), 0, IntArray(2), 0)) return null
            val configs = arrayOfNulls<android.opengl.EGLConfig>(1)
            val configCount = IntArray(1)
            val attributes = intArrayOf(
                EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                EGL14.EGL_NONE
            )
            if (!EGL14.eglChooseConfig(
                    display, attributes, 0, configs, 0, configs.size, configCount, 0
                ) || configCount[0] == 0
            ) return null
            val config = configs[0] ?: return null
            context = EGL14.eglCreateContext(
                display,
                config,
                EGL14.EGL_NO_CONTEXT,
                intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 2, EGL14.EGL_NONE),
                0
            )
            surface = EGL14.eglCreatePbufferSurface(
                display,
                config,
                intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE),
                0
            )
            if (context == EGL14.EGL_NO_CONTEXT || surface == EGL14.EGL_NO_SURFACE ||
                !EGL14.eglMakeCurrent(display, surface, surface, context)
            ) return null
            GLES20.glGetString(GLES20.GL_RENDERER)?.trim()?.takeIf { it.isNotEmpty() }
        } catch (_: Throwable) {
            null
        } finally {
            if (display != EGL14.EGL_NO_DISPLAY) {
                EGL14.eglMakeCurrent(
                    display,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT
                )
                if (surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
                if (context != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, context)
                EGL14.eglTerminate(display)
            }
        }
    }

    companion object {
        private const val REQUEST_CLUSTER_MEDIA = 102
        private const val REQUEST_ASSISTANT_CAMERA = 103

        @Volatile
        private var activeActivity: MainActivity? = null

        /** True while Flutter is driving an active assistant voice session. */
        @Volatile
        var assistantVoiceSessionActive = false

        fun notifyAssistantScreenshotAvailable() {
            activeActivity?.runOnUiThread { activeActivity?.notifyScreenshotAvailable() }
        }

        fun notifyAssistantStopRequested() {
            activeActivity?.runOnUiThread {
                activeActivity?.methodChannel?.invokeMethod("assistantStopRequested", null)
            }
        }

        fun notifyAssistantScreenShareRequested() {
            activeActivity?.runOnUiThread {
                activeActivity?.methodChannel?.invokeMethod(
                    "assistantScreenShareRequested",
                    null
                )
            }
        }

        fun notifyAssistantCameraCaptured(path: String, front: Boolean) {
            activeActivity?.runOnUiThread {
                activeActivity?.methodChannel?.invokeMethod(
                    "assistantCameraCaptured",
                    mapOf("path" to path, "front" to front)
                )
            }
        }
    }
}
