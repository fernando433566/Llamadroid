package com.example.ollama

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.ImageReader
import android.media.MediaRecorder
import android.os.Handler
import android.os.HandlerThread
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Captures media on an Android RPC worker for its paired cluster host. */
object ClusterMediaCapture {
    private val cameraLock = Any()
    private val microphoneLock = Any()

    @SuppressLint("MissingPermission")
    fun captureJpeg(context: Context, front: Boolean): ByteArray = synchronized(cameraLock) {
        checkPermission(context, Manifest.permission.CAMERA, "Cámara")
        val manager = context.getSystemService(CameraManager::class.java)
            ?: error("No se ha encontrado el servicio de cámara")
        val facing = if (front) {
            CameraCharacteristics.LENS_FACING_FRONT
        } else {
            CameraCharacteristics.LENS_FACING_BACK
        }
        val cameraId = manager.cameraIdList.firstOrNull { id ->
            manager.getCameraCharacteristics(id)
                .get(CameraCharacteristics.LENS_FACING) == facing
        } ?: error(if (front) "No hay cámara frontal" else "No hay cámara trasera")
        val characteristics = manager.getCameraCharacteristics(cameraId)
        val sizes = characteristics
            .get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
            ?.getOutputSizes(ImageFormat.JPEG)
            ?.toList()
            .orEmpty()
        val preferred = sizes
            .filter { it.width.toLong() * it.height <= 1920L * 1080L }
            .maxByOrNull { it.width.toLong() * it.height }
            ?: sizes.minByOrNull { it.width.toLong() * it.height }
            ?: error("La cámara no anuncia salida JPEG")

        val callbackThread = HandlerThread("ollama-cluster-camera").apply { start() }
        val handler = Handler(callbackThread.looper)
        val reader = ImageReader.newInstance(
            preferred.width,
            preferred.height,
            ImageFormat.JPEG,
            2
        )
        val completed = CountDownLatch(1)
        val imageBytes = AtomicReference<ByteArray?>()
        val failure = AtomicReference<Throwable?>()
        val openedCamera = AtomicReference<CameraDevice?>()
        val openedSession = AtomicReference<CameraCaptureSession?>()

        fun fail(error: Throwable) {
            failure.compareAndSet(null, error)
            completed.countDown()
        }

        reader.setOnImageAvailableListener({ source ->
            try {
                source.acquireLatestImage()?.use { image ->
                    val buffer = image.planes.first().buffer
                    ByteArray(buffer.remaining()).also {
                        buffer.get(it)
                        imageBytes.set(it)
                    }
                }
            } catch (error: Throwable) {
                failure.compareAndSet(null, error)
            } finally {
                completed.countDown()
            }
        }, handler)

        try {
            manager.openCamera(cameraId, object : CameraDevice.StateCallback() {
                override fun onOpened(camera: CameraDevice) {
                    openedCamera.set(camera)
                    camera.createCaptureSession(
                        listOf(reader.surface),
                        object : CameraCaptureSession.StateCallback() {
                            override fun onConfigured(session: CameraCaptureSession) {
                                openedSession.set(session)
                                try {
                                    val request = camera
                                        .createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE)
                                        .apply {
                                            addTarget(reader.surface)
                                            set(
                                                CaptureRequest.CONTROL_AF_MODE,
                                                CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE
                                            )
                                        }
                                        .build()
                                    session.capture(request, null, handler)
                                } catch (error: Throwable) {
                                    fail(error)
                                }
                            }

                            override fun onConfigureFailed(session: CameraCaptureSession) {
                                fail(IllegalStateException("No se pudo configurar la cámara remota"))
                            }
                        },
                        handler
                    )
                }

                override fun onDisconnected(camera: CameraDevice) {
                    fail(IllegalStateException("La cámara remota se desconectó"))
                }

                override fun onError(camera: CameraDevice, error: Int) {
                    fail(IllegalStateException("Error de cámara remota: $error"))
                }
            }, handler)
            if (!completed.await(12, TimeUnit.SECONDS)) {
                error("La cámara remota agotó el tiempo de espera")
            }
            failure.get()?.let { throw it }
            imageBytes.get() ?: error("La cámara remota no produjo una imagen")
        } finally {
            runCatching { openedSession.get()?.close() }
            runCatching { openedCamera.get()?.close() }
            reader.close()
            callbackThread.quitSafely()
            callbackThread.join(1500)
        }
    }

    fun captureSpeechPcm(
        context: Context,
        silenceMillis: Int = 1200
    ): ByteArray = synchronized(microphoneLock) {
        checkPermission(context, Manifest.permission.RECORD_AUDIO, "Micrófono")
        val sampleRate = 16_000
        val channel = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minimum = AudioRecord.getMinBufferSize(sampleRate, channel, encoding)
        check(minimum > 0) { "El micrófono no admite PCM a 16 kHz" }
        val recorder = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION,
            sampleRate,
            channel,
            encoding,
            max(minimum * 2, 6400)
        )
        check(recorder.state == AudioRecord.STATE_INITIALIZED) {
            "No se pudo inicializar el micrófono remoto"
        }

        val samples = ShortArray(320)
        val output = ByteArrayOutputStream()
        val preRoll = ArrayDeque<ByteArray>()
        var preRollBytes = 0
        val maxPreRollBytes = sampleRate * 2
        var speechStarted = false
        var candidateChunks = 0
        var noiseFloor = 0.003
        val startedAt = android.os.SystemClock.elapsedRealtime()
        var lastSpeechAt = startedAt
        val calibrationEnds = startedAt + 600
        val silence = silenceMillis.coerceIn(400, 3000)

        try {
            recorder.startRecording()
            while (true) {
                val count = recorder.read(samples, 0, samples.size, AudioRecord.READ_BLOCKING)
                if (count <= 0) continue
                val chunk = ByteBuffer.allocate(count * 2)
                    .order(ByteOrder.LITTLE_ENDIAN)
                    .also { bytes ->
                        for (index in 0 until count) bytes.putShort(samples[index])
                    }
                    .array()
                var energy = 0.0
                for (index in 0 until count) {
                    val value = samples[index] / 32768.0
                    energy += value * value
                }
                val rms = sqrt(energy / count)
                val now = android.os.SystemClock.elapsedRealtime()

                if (!speechStarted) {
                    preRoll.addLast(chunk)
                    preRollBytes += chunk.size
                    while (preRollBytes > maxPreRollBytes && preRoll.isNotEmpty()) {
                        preRollBytes -= preRoll.removeFirst().size
                    }
                    if (now < calibrationEnds) {
                        noiseFloor = noiseFloor * 0.8 + rms * 0.2
                        candidateChunks = 0
                    } else {
                        val startThreshold = max(0.012, min(0.08, noiseFloor * 2.8))
                        if (rms > startThreshold) {
                            candidateChunks += 1
                            if (candidateChunks >= 2) {
                                speechStarted = true
                                lastSpeechAt = now
                                preRoll.forEach(output::write)
                                preRoll.clear()
                            }
                        } else {
                            candidateChunks = 0
                            noiseFloor = noiseFloor * 0.98 + rms * 0.02
                        }
                    }
                } else {
                    output.write(chunk)
                    val continueThreshold = max(0.008, min(0.05, noiseFloor * 1.6))
                    if (rms > continueThreshold) lastSpeechAt = now
                    if (now - lastSpeechAt > silence) break
                }

                if (!speechStarted && now - startedAt >= 15_000) break
                if (speechStarted && now - startedAt >= 60_000) break
            }
            output.toByteArray()
        } finally {
            runCatching { recorder.stop() }
            recorder.release()
            output.close()
        }
    }

    private fun checkPermission(context: Context, permission: String, label: String) {
        check(ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED) {
            "$label no autorizado en el worker"
        }
    }
}
