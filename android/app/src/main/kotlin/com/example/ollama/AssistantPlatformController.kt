package com.example.ollama

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.media.MediaPlayer
import android.os.Bundle
import android.provider.AlarmClock
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.UUID
import java.time.OffsetDateTime
import java.time.LocalDateTime
import java.time.ZoneId

class AssistantPlatformController(
    private val activity: MainActivity,
    private val channel: MethodChannel
) {
    private var recognizer: SpeechRecognizer? = null
    private var recognitionResult: MethodChannel.Result? = null
    private var pendingRecognition: Pair<Map<String, Any?>, MethodChannel.Result>? = null
    private var textToSpeech: TextToSpeech? = null
    private var ttsResult: MethodChannel.Result? = null
    private var mediaPlayer: MediaPlayer? = null
    private var mediaResult: MethodChannel.Result? = null
    private var pendingPhoneCall: Pair<Map<String, Any?>, MethodChannel.Result>? = null

    fun handle(method: String, arguments: Map<String, Any?>, result: MethodChannel.Result): Boolean {
        when (method) {
            "recognizeAssistantSpeech" -> recognize(arguments, result)
            "speakAssistantText" -> speak(arguments, result)
            "stopAssistantAudio" -> {
                stopAudio()
                result.success(true)
            }
            "isOnDeviceSpeechRecognitionAvailable" ->
                result.success(SpeechRecognizer.isOnDeviceRecognitionAvailable(activity))
            "openAssistantSettings" -> {
                try {
                    activity.startActivity(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS))
                } catch (_: Exception) {
                    activity.startActivity(Intent(Settings.ACTION_SETTINGS))
                }
                result.success(true)
            }
            "executeAssistantAction" -> executeAction(arguments, result)
            "playAssistantAudio" -> playAudio(arguments, result)
            else -> return false
        }
        return true
    }

    private fun playAudio(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val path = arguments["path"]?.toString()
        if (path.isNullOrBlank()) {
            result.error("AUDIO_PATH", "Falta el archivo de audio", null)
            return
        }
        stopMedia(completeAsCancelled = true)
        try {
            mediaResult = result
            mediaPlayer = MediaPlayer().apply {
                setDataSource(path)
                setOnCompletionListener {
                    val pending = mediaResult
                    mediaResult = null
                    stopMedia(completeAsCancelled = false)
                    pending?.success(true)
                }
                setOnErrorListener { _, what, extra ->
                    val pending = mediaResult
                    mediaResult = null
                    stopMedia(completeAsCancelled = false)
                    pending?.error("AUDIO_$what", "No se pudo reproducir el audio ($extra)", extra)
                    true
                }
                prepare()
                start()
            }
        } catch (error: Exception) {
            mediaResult = null
            stopMedia(completeAsCancelled = false)
            result.error("AUDIO_PLAYBACK", error.message, null)
        }
    }

    @Suppress("UNCHECKED_CAST")
    private fun executeAction(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val action = arguments["action"] as? String
        val values = (arguments["arguments"] as? Map<String, Any?>) ?: emptyMap()
        if (action == "call_contact") {
            callContact(arguments, values, result)
            return
        }
        try {
            val intent = when (action) {
                "compose_email" -> Intent(Intent.ACTION_SENDTO).apply {
                    data = Uri.parse("mailto:${Uri.encode(values["to"]?.toString().orEmpty())}")
                    putExtra(Intent.EXTRA_SUBJECT, values["subject"]?.toString().orEmpty())
                    putExtra(Intent.EXTRA_TEXT, values["body"]?.toString().orEmpty())
                }
                "set_timer" -> Intent(AlarmClock.ACTION_SET_TIMER).apply {
                    putExtra(AlarmClock.EXTRA_LENGTH, number(values["seconds"]).coerceAtLeast(1))
                    putExtra(AlarmClock.EXTRA_MESSAGE, values["label"]?.toString().orEmpty())
                    putExtra(AlarmClock.EXTRA_SKIP_UI, true)
                }
                "set_alarm" -> Intent(AlarmClock.ACTION_SET_ALARM).apply {
                    putExtra(AlarmClock.EXTRA_HOUR, number(values["hour"]).coerceIn(0, 23))
                    putExtra(AlarmClock.EXTRA_MINUTES, number(values["minute"]).coerceIn(0, 59))
                    putExtra(AlarmClock.EXTRA_MESSAGE, values["label"]?.toString().orEmpty())
                    putExtra(AlarmClock.EXTRA_SKIP_UI, false)
                }
                "create_calendar_reminder" -> Intent(Intent.ACTION_INSERT).apply {
                    data = CalendarContract.Events.CONTENT_URI
                    putExtra(CalendarContract.Events.TITLE, values["title"]?.toString().orEmpty())
                    putExtra(CalendarContract.Events.DESCRIPTION, values["description"]?.toString().orEmpty())
                    putExtra(CalendarContract.EXTRA_EVENT_BEGIN_TIME, parseDateTime(values["start_iso"]?.toString()))
                }
                "web_search" -> Intent(
                    Intent.ACTION_VIEW,
                    Uri.parse("https://duckduckgo.com/?q=${Uri.encode(values["query"]?.toString().orEmpty())}")
                )
                "open_app" -> findLaunchIntent(values["app"]?.toString().orEmpty())
                else -> null
            }
            if (intent == null) {
                result.success(mapOf("ok" to false, "error" to "Acción o aplicación no disponible: $action"))
                return
            }
            activity.startActivity(intent)
            result.success(mapOf(
                "ok" to true,
                "action" to action,
                "message" to "Android abrió la pantalla correspondiente para que el usuario confirme."
            ))
        } catch (error: Exception) {
            result.success(mapOf("ok" to false, "error" to (error.message ?: error.javaClass.simpleName)))
        }
    }

    private fun callContact(
        originalArguments: Map<String, Any?>,
        values: Map<String, Any?>,
        result: MethodChannel.Result
    ) {
        val requested = values["contact"]?.toString()?.trim().orEmpty()
        if (requested.isBlank()) {
            result.success(mapOf("ok" to false, "error" to "Falta el nombre o número"))
            return
        }
        val looksLikeNumber = requested.matches(Regex("^[+0-9 ()-]{3,}$"))
        val permissions = mutableListOf(Manifest.permission.CALL_PHONE)
        if (!looksLikeNumber) permissions.add(Manifest.permission.READ_CONTACTS)
        val missing = permissions.filter {
            ContextCompat.checkSelfPermission(activity, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            pendingPhoneCall = originalArguments to result
            ActivityCompat.requestPermissions(
                activity,
                missing.toTypedArray(),
                PHONE_CALL_REQUEST
            )
            return
        }

        var contactName = requested
        var number = requested
        if (!looksLikeNumber) {
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY,
                ContactsContract.CommonDataKinds.Phone.NUMBER
            )
            val selection =
                "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY} LIKE ?"
            val cursor = activity.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                projection,
                selection,
                arrayOf("%$requested%"),
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY + " ASC"
            )
            var foundName: String? = null
            var foundNumber: String? = null
            cursor?.use {
                val nameColumn = it.getColumnIndexOrThrow(
                    ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME_PRIMARY
                )
                val numberColumn = it.getColumnIndexOrThrow(
                    ContactsContract.CommonDataKinds.Phone.NUMBER
                )
                while (it.moveToNext()) {
                    val candidateName = it.getString(nameColumn)
                    val candidateNumber = it.getString(numberColumn)
                    if (foundNumber == null || candidateName.equals(requested, ignoreCase = true)) {
                        foundName = candidateName
                        foundNumber = candidateNumber
                    }
                    if (candidateName.equals(requested, ignoreCase = true)) break
                }
            }
            if (foundNumber.isNullOrBlank()) {
                result.success(mapOf(
                    "ok" to false,
                    "error" to "No se encontró el contacto $requested"
                ))
                return
            }
            contactName = foundName ?: requested
            number = foundNumber
        }

        try {
            activity.startActivity(Intent(
                Intent.ACTION_CALL,
                Uri.parse("tel:${Uri.encode(number)}")
            ))
            result.success(mapOf(
                "ok" to true,
                "action" to "call_contact",
                "contact" to contactName,
                "message" to "Llamada iniciada"
            ))
        } catch (error: Exception) {
            result.success(mapOf(
                "ok" to false,
                "error" to (error.message ?: "No hay una aplicación de teléfono disponible")
            ))
        }
    }

    private fun number(value: Any?): Int = when (value) {
        is Number -> value.toInt()
        else -> value?.toString()?.toIntOrNull() ?: 0
    }

    private fun parseDateTime(value: String?): Long {
        if (value.isNullOrBlank()) return System.currentTimeMillis()
        return try {
            OffsetDateTime.parse(value).toInstant().toEpochMilli()
        } catch (_: Exception) {
            LocalDateTime.parse(value).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        }
    }

    private fun findLaunchIntent(requested: String): Intent? {
        if (requested.isBlank()) return null
        activity.packageManager.getLaunchIntentForPackage(requested)?.let { return it }
        val query = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val match = activity.packageManager.queryIntentActivities(query, 0).firstOrNull { info ->
            val label = info.loadLabel(activity.packageManager).toString()
            label.equals(requested, ignoreCase = true) ||
                label.contains(requested, ignoreCase = true) ||
                info.activityInfo.packageName.equals(requested, ignoreCase = true)
        } ?: return null
        return activity.packageManager.getLaunchIntentForPackage(match.activityInfo.packageName)
    }

    private fun recognize(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(activity, Manifest.permission.RECORD_AUDIO) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingRecognition = arguments to result
            ActivityCompat.requestPermissions(
                activity,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                RECORD_AUDIO_REQUEST
            )
            return
        }
        startRecognition(arguments, result)
    }

    private fun startRecognition(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        stopRecognition(completeAsCancelled = true)
        recognitionResult = result
        val preferOnDevice = arguments["onDevice"] as? Boolean ?: true
        recognizer = if (preferOnDevice &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(activity)
        ) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(activity)
        } else {
            SpeechRecognizer.createSpeechRecognizer(activity)
        }
        recognizer?.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) {
                channel.invokeMethod("assistantSpeechState", "listening")
            }

            override fun onBeginningOfSpeech() {
                channel.invokeMethod("assistantSpeechState", "hearing")
            }

            override fun onRmsChanged(rmsdB: Float) {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {
                channel.invokeMethod("assistantSpeechState", "processing")
            }

            override fun onError(error: Int) {
                val pending = recognitionResult
                recognitionResult = null
                recognizer?.destroy()
                recognizer = null
                pending?.error("SPEECH_$error", speechErrorMessage(error), error)
            }

            override fun onResults(results: Bundle?) {
                val matches = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?: arrayListOf()
                val confidences = results?.getFloatArray(SpeechRecognizer.CONFIDENCE_SCORES)
                val pending = recognitionResult
                recognitionResult = null
                recognizer?.destroy()
                recognizer = null
                pending?.success(
                    mapOf(
                        "text" to (matches.firstOrNull() ?: ""),
                        "alternatives" to matches,
                        "confidences" to (confidences?.toList() ?: emptyList<Float>())
                    )
                )
            }

            override fun onPartialResults(partialResults: Bundle?) {
                val text = partialResults
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                if (!text.isNullOrBlank()) {
                    channel.invokeMethod("assistantSpeechPartial", text)
                }
            }

            override fun onEvent(eventType: Int, params: Bundle?) {}
        })

        val language = (arguments["language"] as? String)?.trim().orEmpty()
        val silenceMillis = (arguments["silenceMillis"] as? Number)
            ?.toInt()?.coerceIn(400, 3000) ?: 1200
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 3)
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS,
                silenceMillis.toLong()
            )
            putExtra(
                RecognizerIntent.EXTRA_SPEECH_INPUT_POSSIBLY_COMPLETE_SILENCE_LENGTH_MILLIS,
                (silenceMillis / 2).coerceAtLeast(300).toLong()
            )
            if (language.isNotEmpty()) putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
        }
        recognizer?.startListening(intent)
    }

    private fun speak(arguments: Map<String, Any?>, result: MethodChannel.Result) {
        val text = (arguments["text"] as? String).orEmpty()
        if (text.isBlank()) {
            result.success(true)
            return
        }
        stopTts(completeAsCancelled = true)
        ttsResult = result
        val language = (arguments["language"] as? String)?.trim().orEmpty()
        textToSpeech = TextToSpeech(activity) { status ->
            val engine = textToSpeech
            if (status != TextToSpeech.SUCCESS || engine == null) {
                val pending = ttsResult
                ttsResult = null
                pending?.error("TTS_INIT", "No se pudo iniciar el TTS del dispositivo", status)
                return@TextToSpeech
            }
            if (language.isNotEmpty()) engine.language = Locale.forLanguageTag(language)
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    activity.runOnUiThread {
                        channel.invokeMethod("assistantSpeechState", "speaking")
                    }
                }

                override fun onDone(utteranceId: String?) {
                    activity.runOnUiThread {
                        val pending = ttsResult
                        ttsResult = null
                        textToSpeech?.shutdown()
                        textToSpeech = null
                        pending?.success(true)
                    }
                }

                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) {
                    onError(utteranceId, TextToSpeech.ERROR)
                }

                override fun onError(utteranceId: String?, errorCode: Int) {
                    activity.runOnUiThread {
                        val pending = ttsResult
                        ttsResult = null
                        textToSpeech?.shutdown()
                        textToSpeech = null
                        pending?.error("TTS_$errorCode", "El TTS no pudo reproducir la respuesta", errorCode)
                    }
                }
            })
            engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, UUID.randomUUID().toString())
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray): Boolean {
        if (requestCode == PHONE_CALL_REQUEST) {
            val pending = pendingPhoneCall
            pendingPhoneCall = null
            if (pending == null) return true
            if (grantResults.isNotEmpty() &&
                grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            ) {
                executeAction(pending.first, pending.second)
            } else {
                pending.second.success(mapOf(
                    "ok" to false,
                    "error" to "Se necesitan permisos de teléfono y contactos"
                ))
            }
            return true
        }
        if (requestCode != RECORD_AUDIO_REQUEST) return false
        val pending = pendingRecognition
        pendingRecognition = null
        if (pending == null) return true
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            startRecognition(pending.first, pending.second)
        } else {
            pending.second.error(
                "MICROPHONE_PERMISSION",
                "Se necesita permiso de micrófono para escuchar",
                null
            )
        }
        return true
    }

    fun destroy() {
        stopAudio()
    }

    private fun stopAudio() {
        stopRecognition(completeAsCancelled = true)
        stopTts(completeAsCancelled = true)
        stopMedia(completeAsCancelled = true)
    }

    private fun stopMedia(completeAsCancelled: Boolean) {
        try {
            mediaPlayer?.stop()
        } catch (_: Exception) {}
        mediaPlayer?.release()
        mediaPlayer = null
        if (completeAsCancelled) mediaResult?.success(false)
        mediaResult = null
    }

    private fun stopRecognition(completeAsCancelled: Boolean) {
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
        if (completeAsCancelled) {
            recognitionResult?.success(mapOf("text" to "", "cancelled" to true))
        }
        recognitionResult = null
    }

    private fun stopTts(completeAsCancelled: Boolean) {
        textToSpeech?.stop()
        textToSpeech?.shutdown()
        textToSpeech = null
        if (completeAsCancelled) ttsResult?.success(false)
        ttsResult = null
    }

    private fun speechErrorMessage(error: Int): String = when (error) {
        SpeechRecognizer.ERROR_AUDIO -> "Error al capturar audio"
        SpeechRecognizer.ERROR_CLIENT -> "El reconocimiento se canceló"
        SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> "Falta permiso de micrófono"
        SpeechRecognizer.ERROR_NETWORK,
        SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> "El servicio de voz no tiene conexión"
        SpeechRecognizer.ERROR_NO_MATCH -> "No se entendió ninguna frase"
        SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> "El reconocimiento de voz está ocupado"
        SpeechRecognizer.ERROR_TOO_MANY_REQUESTS -> "Demasiadas solicitudes al reconocimiento de voz"
        SpeechRecognizer.ERROR_SERVER,
        SpeechRecognizer.ERROR_SERVER_DISCONNECTED -> "El servicio de voz no está disponible"
        SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> "No se detectó voz"
        SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED -> "El idioma de voz no está soportado"
        SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> "El idioma de voz no está descargado en el dispositivo"
        SpeechRecognizer.ERROR_CANNOT_LISTEN_TO_DOWNLOAD_EVENTS ->
            "No se puede supervisar la descarga del idioma de voz"
        else -> "Error de reconocimiento de voz ($error)"
    }

    companion object {
        private const val RECORD_AUDIO_REQUEST = 202
        private const val PHONE_CALL_REQUEST = 203
    }
}
