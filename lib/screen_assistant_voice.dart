import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

import 'main.dart';
import 'assistant_tools.dart';
import 'cluster_devices.dart';
import 'assistant_voice_engines.dart';
import 'screen_assistant.dart';
import 'server_controller.dart';

enum AssistantVoiceState { idle, listening, hearing, thinking, speaking, error }

bool assistantCanSubmitTypedPrompt(AssistantVoiceState state) =>
    state == AssistantVoiceState.idle ||
    state == AssistantVoiceState.error ||
    state == AssistantVoiceState.listening ||
    state == AssistantVoiceState.hearing;

Future<void> Function(String method, dynamic arguments)?
    activeAssistantVoicePlatformEventHandler;
bool assistantVoiceSessionActive = false;

Map<String, dynamic> assistantChatRequest(
    String modelName, String prompt, bool disableThinking,
    {List<String> images = const <String>[]}) {
  return {
    "model": modelName,
    "messages": [
      {
        "role": "system",
        "content": prefs?.getString("system") ?? "You are a helpful assistant"
      },
      {
        "role": "user",
        "content": prompt,
        if (images.isNotEmpty) "images": images,
      }
    ],
    "stream": true,
    "think": disableThinking
        ? false
        : (prefs?.getBool("thinkingEnabled:$modelName") ?? false),
    "keep_alive": activeKeepAlive(),
    "options": activeChatOptions(loadVision: images.isNotEmpty),
  };
}

Map<String, dynamic> assistantChatBody(Map<String, dynamic> initial,
    List<Map<String, dynamic>> conversation, List<Map<String, dynamic>> tools) {
  return <String, dynamic>{
    ...initial,
    "messages": conversation,
    if (tools.isNotEmpty) "tools": tools,
  };
}

List<Map<String, dynamic>> assistantConversationForTurn(
    Map<String, dynamic> initial, List<Map<String, dynamic>> sessionHistory) {
  final messages = (initial["messages"] as List)
      .map((message) => Map<String, dynamic>.from(message as Map))
      .toList();
  if (messages.length < 2) return messages;
  return <Map<String, dynamic>>[
    messages.first,
    ...sessionHistory.map(Map<String, dynamic>.from),
    messages.last,
  ];
}

void appendAssistantSessionTurn(
    List<Map<String, dynamic>> sessionHistory, String prompt, String answer,
    {List<String> images = const <String>[]}) {
  if (prompt.trim().isEmpty || answer.trim().isEmpty) return;
  sessionHistory.add({
    "role": "user",
    "content": prompt.trim(),
    if (images.isNotEmpty) "images": List<String>.from(images),
  });
  sessionHistory.add({
    "role": "assistant",
    "content": answer.trim(),
  });
}

/// Persists the assistant's in-session history to SharedPreferences so the
/// conversation survives screen destruction (like the text chat does).
void persistAssistantHistory(List<Map<String, dynamic>> sessionHistory) {
  try {
    prefs?.setString(
        "assistantHistory", jsonEncode(sessionHistory.map((e) => e).toList()));
  } catch (_) {}
}

/// Loads a previously persisted assistant history, if any.
List<Map<String, dynamic>> loadPersistedAssistantHistory() {
  final stored = prefs?.getString("assistantHistory");
  if (stored == null || stored.isEmpty) return [];
  try {
    return (jsonDecode(stored) as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  } catch (_) {
    return [];
  }
}

void clearPersistedAssistantHistory() {
  prefs?.remove("assistantHistory");
}

bool isRecoverableFollowUpSpeechError(String code) {
  return code == "SPEECH_5" ||
      code == "SPEECH_6" ||
      code == "SPEECH_7" ||
      code == "SPEECH_8";
}

Uri assistantChatUri(String? configuredHost) {
  final normalized = configuredHost?.trim().replaceFirst(RegExp(r"/+$"), "");
  final uri = normalized == null || normalized.isEmpty
      ? null
      : Uri.tryParse("$normalized/api/chat");
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    throw StateError(
        "No hay un servidor Ollama configurado. Abre Ajustes y selecciona Local, Servidor externo u Ollama Cloud.");
  }
  return uri;
}

const int _mib = 1024 * 1024;

/// Conservative admission control for direct multimodal inference on Android.
/// Model files are usually memory-mapped, so requiring the complete file to be
/// available would reject capable devices. We still reserve RAM for Android,
/// Flutter, the audio encoder and the KV cache and require a sizeable amount
/// of immediately available memory to avoid an LMKD process kill.
bool embeddedAudioFitsInDeviceMemory({
  required int modelSizeBytes,
  required int totalBytes,
  required int availableBytes,
  int thresholdBytes = 0,
  bool lowMemory = false,
}) {
  if (lowMemory || availableBytes <= 0) return false;
  final systemReserve =
      thresholdBytes * 2 > 1280 * _mib ? thresholdBytes * 2 : 1280 * _mib;
  if (availableBytes < systemReserve) return false;
  // Local /api/tags normally supplies the size. Failing closed avoids an
  // unsafe direct load when the tag could not be matched or queried.
  if (modelSizeBytes <= 0 || totalBytes <= 0) return false;
  // The audio encoder needs dequantized/work buffers beyond the mapped model,
  // projector and KV cache. Measurements on Android make 1.65x the stored
  // size plus an OS reserve a conservative cross-architecture lower bound.
  final requiredTotal = modelSizeBytes * 165 ~/ 100 + systemReserve;
  if (totalBytes < requiredTotal) return false;
  final modelHeadroom = modelSizeBytes * 50 ~/ 100;
  final requiredAvailable =
      modelHeadroom > 1280 * _mib ? modelHeadroom : 1280 * _mib;
  return availableBytes >= requiredAvailable;
}

String normalizedOllamaModelReference(String value) {
  final normalized = value.trim().toLowerCase();
  return normalized.endsWith(":latest")
      ? normalized.substring(0, normalized.length - ":latest".length)
      : normalized;
}

class _EmbeddedAudioRuntimePlan {
  const _EmbeddedAudioRuntimePlan.direct()
      : useDirectAudio = true,
        reason = null;

  const _EmbeddedAudioRuntimePlan.fallback(this.reason)
      : useDirectAudio = false;

  final bool useDirectAudio;
  final String? reason;
}

class _AssistantStreamingSpeech {
  _AssistantStreamingSpeech({
    required this.engine,
    required this.language,
    required this.onStarted,
  });

  final String engine;
  final String language;
  final VoidCallback onStarted;
  final StreamingSpeechChunker _chunker = StreamingSpeechChunker();
  final StringBuffer _completeText = StringBuffer();
  Future<void> _tail = Future<void>.value();
  bool _cancelled = false;
  bool _started = false;
  bool _queuedAny = false;

  void addDelta(String delta) {
    if (_cancelled || delta.isEmpty) return;
    _completeText.write(delta);
    for (final chunk in _chunker.add(delta)) {
      _enqueue(chunk);
    }
  }

  void _enqueue(String text) {
    if (_cancelled || text.trim().isEmpty) return;
    _queuedAny = true;
    _tail = _tail.then((_) async {
      if (_cancelled) return;
      if (!_started) {
        _started = true;
        onStarted();
      }
      if (engine == "device") {
        await ServerController.speakAssistantText(text, language: language);
      } else {
        await speakWithSupertonic(text, language);
      }
    });
  }

  Future<bool> finish(String finalAnswer) async {
    if (_cancelled) return false;
    if (_completeText.toString().trim() != finalAnswer.trim()) {
      cancel();
      return false;
    }
    final remainder = _chunker.takeRemainder();
    if (remainder.isNotEmpty) _enqueue(remainder);
    if (!_queuedAny) return false;
    await _tail;
    return !_cancelled;
  }

  void cancel() {
    _cancelled = true;
  }
}

class ScreenAssistantVoice extends StatefulWidget {
  const ScreenAssistantVoice({super.key, this.compact = false});

  final bool compact;

  @override
  State<ScreenAssistantVoice> createState() => _ScreenAssistantVoiceState();
}

class _ScreenAssistantVoiceState extends State<ScreenAssistantVoice> {
  AssistantVoiceState state = AssistantVoiceState.idle;
  String transcript = "";
  String response = "";
  String partialSpeech = "";
  String? error;
  http.Client? generationClient;
  _AssistantStreamingSpeech? activeStreamingSpeech;
  bool cancelled = false;
  final List<String> attachmentPaths = <String>[];
  final List<Map<String, dynamic>> sessionConversation =
      <Map<String, dynamic>>[];
  final TextEditingController typedPromptController = TextEditingController();
  bool followUpSpeechDetected = false;
  bool interruptVoiceLoopForText = false;
  bool preserveHistoryAfterVoiceLoop = false;
  bool directEmbeddedAudioDisabledForSession = false;
  Completer<void>? voiceLoopCompletion;

  bool get busy =>
      state != AssistantVoiceState.idle && state != AssistantVoiceState.error;
  bool get canSubmitTypedPrompt => assistantCanSubmitTypedPrompt(state);

  @override
  void initState() {
    super.initState();
    assistantVoiceSessionActive = true;
    unawaited(ServerController.setAssistantVoiceSessionState(active: true));
    activeAssistantVoicePlatformEventHandler = handlePlatformEvent;
    // Restore prior history (in-app and external panel share it via prefs).
    sessionConversation
      ..clear()
      ..addAll(loadPersistedAssistantHistory());
    // The in-app assistant can consume its launch context immediately. The
    // external assistant waits for an explicit tap on Share screen so a
    // screenshot is never attached merely because the assistant was invoked.
    if (!widget.compact) unawaited(_consumeAssistantScreenshot());
    WidgetsBinding.instance.addPostFrameCallback((_) => _startSession());
  }

  Future<void> handlePlatformEvent(String method, dynamic arguments) async {
    if (!mounted) return;
    if (method == "assistantSpeechPartial") {
      setState(() => partialSpeech = arguments?.toString() ?? "");
    } else if (method == "assistantSpeechState") {
      final next = arguments?.toString();
      setState(() {
        if (next == "listening") state = AssistantVoiceState.listening;
        if (next == "hearing") {
          followUpSpeechDetected = true;
          state = AssistantVoiceState.hearing;
        }
      });
    } else if (method == "assistantScreenshotAvailable") {
      if (!widget.compact) await _consumeAssistantScreenshot();
    } else if (method == "assistantScreenShareRequested") {
      await _consumeAssistantScreenshot(showFeedback: true);
    } else if (method == "assistantCameraCaptured") {
      await _attachExternalCamera(arguments);
    } else if (method == "assistantStopRequested") {
      await _stop();
    }
  }

  String? get assistantModel {
    final configured = prefs?.getString("assistantModel")?.trim();
    if (configured != null && configured.isNotEmpty) return configured;
    final current = model?.trim();
    return current == null || current.isEmpty ? null : current;
  }

  bool get modelSupportsVision {
    final name = assistantModel;
    if (name == null || name.isEmpty) return false;
    final detected = (prefs?.getStringList("detectedModelCapabilities:$name") ??
            const <String>[])
        .map((capability) => capability.toLowerCase())
        .toSet();
    final currentCapabilities =
        model == name ? selectedModelCapabilities : detected;
    return effectiveModelCapabilities(name, currentCapabilities)
            .contains("vision") ||
        (prefs?.getBool("attachmentOverride:$name") ?? false);
  }

  bool get modelSupportsEmbeddedAudio {
    final name = assistantModel;
    if (name == null || name.isEmpty) return false;
    final detected = (prefs?.getStringList("detectedModelCapabilities:$name") ??
            const <String>[])
        .map((capability) => capability.toLowerCase())
        .toSet();
    final currentCapabilities =
        model == name ? selectedModelCapabilities : detected;
    return effectiveModelCapabilities(name, currentCapabilities)
        .contains("audio");
  }

  Future<bool> _consumeAssistantScreenshot({bool showFeedback = false}) async {
    final path = await ServerController.consumeAssistantScreenshot();
    if (!mounted) return false;
    if (path == null || path.isEmpty) {
      if (showFeedback) {
        unawaited(ServerController.updateAssistantPanelState(
            "Screen capture is not available", busy));
      }
      return false;
    }
    if (assistantCapabilityEnabled("screen") &&
        clusterCaptureEntityEnabled(clusterEntityScreen) &&
        modelSupportsVision) {
      setState(() {
        if (!attachmentPaths.contains(path)) attachmentPaths.add(path);
      });
      if (showFeedback) {
        unawaited(ServerController.updateAssistantPanelState(
            "Screen attached", busy));
      }
      return true;
    } else {
      try {
        await File(path).delete();
      } catch (_) {}
      if (showFeedback) {
        final reason = !assistantCapabilityEnabled("screen")
            ? "Enable screen sharing in Assistant capabilities"
            : !modelSupportsVision
                ? "Enable vision for the assistant model"
                : "Screen capture is disabled for this cluster device";
        unawaited(ServerController.updateAssistantPanelState(reason, busy));
      }
      return false;
    }
  }

  Future<void> _attachExternalCamera(dynamic arguments) async {
    if (!mounted || arguments is! Map) return;
    final path = arguments["path"]?.toString();
    final front = arguments["front"] == true;
    if (path == null || path.isEmpty) return;
    final capability = front ? "frontCamera" : "rearCamera";
    final entity = front ? clusterEntityCameraFront : clusterEntityCameraRear;
    if (assistantCapabilityEnabled(capability) &&
        clusterCaptureEntityEnabled(entity) &&
        modelSupportsVision) {
      setState(() {
        if (!attachmentPaths.contains(path)) attachmentPaths.add(path);
      });
      unawaited(ServerController.updateAssistantPanelState(
          front ? "Front camera attached" : "Rear camera attached", busy));
      return;
    }
    try {
      await File(path).delete();
    } catch (_) {}
    final reason = !assistantCapabilityEnabled(capability)
        ? "Enable this camera in Assistant capabilities"
        : !modelSupportsVision
            ? "Enable vision for the assistant model"
            : "This camera is disabled for the cluster device";
    unawaited(ServerController.updateAssistantPanelState(reason, busy));
  }

  Future<void> _captureCamera(CameraDevice camera) async {
    final entity = camera == CameraDevice.front
        ? clusterEntityCameraFront
        : clusterEntityCameraRear;
    if (!clusterCaptureEntityEnabled(entity)) return;
    final remote = activeClusterRemoteMediaWorker(entity);
    if (remote != null) {
      final bytes = await const ClusterRemoteMediaClient()
          .captureCamera(remote, front: camera == CameraDevice.front);
      final path =
          '${Directory.systemTemp.path}/cluster-${camera.name}-${DateTime.now().microsecondsSinceEpoch}.jpg';
      await File(path).writeAsBytes(bytes, flush: true);
      if (mounted) setState(() => attachmentPaths.add(path));
      return;
    }
    final picked = await ImagePicker().pickImage(
        source: ImageSource.camera,
        preferredCameraDevice: camera,
        imageQuality: 88);
    if (picked != null && mounted) {
      setState(() => attachmentPaths.add(picked.path));
    }
  }

  Future<String> _listen(
      {required bool followUp, String? engineOverride}) async {
    final remoteMicrophone =
        activeClusterRemoteMediaWorker(clusterEntityMicrophone);
    if (!clusterHostEntityEnabled(clusterEntityMicrophone) &&
        remoteMicrophone == null) {
      throw StateError(
          'El micrófono de este dispositivo está desactivado en Multimodal device division.');
    }
    final engine =
        engineOverride ?? prefs?.getString("assistantSttEngine") ?? "device";
    Future<String> recognizeOnce() {
      if (remoteMicrophone != null) {
        if (engine != 'parakeet' &&
            engine != 'whisper' &&
            engine != 'nemotron') {
          throw StateError(
              'El STT del dispositivo no acepta audio de red. Usa audio embebido, Whisper, Nemotron o Parakeet para el micrófono remoto.');
        }
        followUpSpeechDetected = true;
        unawaited(
            ServerController.updateAssistantPanelState("Te escucho…", true));
        if (mounted) setState(() => state = AssistantVoiceState.hearing);
        return (() async {
          final captured = await const ClusterRemoteMediaClient()
              .captureSpeech(remoteMicrophone);
          if (captured == null) return '';
          return recognizeCapturedAssistantAudio(engine, captured);
        })();
      }
      if (engine == "parakeet" || engine == "whisper" || engine == "nemotron") {
        return recognizeWithOfflineAsr(engine, onSpeechDetected: () {
          followUpSpeechDetected = true;
          unawaited(
              ServerController.updateAssistantPanelState("Te escucho…", true));
          if (mounted) {
            setState(() => state = AssistantVoiceState.hearing);
          }
        });
      }
      return ServerController.recognizeAssistantSpeech(
              language: assistantDeviceSttLanguage(),
              onDevice: true,
              silenceMillis: (prefs?.getInt("assistantSttSilenceMs") ?? 1200)
                  .clamp(400, 3000)
                  .toInt())
          .then((result) => result["text"]?.toString().trim() ?? "");
    }

    return _listenUntilFollowUpDeadline(recognizeOnce, followUp: followUp);
  }

  Future<String> _listenUntilFollowUpDeadline(
      Future<String> Function() recognizeOnce,
      {required bool followUp}) async {
    if (!followUp) return recognizeOnce();
    final seconds =
        (prefs?.getInt("assistantFollowUpSeconds") ?? 10).clamp(1, 30).toInt();
    final deadline = DateTime.now().add(Duration(seconds: seconds));
    while (!cancelled && mounted && DateTime.now().isBefore(deadline)) {
      followUpSpeechDetected = false;
      final remaining = deadline.difference(DateTime.now());
      final recognition = recognizeOnce();
      try {
        final heard = await recognition.timeout(remaining);
        if (heard.trim().isNotEmpty) return heard.trim();
      } on TimeoutException {
        if (followUpSpeechDetected) {
          try {
            return (await recognition.timeout(const Duration(seconds: 60)))
                .trim();
          } on TimeoutException {
            // The recognizer became stuck after speech started; stop it below.
          }
        }
        break;
      } on PlatformException catch (speechError) {
        if (!isRecoverableFollowUpSpeechError(speechError.code)) rethrow;
      }
      if (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    await ServerController.stopAssistantAudio();
    await stopLocalAssistantVoiceEngine();
    return "";
  }

  Future<String> _listenWithEmbeddedAudioModel({required bool followUp}) async {
    return _listenUntilFollowUpDeadline(_transcribeEmbeddedAudio,
        followUp: followUp);
  }

  String _embeddedAudioFallbackEngine() {
    final configured = prefs?.getString("assistantSttEngine") ?? "device";
    if ((configured == "parakeet" ||
            configured == "whisper" ||
            configured == "nemotron") &&
        assistantVoiceModelInstalled(configured)) {
      return configured;
    }
    // Keep the same custom VAD whenever an offline recognizer is already
    // installed, avoiding a second recording or asking the user to repeat.
    final emergency = _installedEmergencyAudioEngine();
    if (emergency != null) return emergency;
    return "device";
  }

  String? _installedEmergencyAudioEngine() {
    final configured = prefs?.getString("assistantSttEngine") ?? "device";
    final candidates = <String>[
      if (configured != "device") configured,
      "whisper",
      "nemotron",
      "parakeet",
    ];
    for (final candidate in candidates) {
      if ((candidate == "whisper" ||
              candidate == "nemotron" ||
              candidate == "parakeet") &&
          assistantVoiceModelInstalled(candidate)) {
        return candidate;
      }
    }
    return null;
  }

  Future<bool> _ensureLocalAssistantServer() async {
    if (activeConnectionMode != connectionModeLocal) return true;
    await startConfiguredLocalServer();
    for (var attempt = 0; attempt < 20 && mounted && !cancelled; attempt++) {
      try {
        final response = await http
            .get(Uri.parse("$localOllamaHost/api/tags"))
            .timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) return true;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  Future<_EmbeddedAudioRuntimePlan> _embeddedAudioRuntimePlan() async {
    if (!modelSupportsEmbeddedAudio ||
        activeConnectionMode != connectionModeLocal ||
        !Platform.isAndroid) {
      return const _EmbeddedAudioRuntimePlan.direct();
    }
    if (!await _ensureLocalAssistantServer()) {
      return const _EmbeddedAudioRuntimePlan.fallback(
          "el servidor local no respondió");
    }
    final memory = await ServerController.getMemoryInfo();
    var modelSize = 0;
    try {
      final response = await http
          .get(Uri.parse("$localOllamaHost/api/tags"))
          .timeout(const Duration(seconds: 5));
      final decoded = jsonDecode(response.body);
      final models = decoded is Map ? decoded["models"] : null;
      if (models is List) {
        final selected = assistantModel == null
            ? null
            : normalizedOllamaModelReference(assistantModel!);
        for (final entry in models.whereType<Map>()) {
          final rawName = (entry["name"] ?? entry["model"])?.toString();
          final name =
              rawName == null ? null : normalizedOllamaModelReference(rawName);
          if (name == selected) {
            modelSize = (entry["size"] as num?)?.toInt() ?? 0;
            break;
          }
        }
      }
    } catch (_) {
      // Unknown size fails closed in embeddedAudioFitsInDeviceMemory.
    }
    int integer(String key) => (memory[key] as num?)?.toInt() ?? 0;
    final safe = embeddedAudioFitsInDeviceMemory(
      modelSizeBytes: modelSize,
      totalBytes: integer("totalBytes"),
      availableBytes: integer("availableBytes"),
      thresholdBytes: integer("thresholdBytes"),
      lowMemory: memory["lowMemory"] == true,
    );
    if (safe) return const _EmbeddedAudioRuntimePlan.direct();
    final modelGiB = modelSize <= 0
        ? "tamaño desconocido"
        : "${(modelSize / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
    final available = integer("availableBytes");
    final availableGiB = available <= 0
        ? "memoria disponible desconocida"
        : "${(available / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB libres";
    return _EmbeddedAudioRuntimePlan.fallback(
        "el modelo ocupa $modelGiB y el dispositivo tiene $availableGiB");
  }

  Future<String> _transcribeEmbeddedAudio() async {
    final selectedAssistantModel = assistantModel;
    if (selectedAssistantModel == null || selectedAssistantModel.isEmpty) {
      throw StateError("Selecciona un modelo para el asistente.");
    }
    final remoteMicrophone =
        activeClusterRemoteMediaWorker(clusterEntityMicrophone);
    final captured = remoteMicrophone == null
        ? await captureAssistantAudio(onSpeechDetected: () {
            followUpSpeechDetected = true;
            unawaited(ServerController.updateAssistantPanelState(
                "Te escucho…", true));
            if (mounted) setState(() => state = AssistantVoiceState.hearing);
          })
        : await const ClusterRemoteMediaClient()
            .captureSpeech(remoteMicrophone)
            .then((audio) {
            if (audio != null) {
              followUpSpeechDetected = true;
              unawaited(ServerController.updateAssistantPanelState(
                  "Te escucho…", true));
              if (mounted) setState(() => state = AssistantVoiceState.hearing);
            }
            return audio;
          });
    if (captured == null) return "";
    final audio = encodeCapturedAssistantAudio(captured);
    final body = assistantChatRequest(
        selectedAssistantModel,
        "Transcribe exactamente la petición hablada. Devuelve solamente las palabras pronunciadas.",
        true,
        images: <String>[audio])
      ..["stream"] = false
      ..["think"] = false;
    body["options"] = <String, dynamic>{
      ...Map<String, dynamic>.from(body["options"] as Map),
      "num_ctx": 2048,
      "num_predict": 256,
    };
    try {
      final response = await http
          .post(assistantChatUri(host),
              headers: {
                ...activeHostHeaders(),
                "Content-Type": "application/json",
              },
              body: jsonEncode(body))
          .timeout(activeInferenceTimeout());
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException("HTTP ${response.statusCode}: ${response.body}");
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded["message"] is! Map) {
        throw const FormatException("El modelo no devolvió una transcripción");
      }
      return ((decoded["message"] as Map)["content"] ?? "").toString().trim();
    } catch (directAudioError) {
      // Do not repeatedly crash/restart a local runner during follow-up turns.
      // The captured utterance is recovered below and the rest of this voice
      // session continues through the safe STT path.
      directEmbeddedAudioDisabledForSession = true;
      final emergencyEngine = _installedEmergencyAudioEngine();
      if (emergencyEngine == null) rethrow;
      final recovered =
          await recognizeCapturedAssistantAudio(emergencyEngine, captured);
      if (activeConnectionMode == connectionModeLocal) {
        await _ensureLocalAssistantServer();
      }
      if (recovered.isNotEmpty) return recovered;
      throw StateError(
          "El audio directo falló ($directAudioError) y el STT local no pudo recuperar la petición.");
    }
  }

  Future<String> _generate(String prompt,
      {void Function(String delta)? onTextDelta}) async {
    String remember(String answer, {List<String> images = const <String>[]}) {
      if (!cancelled) {
        appendAssistantSessionTurn(sessionConversation, prompt, answer,
            images: images);
        persistAssistantHistory(sessionConversation);
      }
      return answer;
    }

    final directCommand = parseDirectAssistantCommand(prompt);
    String? prefetchedWebResult;
    String? webEvidence;
    if (directCommand != null) {
      if (!assistantCapabilityEnabled(directCommand.capability)) {
        return remember(
            "Esa función está deshabilitada. Actívala en Assistant capabilities.");
      }
      if (mounted) {
        setState(() => response = "Ejecutando la acción…");
      }
      final result = await executeAssistantTool(
          directCommand.toolName, directCommand.arguments);
      if (directCommand.toolName != "web_search") {
        return remember(formatDirectAssistantResult(directCommand, result));
      }
      final decoded = jsonDecode(result);
      if (decoded is! Map || decoded["ok"] != true) {
        return remember(formatDirectAssistantResult(directCommand, result));
      }
      prefetchedWebResult = result;
      webEvidence = result;
    }
    final selectedAssistantModel = assistantModel;
    if (selectedAssistantModel == null || selectedAssistantModel.isEmpty) {
      if (directCommand != null && prefetchedWebResult != null) {
        return remember(
            formatDirectAssistantResult(directCommand, prefetchedWebResult));
      }
      throw StateError("Selecciona un modelo en Assistant capabilities.");
    }
    final images = <String>[];
    for (final path in attachmentPaths) {
      images.add(base64Encode(await File(path).readAsBytes()));
    }
    final client = http.Client();
    generationClient = client;
    final initial = assistantChatRequest(
        selectedAssistantModel,
        prompt,
        assistantCapabilityEnabled("screen") ||
            assistantCapabilityEnabled("frontCamera") ||
            assistantCapabilityEnabled("rearCamera"),
        images: images);
    final conversation =
        assistantConversationForTurn(initial, sessionConversation);
    final tools = prefetchedWebResult == null
        ? assistantToolsForPrompt(
            activeAssistantTools(), prompt, selectedAssistantModel)
        : <Map<String, dynamic>>[];
    final allowedToolNames = tools
        .map((tool) => (tool["function"] as Map)["name"].toString())
        .toSet();
    if (prefetchedWebResult != null) {
      conversation.insert(1, {
        "role": "system",
        "content": assistantWebResultsContext(prefetchedWebResult),
      });
    } else if (tools.isNotEmpty) {
      conversation.insert(1, {
        "role": "system",
        "content": assistantToolProtocol(tools),
      });
    }
    final streamSpeech =
        onTextDelta != null && tools.isEmpty && webEvidence == null;
    try {
      for (var toolRound = 0; toolRound < 4 && !cancelled; toolRound++) {
        final body = assistantChatBody(initial, conversation, tools);
        final request = http.Request("POST", assistantChatUri(host))
          ..headers.addAll({
            ...activeHostHeaders(),
            "Content-Type": "application/json",
          })
          ..body = jsonEncode(body);
        final streamed = await client.send(request);
        if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
          final errorBody = await streamed.stream.bytesToString();
          throw HttpException("HTTP ${streamed.statusCode}: $errorBody");
        }
        var turnText = "";
        final toolCalls = <Map<String, dynamic>>[];
        await for (final line in streamed.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())) {
          if (cancelled) break;
          if (line.trim().isEmpty) continue;
          final decoded = jsonDecode(line);
          if (decoded is Map && decoded["error"] != null) {
            throw StateError(decoded["error"].toString());
          }
          final message = decoded is Map ? decoded["message"] : null;
          if (message is Map) {
            final contentDelta = (message["content"] ?? "").toString();
            turnText += contentDelta;
            if (streamSpeech && contentDelta.isNotEmpty) {
              onTextDelta(contentDelta);
            }
            final calls = message["tool_calls"];
            if (calls is List) {
              toolCalls.addAll(calls
                  .whereType<Map>()
                  .map((call) => Map<String, dynamic>.from(call)));
            }
          }
          if (mounted && turnText.isNotEmpty) {
            setState(() => response = isDegenerateAssistantResponse(turnText)
                ? "El modelo ha generado una salida inválida."
                : turnText);
          }
        }
        if (toolCalls.isEmpty) {
          final textualCall = parseAssistantTextToolCall(turnText);
          if (textualCall != null &&
              allowedToolNames.contains(textualCall["name"])) {
            toolCalls.add({
              "function": {
                "name": textualCall["name"],
                "arguments": textualCall["arguments"] ?? <String, dynamic>{},
              }
            });
          }
        }
        if (cancelled || toolCalls.isEmpty) {
          if (webEvidence != null &&
              isSmallAssistantModel(selectedAssistantModel) &&
              !isAssistantWebResponseGrounded(turnText, webEvidence)) {
            return remember(formatAssistantWebResults(webEvidence),
                images: images);
          }
          if (turnText.toUpperCase().contains("ACTION_JSON")) {
            const answer =
                "No he podido interpretar la acción solicitada con este modelo.";
            return remember(
                webEvidence == null
                    ? answer
                    : ensureAssistantWebSources(answer, webEvidence),
                images: images);
          }
          var answer = isDegenerateAssistantResponse(turnText)
              ? "No he podido interpretar la petición con este modelo."
              : turnText.trim();
          if (webEvidence != null) {
            answer = ensureAssistantWebSources(answer, webEvidence);
          }
          return remember(answer, images: images);
        }
        conversation.add({
          "role": "assistant",
          "content": turnText,
          "tool_calls": toolCalls,
        });
        for (final call in toolCalls) {
          final function = call["function"];
          if (function is! Map) continue;
          final name = function["name"]?.toString() ?? "";
          final rawArguments = function["arguments"];
          final arguments = rawArguments is Map
              ? Map<String, dynamic>.from(rawArguments)
              : (rawArguments is String && rawArguments.trim().isNotEmpty
                  ? Map<String, dynamic>.from(jsonDecode(rawArguments) as Map)
                  : <String, dynamic>{});
          final normalized =
              normalizeAssistantToolCallForPrompt(prompt, name, arguments);
          final effectiveName = normalized["name"]?.toString() ?? name;
          final effectiveArguments = Map<String, dynamic>.from(
              normalized["arguments"] as Map? ?? <String, dynamic>{});
          if (!allowedToolNames.contains(effectiveName) ||
              !assistantToolAllowedForPrompt(prompt, effectiveName)) {
            conversation.add({
              "role": "user",
              "content":
                  "La acción $effectiveName no está justificada por la petición, está deshabilitada o no existe. Responde sin ejecutarla.",
            });
            continue;
          }
          if (mounted) {
            setState(() => response = "Ejecutando $effectiveName…");
          }
          final toolResult =
              await executeAssistantTool(effectiveName, effectiveArguments);
          if (effectiveName == "web_search") webEvidence = toolResult;
          conversation.add({
            "role": "user",
            "content":
                "Resultado de la acción $effectiveName: $toolResult\nContinúa y responde brevemente al usuario.",
          });
        }
      }
      throw StateError("El modelo encadenó demasiadas acciones.");
    } finally {
      generationClient = null;
      client.close();
    }
  }

  Future<void> _startSession() async {
    if (busy) return;
    while (mounted && prefs == null) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    if (!mounted) return;
    cancelled = false;
    interruptVoiceLoopForText = false;
    error = null;
    response = "";
    partialSpeech = "";
    directEmbeddedAudioDisabledForSession = false;
    if (!(prefs?.getBool("assistantEnabled") ?? false) ||
        !assistantCapabilityEnabled("voiceSession")) {
      setState(() {
        state = AssistantVoiceState.error;
        error =
            "Activa las funciones de asistente y Conversación por voz en Assistant capabilities.";
      });
      return;
    }
    final sttEngine = prefs?.getString("assistantSttEngine") ?? "device";
    if (!modelSupportsEmbeddedAudio &&
        (sttEngine == "parakeet" ||
            sttEngine == "whisper" ||
            sttEngine == "nemotron") &&
        !assistantVoiceModelInstalled(sttEngine)) {
      setState(() {
        state = AssistantVoiceState.error;
        error =
            "Importa primero el modelo $sttEngine en Assistant capabilities.";
      });
      return;
    }
    if ((prefs?.getString("assistantTtsEngine") ?? "device") == "supertonic" &&
        !assistantVoiceModelInstalled("supertonic")) {
      setState(() {
        state = AssistantVoiceState.error;
        error =
            "Importa primero el modelo Supertonic en Assistant capabilities.";
      });
      return;
    }
    final embeddedPlan = modelSupportsEmbeddedAudio
        ? await _embeddedAudioRuntimePlan()
        : const _EmbeddedAudioRuntimePlan.fallback(null);
    if (!embeddedPlan.useDirectAudio && embeddedPlan.reason != null) {
      debugPrint("Embedded audio fallback: ${embeddedPlan.reason}");
      unawaited(ServerController.updateAssistantPanelState(
          "STT seguro: memoria insuficiente para audio directo", false));
    }
    await ServerController.setKeepScreenOn(true);
    final loopCompletion = Completer<void>();
    voiceLoopCompletion = loopCompletion;
    try {
      var followUp = false;
      while (!cancelled && !interruptVoiceLoopForText && mounted) {
        unawaited(
            ServerController.updateAssistantPanelState("Escuchando…", true));
        setState(() {
          state = AssistantVoiceState.listening;
          partialSpeech = "";
        });
        final heard = embeddedPlan.useDirectAudio &&
                !directEmbeddedAudioDisabledForSession
            ? await _listenWithEmbeddedAudioModel(followUp: followUp)
            : await _listen(
                followUp: followUp,
                engineOverride: modelSupportsEmbeddedAudio
                    ? _embeddedAudioFallbackEngine()
                    : null);
        if (cancelled || interruptVoiceLoopForText || heard.isEmpty) {
          unawaited(ServerController.updateAssistantPanelState("Listo", false));
          break;
        }
        unawaited(ServerController.updateAssistantPanelState(
            "Generando respuesta…", true));
        setState(() {
          transcript = heard;
          partialSpeech = "";
          response = "";
          state = AssistantVoiceState.thinking;
        });
        final speech = _newStreamingSpeech();
        activeStreamingSpeech = speech;
        final answer = await _generate(heard, onTextDelta: speech.addDelta);
        if (cancelled) break;
        if (answer.isEmpty) {
          throw StateError("El modelo no devolvió una respuesta de voz.");
        }
        setState(() => response = answer);
        unawaited(
            ServerController.updateAssistantPanelState("Respondiendo…", true));
        final spokenWhileStreaming = await speech.finish(answer);
        if (!spokenWhileStreaming && !cancelled) {
          await _speakCompleteAnswer(answer);
        }
        if (identical(activeStreamingSpeech, speech)) {
          activeStreamingSpeech = null;
        }
        followUp = true;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (mounted && !cancelled) {
        unawaited(ServerController.updateAssistantPanelState("Listo", false));
        setState(() => state = AssistantVoiceState.idle);
      }
    } on PlatformException catch (platformError) {
      if (!mounted || cancelled) return;
      setState(() {
        state = AssistantVoiceState.error;
        error = platformError.message ?? platformError.code;
      });
    } catch (sessionError) {
      if (!mounted || cancelled) return;
      setState(() {
        state = AssistantVoiceState.error;
        error = sessionError.toString();
      });
    } finally {
      activeStreamingSpeech?.cancel();
      activeStreamingSpeech = null;
      preserveHistoryAfterVoiceLoop = false;
      if (!loopCompletion.isCompleted) loopCompletion.complete();
      if (identical(voiceLoopCompletion, loopCompletion)) {
        voiceLoopCompletion = null;
      }
      unawaited(_endSessionInBackground());
      await ServerController.setKeepScreenOn(false);
    }
  }

  Future<void> _submitTypedPrompt() async {
    final prompt = typedPromptController.text.trim();
    if (prompt.isEmpty || !canSubmitTypedPrompt) return;
    if (state == AssistantVoiceState.listening ||
        state == AssistantVoiceState.hearing) {
      preserveHistoryAfterVoiceLoop = true;
      interruptVoiceLoopForText = true;
      await ServerController.stopAssistantAudio();
      await stopLocalAssistantVoiceEngine();
      final completion = voiceLoopCompletion;
      if (completion != null) {
        try {
          await completion.future.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          // Continue with text even if a vendor recognizer is slow to release.
        }
      }
      preserveHistoryAfterVoiceLoop = false;
      interruptVoiceLoopForText = false;
      if (!mounted) return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    typedPromptController.clear();
    cancelled = false;
    error = null;
    await ServerController.setKeepScreenOn(true);
    setState(() {
      transcript = prompt;
      partialSpeech = "";
      response = "";
      state = AssistantVoiceState.thinking;
    });
    try {
      final speech = _newStreamingSpeech();
      activeStreamingSpeech = speech;
      final answer = await _generate(prompt, onTextDelta: speech.addDelta);
      if (cancelled) return;
      if (answer.isEmpty) {
        throw StateError("El modelo no devolvió una respuesta.");
      }
      setState(() => response = answer);
      final spokenWhileStreaming = await speech.finish(answer);
      if (!spokenWhileStreaming && !cancelled) {
        await _speakCompleteAnswer(answer);
      }
      if (identical(activeStreamingSpeech, speech)) {
        activeStreamingSpeech = null;
      }
      if (mounted && !cancelled) {
        setState(() => state = AssistantVoiceState.idle);
      }
    } on PlatformException catch (platformError) {
      if (!mounted || cancelled) return;
      setState(() {
        state = AssistantVoiceState.error;
        error = platformError.message ?? platformError.code;
      });
    } catch (sessionError) {
      if (!mounted || cancelled) return;
      setState(() {
        state = AssistantVoiceState.error;
        error = sessionError.toString();
      });
    } finally {
      activeStreamingSpeech?.cancel();
      activeStreamingSpeech = null;
      await ServerController.setKeepScreenOn(false);
    }
  }

  _AssistantStreamingSpeech _newStreamingSpeech() {
    return _AssistantStreamingSpeech(
        engine: prefs?.getString("assistantTtsEngine") ?? "device",
        language: prefs?.getString("assistantTtsLanguage") ?? "es",
        onStarted: () {
          if (mounted && !cancelled) {
            setState(() => state = AssistantVoiceState.speaking);
          }
        });
  }

  Future<void> _endSessionInBackground() async {
    // Voice session finished: mark it inactive so the overlay can go back.
    assistantVoiceSessionActive = false;
    await ServerController.setAssistantVoiceSessionState(active: false);
  }

  Future<void> _speakCompleteAnswer(String answer) async {
    if (mounted) setState(() => state = AssistantVoiceState.speaking);
    if ((prefs?.getString("assistantTtsEngine") ?? "device") == "device") {
      await ServerController.speakAssistantText(answer,
          language: prefs?.getString("assistantTtsLanguage") ?? "es");
      return;
    }
    if (!assistantVoiceModelInstalled("supertonic")) {
      throw StateError(
          "Importa primero el modelo Supertonic en Assistant capabilities.");
    }
    await speakWithSupertonic(
        answer, prefs?.getString("assistantTtsLanguage") ?? "es");
  }

  Future<void> _stop() async {
    cancelled = true;
    interruptVoiceLoopForText = false;
    preserveHistoryAfterVoiceLoop = false;
    sessionConversation.clear();
    clearPersistedAssistantHistory();
    activeStreamingSpeech?.cancel();
    activeStreamingSpeech = null;
    generationClient?.close();
    generationClient = null;
    await ServerController.stopAssistantAudio();
    await stopLocalAssistantVoiceEngine();
    unawaited(_endSessionInBackground());
    await ServerController.setKeepScreenOn(false);
    unawaited(ServerController.updateAssistantPanelState(
        appText("Stopped", "Detenido"), false));
    if (mounted) setState(() => state = AssistantVoiceState.idle);
  }

  String get stateLabel => switch (state) {
        AssistantVoiceState.listening => appText("Listening…", "Escuchando…"),
        AssistantVoiceState.hearing => appText("I hear you…", "Te escucho…"),
        AssistantVoiceState.thinking =>
          appText("Generating response…", "Generando respuesta…"),
        AssistantVoiceState.speaking => appText("Responding…", "Respondiendo…"),
        AssistantVoiceState.error =>
          appText("Unable to continue", "No se pudo continuar"),
        _ => appText("Tap the logo to speak", "Toca el logo para hablar"),
      };

  Future<void> _closeCompactAssistant() async {
    await _stop();
    await ServerController.finishAssistantOverlay();
  }

  Widget _buildCompactAssistant(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth >= 320 && constraints.maxHeight >= 130) {
        return _buildWideCompactAssistant(context);
      }
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
          backgroundColor: Colors.transparent,
          body: Center(
              child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Material(
                      elevation: 8,
                      color: colors.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(24),
                      clipBehavior: Clip.antiAlias,
                      child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          child: Row(children: [
                            Semantics(
                                button: true,
                                label: busy
                                    ? "Detener asistente"
                                    : "Hablar con Ollama",
                                child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: busy ? _stop : _startSession,
                                    child: AnimatedContainer(
                                        duration:
                                            const Duration(milliseconds: 220),
                                        width: 52,
                                        height: 52,
                                        padding: const EdgeInsets.all(9),
                                        decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: colors.surface,
                                            border: Border.all(
                                                width: busy ? 3 : 1,
                                                color: colors.primary)),
                                        child: ColorFiltered(
                                            colorFilter: ColorFilter.mode(
                                                colors.onSurface,
                                                BlendMode.srcIn),
                                            child: const Image(
                                                image: AssetImage(
                                                    "assets/logo512.png")))))),
                            const SizedBox(width: 8),
                            Expanded(
                                child: Row(children: [
                              if (busy) ...[
                                const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2)),
                                const SizedBox(width: 6),
                              ],
                              Expanded(
                                  child: Text(stateLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .labelMedium))
                            ])),
                          ]))))));
    });
  }

  Widget _buildWideCompactAssistant(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final visibleText = partialSpeech.isNotEmpty
        ? partialSpeech
        : response.isNotEmpty
            ? response
            : transcript;
    return Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
            top: false,
            child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Material(
                        elevation: 16,
                        shadowColor: Colors.black54,
                        color: colors.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(32),
                        clipBehavior: Clip.antiAlias,
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 10, 8, 10),
                                child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Semantics(
                                          button: true,
                                          label: busy
                                              ? "Detener asistente"
                                              : "Hablar con Ollama",
                                          child: InkWell(
                                              customBorder:
                                                  const CircleBorder(),
                                              onTap:
                                                  busy ? _stop : _startSession,
                                              child: AnimatedContainer(
                                                  duration: const Duration(
                                                      milliseconds: 220),
                                                  width: 68,
                                                  height: 68,
                                                  padding:
                                                      const EdgeInsets.all(12),
                                                  decoration: BoxDecoration(
                                                      shape: BoxShape.circle,
                                                      color: colors.surface,
                                                      border: Border.all(
                                                          width: busy ? 3 : 1,
                                                          color:
                                                              colors.primary)),
                                                  child: ColorFiltered(
                                                      colorFilter:
                                                          ColorFilter.mode(
                                                              colors.onSurface,
                                                              BlendMode.srcIn),
                                                      child: const Image(
                                                          image: AssetImage(
                                                              "assets/logo512.png")))))),
                                      const SizedBox(width: 12),
                                      Flexible(
                                          child: ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                  minWidth: 130),
                                              child: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    Row(children: [
                                                      if (busy) ...[
                                                        const SizedBox(
                                                            width: 15,
                                                            height: 15,
                                                            child:
                                                                CircularProgressIndicator(
                                                                    strokeWidth:
                                                                        2)),
                                                        const SizedBox(
                                                            width: 7),
                                                      ],
                                                      Flexible(
                                                          child: Text(
                                                              stateLabel,
                                                              maxLines: 1,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: Theme.of(
                                                                      context)
                                                                  .textTheme
                                                                  .labelLarge))
                                                    ]),
                                                    if (visibleText
                                                        .isNotEmpty) ...[
                                                      const SizedBox(height: 4),
                                                      Text(visibleText,
                                                          maxLines: 3,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style:
                                                              Theme.of(context)
                                                                  .textTheme
                                                                  .bodyMedium)
                                                    ],
                                                    if (error != null) ...[
                                                      const SizedBox(height: 4),
                                                      Text(error!,
                                                          maxLines: 2,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: Theme.of(
                                                                  context)
                                                              .textTheme
                                                              .bodySmall
                                                              ?.copyWith(
                                                                  color: colors
                                                                      .error))
                                                    ]
                                                  ]))),
                                      if (busy)
                                        IconButton(
                                            tooltip: appText("Stop", "Detener"),
                                            onPressed: _stop,
                                            icon: const Icon(
                                                Icons.stop_circle_outlined)),
                                      IconButton(
                                          tooltip: appText("Close", "Cerrar"),
                                          onPressed: _closeCompactAssistant,
                                          icon: const Icon(Icons.close_rounded))
                                    ]))))))));
  }

  @override
  void dispose() {
    assistantVoiceSessionActive = false;
    unawaited(ServerController.setAssistantVoiceSessionState(active: false));
    activeAssistantVoicePlatformEventHandler = null;
    cancelled = true;
    // Keep the history cleared only in-memory; the persisted copy survives so
    // the external panel can continue the same conversation later.
    sessionConversation.clear();
    activeStreamingSpeech?.cancel();
    activeStreamingSpeech = null;
    generationClient?.close();
    unawaited(ServerController.stopAssistantAudio());
    unawaited(stopLocalAssistantVoiceEngine());
    unawaited(ServerController.setKeepScreenOn(false));
    typedPromptController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact) return _buildCompactAssistant(context);
    return Scaffold(
        appBar: AppBar(
            title: Text(appText("Ollama Assistant", "Asistente Ollama")),
            actions: [
              IconButton(
                  tooltip: appText(
                      "Assistant capabilities", "Funciones del asistente"),
                  onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ScreenAssistant())),
                  icon: const Icon(Icons.settings_outlined))
            ]),
        body: SafeArea(
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(children: [
                  const Spacer(),
                  Semantics(
                      button: true,
                      label: busy
                          ? appText("Stop assistant", "Detener asistente")
                          : appText("Talk to Ollama", "Hablar con Ollama"),
                      child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: busy ? _stop : _startSession,
                          child: AnimatedContainer(
                              duration: const Duration(milliseconds: 250),
                              width: 150,
                              height: 150,
                              padding: const EdgeInsets.all(28),
                              decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Theme.of(context)
                                      .colorScheme
                                      .primaryContainer,
                                  border: Border.all(
                                      width: busy ? 5 : 1,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .primary)),
                              child: const Image(
                                  image: AssetImage("assets/logo512.png"))))),
                  const SizedBox(height: 20),
                  if (busy) const CircularProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(stateLabel,
                      style: Theme.of(context).textTheme.titleMedium),
                  if (partialSpeech.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(partialSpeech,
                        style: Theme.of(context)
                            .textTheme
                            .bodyLarge
                            ?.copyWith(color: Colors.grey))
                  ],
                  if (!modelSupportsVision &&
                      (assistantCapabilityEnabled("screen") ||
                          assistantCapabilityEnabled("frontCamera") ||
                          assistantCapabilityEnabled("rearCamera")))
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                            appText(
                                "Vision is not enabled for the assistant model. You can enable it in the model editor.",
                                "El modelo del asistente no tiene activada la capacidad de visión. Puedes habilitarla desde el editor del modelo."),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Theme.of(context).colorScheme.error))),
                  if (modelSupportsVision &&
                      (assistantCapabilityEnabled("frontCamera") ||
                          assistantCapabilityEnabled("rearCamera")))
                    Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Wrap(spacing: 8, children: [
                          if (assistantCapabilityEnabled("frontCamera") &&
                              clusterCaptureEntityEnabled(
                                  clusterEntityCameraFront))
                            ActionChip(
                                avatar: const Icon(Icons.camera_front_rounded),
                                label: Text(
                                    appText("Front camera", "Cámara frontal")),
                                onPressed: busy
                                    ? null
                                    : () => _captureCamera(CameraDevice.front)),
                          if (assistantCapabilityEnabled("rearCamera") &&
                              clusterCaptureEntityEnabled(
                                  clusterEntityCameraRear))
                            ActionChip(
                                avatar: const Icon(Icons.camera_rear_rounded),
                                label: Text(
                                    appText("Rear camera", "Cámara trasera")),
                                onPressed: busy
                                    ? null
                                    : () => _captureCamera(CameraDevice.rear)),
                        ])),
                  if (attachmentPaths.isNotEmpty)
                    SizedBox(
                        height: 92,
                        child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: attachmentPaths.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 8),
                            itemBuilder: (context, index) => Stack(children: [
                                  ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Image.file(
                                          File(attachmentPaths[index]),
                                          width: 92,
                                          height: 92,
                                          fit: BoxFit.cover)),
                                  Positioned(
                                      right: 0,
                                      child: IconButton.filledTonal(
                                          tooltip: appText(
                                              "Remove image", "Quitar imagen"),
                                          iconSize: 18,
                                          onPressed: busy
                                              ? null
                                              : () => setState(() =>
                                                  attachmentPaths
                                                      .removeAt(index)),
                                          icon:
                                              const Icon(Icons.close_rounded)))
                                ]))),
                  const Spacer(),
                  if (transcript.isNotEmpty)
                    Align(
                        alignment: Alignment.centerRight,
                        child: Card(
                            child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Text(transcript)))),
                  if (response.isNotEmpty)
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Card(
                            child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: MarkdownBody(
                                  data: response,
                                  onTapLink: (_, href, __) async {
                                    final uri = Uri.tryParse(href ?? "");
                                    if (uri != null &&
                                        (uri.scheme == "http" ||
                                            uri.scheme == "https")) {
                                      await launchUrl(uri,
                                          mode: LaunchMode.inAppBrowserView);
                                    }
                                  },
                                )))),
                  if (error != null)
                    Card(
                        color: Theme.of(context).colorScheme.errorContainer,
                        child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(error!))),
                  const Spacer(),
                  TextField(
                      controller: typedPromptController,
                      enabled: canSubmitTypedPrompt,
                      minLines: 1,
                      maxLines: 3,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _submitTypedPrompt(),
                      decoration: InputDecoration(
                          labelText:
                              appText("Write to the assistant",
                                  "Escribir al asistente"),
                          hintText:
                              "También funciona sin reconocimiento de voz",
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                              tooltip: appText("Send", "Enviar"),
                              onPressed: canSubmitTypedPrompt
                                  ? _submitTypedPrompt
                                  : null,
                              icon: const Icon(Icons.send_rounded)))),
                ]))));
  }
}
