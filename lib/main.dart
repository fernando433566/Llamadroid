import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'package:ollama_app/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

import 'screen_settings.dart';
import 'screen_assistant.dart';
import 'assistant_tools.dart';
import 'cluster_devices.dart';
import 'document_rag.dart';
import 'screen_assistant_voice.dart';
import 'screen_welcome.dart';
import 'server_controller.dart';
import 'worker_setter.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:flutter_chat_ui/flutter_chat_ui.dart';
import 'package:uuid/uuid.dart';
import 'package:image_picker/image_picker.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:http/http.dart' as http;
import 'package:ollama_dart/ollama_dart.dart' as llama;
import 'package:dartx/dartx.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;
import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:flutter_displaymode/flutter_displaymode.dart';

// client configuration

// use host or not, if false dialog is shown
const useHost = false;
// host of ollama, must be accessible from the client, without trailing slash, will always be accepted as valid
const fixedHost = "http://example.com:11434";
// use model or not, if false selector is shown
const useModel = false;
// model name as string, must be valid ollama model!
const fixedModel = "gemma";
// recommended models, shown with as star in model selector
const recommendedModels = ["gemma", "llama3"];
// allow opening of settings
const allowSettings = true;
// allow multiple chats
const allowMultipleChats = true;

const connectionModeLocal = "local";
const connectionModeExternal = "external";
const connectionModeCloud = "cloud";
const localOllamaHost = "http://localhost:11434";
const ollamaCloudHost = "https://ollama.com";
const cloudApiKeyStorageKey = "ollama_cloud_api_key";
const computeModeAdaptive = "adaptive";
const computeModeGpuOnly = "gpu_only";
const computeModeCpuOnly = "cpu_only";
const computeModeHybrid = "hybrid";
const computeModeForced = "forced";
const computeModeSynergy = "synergy";
const defaultChatTemperature = 0.8;
const defaultChatTopP = 0.9;
const defaultChatTopK = 40;
const defaultChatMaxTokens = 2048;
const defaultChatContextTokens = 4096;
const defaultChatMinResponseTokens = 0;
const defaultChatReasoningBudget = -1;
const unlimitedLoadedModelsValue = 2147483647;

String mergeSystemContexts(String base, Iterable<String> supplemental) {
  final usable = supplemental
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
  return usable.isEmpty ? base : '$base\n\n${usable.join('\n\n')}';
}

// client configuration end

SharedPreferences? prefs;
ThemeData? theme;
ThemeData? themeDark;

const secureStorage = FlutterSecureStorage();
String activeConnectionMode = connectionModeExternal;
String? cloudApiKey;

String? model;
String? host;

bool multimodal = false;
Set<String> selectedModelCapabilities = <String>{};
bool attachmentOverride = false;

List<types.Message> messages = [];
String? chatUuid;
bool chatAllowed = true;

final user = types.User(id: const Uuid().v4());
final assistant = types.User(id: const Uuid().v4());

bool settingsOpen = false;
http.Client? activeChatHttpClient;

const supportedImageExtensions = <String>[
  "jpg",
  "jpeg",
  "png",
  "gif",
  "webp",
  "svg",
];

const supportedAudioExtensions = <String>["mp3", "wav"];

const supportedDocumentExtensions = <String>[
  "pdf",
  "doc",
  "docx",
  "odt",
  "rtf",
  "txt",
  "md",
  "csv",
  "tsv",
  "xls",
  "xlsx",
  "ods",
  "ppt",
  "pptx",
  "odp",
  "epub",
  "html",
  "htm",
  "xml",
  "json",
  "yaml",
  "yml",
  "log",
];

const configurableModelCapabilities = <String, String>{
  "vision": "Images",
  "files": "Adjuntar archivos de texto o código",
  "documents": "Attach document",
  "tools": "Herramientas y comportamiento agéntico",
  "thinking": "Razonamiento separado",
  "audio": "Audio",
};

const modelCapabilityDescriptions = <String, String>{
  "vision": "JPEG, PNG, GIF, WebP y SVG (convertido a PNG)",
  "files": "Código fuente, Markdown y otros archivos de texto",
  "documents":
      "PDF, DOC/DOCX, ODT, RTF, TXT/Markdown, hojas de cálculo, presentaciones, EPUB, HTML, XML, JSON y YAML",
  "tools": "Function calling, Grounding with the internet y acciones",
  "thinking": "Muestra el razonamiento separado de la respuesta",
  "audio": "MP3 y WAV enviados directamente a modelos con audio",
};

IconData chatActionIconForCapabilities(Set<String> capabilities) {
  final hasNonVisualAction =
      capabilities.any(const {"files", "documents", "audio", "tools"}.contains);
  return hasNonVisualAction ? Icons.add_rounded : Icons.photo_camera_rounded;
}

bool hasModelAttachmentCapabilities(Set<String> capabilities) =>
    capabilities.contains("vision") ||
    capabilities.contains("files") ||
    capabilities.contains("documents") ||
    capabilities.contains("audio");

String _modelCapabilitiesOverrideKey(String modelName) =>
    "modelCapabilitiesOverride:$modelName";
String _detectedModelCapabilitiesKey(String modelName) =>
    "detectedModelCapabilities:$modelName";

Set<String> effectiveModelCapabilities(
    String modelName, Set<String> detectedCapabilities) {
  final overridden =
      prefs?.getStringList(_modelCapabilitiesOverrideKey(modelName));
  final effective = (overridden ?? detectedCapabilities.toList())
      .map((capability) => capability.toLowerCase())
      .toSet();
  if (!(prefs?.getBool("enableEmbeddedAudioModels") ?? false)) {
    effective.remove("audio");
  }
  return effective;
}

bool ggufImportEnabled() => prefs?.getBool("enableGgufModels") ?? false;

bool extraComputeModesEnabled() =>
    prefs?.getBool("enableExtraComputeModes") ?? false;

String configuredComputeMode() {
  final saved = prefs?.getString("computeMode") ?? computeModeAdaptive;
  if (saved == computeModeGpuOnly || saved == computeModeCpuOnly) {
    return computeModeForced;
  }
  if (saved == computeModeHybrid) return computeModeSynergy;
  // Offloading was exposed by an older experimental build but never had a
  // runtime capable of moving already-loaded tensors. Migrate it safely.
  if (saved == "offloading") return computeModeAdaptive;
  return saved;
}

String configuredForcedDevice() {
  final saved = prefs?.getString("computeMode");
  if (saved == computeModeGpuOnly) return "gpu";
  if (saved == computeModeCpuOnly) return "cpu";
  return prefs?.getString("forcedComputeDevice") ?? "gpu";
}

Future<void> rememberDetectedModelCapabilities(
    String modelName, Set<String> capabilities) async {
  await prefs?.setStringList(
      _detectedModelCapabilitiesKey(modelName), capabilities.toList()..sort());
}

Future<Set<String>?> showModelCapabilitiesEditor(
    BuildContext context, String modelName, Set<String> currentCapabilities) {
  final detected =
      (prefs?.getStringList(_detectedModelCapabilitiesKey(modelName)) ??
              currentCapabilities.toList())
          .map((capability) => capability.toLowerCase())
          .toSet();
  final selected = Set<String>.from(currentCapabilities);
  var useDetected =
      !prefs!.containsKey(_modelCapabilitiesOverrideKey(modelName));

  return showDialog<Set<String>>(
      context: context,
      builder: (dialogContext) =>
          StatefulBuilder(builder: (dialogContext, setDialogState) {
            return AlertDialog(
                title: Text(appText(
                    "$modelName capabilities", "Capacidades de $modelName")),
                content: SizedBox(
                    width: 420,
                    child: SingleChildScrollView(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      const Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                              "Estos interruptores solo cambian cómo la aplicación trata al modelo. No modifican el modelo ni añaden capacidades al motor.")),
                      const SizedBox(height: 12),
                      ...configurableModelCapabilities.entries
                          .where((entry) =>
                              entry.key != "audio" ||
                              (prefs?.getBool("enableEmbeddedAudioModels") ??
                                  false))
                          .map((entry) => SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(entry.value),
                              subtitle: Text(
                                  modelCapabilityDescriptions[entry.key] ??
                                      entry.key),
                              value: selected.contains(entry.key),
                              onChanged: (value) {
                                useDetected = false;
                                if (value) {
                                  selected.add(entry.key);
                                } else {
                                  selected.remove(entry.key);
                                }
                                setDialogState(() {});
                              })),
                      if (useDetected)
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                                appText("Using detected capabilities",
                                    "Usando capacidades detectadas"),
                                style: const TextStyle(color: Colors.grey)))
                    ]))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: Text(appText("Cancel", "Cancelar"))),
                  TextButton(
                      onPressed: () {
                        useDetected = true;
                        selected
                          ..clear()
                          ..addAll(detected);
                        setDialogState(() {});
                      },
                      child: Text(appText("Use detected", "Usar detectadas"))),
                  FilledButton(
                      onPressed: () async {
                        if (useDetected) {
                          await prefs?.remove(
                              _modelCapabilitiesOverrideKey(modelName));
                        } else {
                          await prefs?.setStringList(
                              _modelCapabilitiesOverrideKey(modelName),
                              selected.toList()..sort());
                        }
                        if (model == modelName) {
                          selectedModelCapabilities =
                              Set<String>.from(selected);
                          attachmentOverride =
                              prefs?.getBool("attachmentOverride:$modelName") ??
                                  false;
                          multimodal = hasModelAttachmentCapabilities(selected);
                          await prefs?.setStringList(
                              "modelCapabilities", selected.toList()..sort());
                          await prefs?.setBool("multimodal", multimodal);
                        }
                        if (dialogContext.mounted) {
                          Navigator.of(dialogContext)
                              .pop(Set<String>.from(selected));
                        }
                      },
                      child: Text(appText("Save", "Guardar")))
                ]);
          }));
}

void cancelActiveChatRequest() {
  activeChatHttpClient?.close();
  activeChatHttpClient = null;
}

Map<String, String> activeHostHeaders() {
  if (activeConnectionMode == connectionModeCloud) {
    final key = cloudApiKey?.trim() ?? "";
    return key.isEmpty ? {} : {"Authorization": "Bearer $key"};
  }
  if (activeConnectionMode == connectionModeLocal) return {};

  try {
    final decoded = jsonDecode(prefs?.getString("hostHeaders") ?? "{}");
    if (decoded is! Map) return {};
    return decoded
        .map((key, value) => MapEntry(key.toString(), value.toString()));
  } catch (_) {
    return {};
  }
}

Duration activeInferenceTimeout() => activeConnectionMode == connectionModeLocal
    ? const Duration(minutes: 10)
    : const Duration(minutes: 2);

Future<String> imageContentFromUri(String uri) async {
  if (uri.startsWith("data:") && uri.contains(",")) {
    return uri.substring(uri.indexOf(",") + 1);
  }
  return base64.encode(await File(uri).readAsBytes());
}

Future<Uint8List> convertSvgToPng(Uint8List source,
    {int maxDimension = 2048}) async {
  final pictureInfo = await vg.loadPicture(
    SvgStringLoader(utf8.decode(source, allowMalformed: false)),
    null,
  );
  try {
    final sourceWidth =
        pictureInfo.size.width.isFinite && pictureInfo.size.width > 0
            ? pictureInfo.size.width
            : 1024.0;
    final sourceHeight =
        pictureInfo.size.height.isFinite && pictureInfo.size.height > 0
            ? pictureInfo.size.height
            : 1024.0;
    final scale = min(1.0, maxDimension / max(sourceWidth, sourceHeight));
    final width = max(1, (sourceWidth * scale).round());
    final height = max(1, (sourceHeight * scale).round());
    final raster = await pictureInfo.picture.toImage(width, height);
    try {
      final data = await raster.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) {
        throw const FormatException("No se pudo convertir el SVG a PNG.");
      }
      return data.buffer.asUint8List();
    } finally {
      raster.dispose();
    }
  } finally {
    pictureInfo.picture.dispose();
  }
}

bool isDirectMediaAttachment(types.Message message) =>
    message is types.ImageMessage ||
    (message is types.FileMessage &&
        (message.mimeType?.toLowerCase().startsWith("audio/") ?? false));

Future<String> directMediaContent(types.Message message) {
  if (message is types.ImageMessage) return imageContentFromUri(message.uri);
  if (message is types.FileMessage) return imageContentFromUri(message.uri);
  throw ArgumentError("Unsupported media attachment");
}

llama.RequestOptions? activeComputeOptions() {
  if (activeConnectionMode != connectionModeLocal) return null;
  return switch (configuredComputeMode()) {
    computeModeForced => switch (configuredForcedDevice()) {
        "cpu" => const llama.RequestOptions(numGpu: 0),
        "gpu" => const llama.RequestOptions(numGpu: 999),
        _ => const llama.RequestOptions(numGpu: 0),
      },
    // Values -1000..-1100 are handled by the bundled Android server as an
    // explicit GPU percentage, including the CPU-only and GPU-only endpoints.
    // Stock remote Ollama servers never receive this extension.
    computeModeSynergy => llama.RequestOptions(
        numGpu: -1000 -
            (prefs?.getInt("synergyGpuPercent") ??
                    prefs?.getInt("hybridGpuPercent") ??
                    50)
                .clamp(0, 100)),
    _ => const llama.RequestOptions(numGpu: -1),
  };
}

bool activeThinkingEnabled() {
  final selectedModel = model;
  if (selectedModel == null) return false;
  return prefs?.getBool("thinkingEnabled:$selectedModel") ??
      selectedModelCapabilities.contains("thinking");
}

double _modelDoublePreference(String key, double fallback) {
  final selectedModel = model;
  return selectedModel == null
      ? fallback
      : prefs?.getDouble("$key:$selectedModel") ?? fallback;
}

int _modelIntPreference(String key, int fallback) {
  final selectedModel = model;
  return selectedModel == null
      ? fallback
      : prefs?.getInt("$key:$selectedModel") ?? fallback;
}

Object activeKeepAlive() {
  if (activeConnectionMode == connectionModeLocal) {
    // While the app is in use, keep the runner resident so changing sampling
    // controls does not trigger a costly model reload. The lifecycle observer
    // explicitly unloads it on background unless the user opted to retain it.
    return -1;
  }
  return "5m";
}

Map<String, dynamic> activeChatOptions({bool? loadVision}) {
  final options = <String, dynamic>{
    "temperature": _modelDoublePreference("chatTemperature",
        prefs?.getDouble("chatTemperature") ?? defaultChatTemperature),
    "top_p": _modelDoublePreference(
        "chatTopP", prefs?.getDouble("chatTopP") ?? defaultChatTopP),
    "top_k": _modelIntPreference(
        "chatTopK", prefs?.getInt("chatTopK") ?? defaultChatTopK),
    "num_predict": _modelIntPreference("chatMaxTokens",
        prefs?.getInt("chatMaxTokens") ?? defaultChatMaxTokens),
    "num_ctx": _modelIntPreference("chatContextTokens",
        prefs?.getInt("chatContextTokens") ?? defaultChatContextTokens),
    "reasoning_budget":
        _modelIntPreference("chatReasoningBudget", defaultChatReasoningBudget),
  };
  final computeOptions = activeComputeOptions();
  if (computeOptions != null) options.addAll(computeOptions.toJson());
  // This extension is only understood by the bundled Android Ollama server.
  // Remote and cloud servers continue receiving the stock Ollama API.
  if (activeConnectionMode == connectionModeLocal && loadVision != null) {
    options["load_vision"] = loadVision;
  }
  return options;
}

String applyMinimumResponseLength(String systemPrompt) {
  final minimum = _modelIntPreference(
      "chatMinResponseTokens", defaultChatMinResponseTokens);
  if (minimum <= 0) return systemPrompt;
  return "$systemPrompt\n\nUnless the user explicitly requests a shorter answer, the final answer should contain at least approximately $minimum tokens. Do not add filler or repeat information merely to reach this target.";
}

Future<bool> unloadLocalModel([String? modelName]) async {
  final target = modelName ?? model;
  if (!Platform.isAndroid ||
      activeConnectionMode != connectionModeLocal ||
      target == null ||
      target.trim().isEmpty) {
    return false;
  }
  try {
    final response = await http
        .post(Uri.parse("$localOllamaHost/api/generate"),
            headers: const {"Content-Type": "application/json"},
            body: jsonEncode({
              "model": target,
              "keep_alive": 0,
            }))
        .timeout(const Duration(seconds: 30));
    return response.statusCode >= 200 && response.statusCode < 300;
  } catch (_) {
    return false;
  }
}

Future<void> unloadAllLocalModels() async {
  if (!Platform.isAndroid || activeConnectionMode != connectionModeLocal) {
    return;
  }
  final loadedNames = <String>{};
  try {
    final response = await http
        .get(Uri.parse("$localOllamaHost/api/ps"))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode >= 200 && response.statusCode < 300) {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded["models"] is List) {
        for (final entry in decoded["models"] as List) {
          if (entry is Map) {
            final name = (entry["name"] ?? entry["model"])?.toString();
            if (name != null && name.trim().isNotEmpty) loadedNames.add(name);
          }
        }
      }
    }
  } catch (_) {}
  if (loadedNames.isEmpty && model?.trim().isNotEmpty == true) {
    loadedNames.add(model!);
  }
  await Future.wait(loadedNames.map(unloadLocalModel));
}

int configuredMaxLoadedModels() => prefs?.getInt("maxLoadedModels") ?? 1;

int maxLoadedModelsServerValue(int configuredValue) =>
    configuredValue < 0 ? unlimitedLoadedModelsValue : configuredValue;

String localServerBindAddress(bool exposeToLan) =>
    exposeToLan ? "0.0.0.0:11434" : "127.0.0.1:11434";

Map<String, dynamic> customModelCreateRequest(
        String modelName, Map<String, String> files) =>
    {
      "model": modelName.trim(),
      "files": files,
      "stream": false,
    };

String configuredRpcServersForCluster() {
  if (!(prefs?.getBool("rpcClusteringEnabled") ?? false)) return "";
  return configuredClusterRpcServers(
    prefs?.getString("rpcServers") ?? "",
    prefs?.getString("rpcWorkerProfiles"),
  );
}

String configuredClusterMultimodalBackend() {
  if (!(prefs?.getBool("rpcClusteringEnabled") ?? false) ||
      !(prefs?.getBool("clusterMultimodalDivision") ?? false)) {
    return "";
  }
  final target = prefs?.getString("clusterMultimodalTarget") ?? "host";
  if (target == "host") {
    return prefs?.getString("clusterHostMultimodalDevice") ?? "LOCAL_GPU";
  }
  return configuredRemoteMultimodalBackend(
        enabledEndpoints: configuredRpcServersForCluster(),
        encodedProfiles: prefs?.getString("rpcWorkerProfiles"),
        target: target,
      ) ??
      "";
}

bool clusterHostEntityEnabled(String entity) {
  if (!(prefs?.getBool("rpcClusteringEnabled") ?? false) ||
      !(prefs?.getBool("clusterMultimodalDivision") ?? false)) {
    return true;
  }
  final selected = prefs?.getStringList("clusterHostEntities");
  return selected == null || selected.contains(entity);
}

ClusterWorkerProfile? activeClusterRemoteMediaWorker(String entity) {
  if (!(prefs?.getBool('rpcClusteringEnabled') ?? false) ||
      !(prefs?.getBool('clusterMultimodalDivision') ?? false)) {
    return null;
  }
  final target = prefs?.getString('clusterMultimodalTarget') ?? 'host';
  if (target.isEmpty || target == 'host') return null;
  final profiles =
      decodeClusterWorkerProfiles(prefs?.getString('rpcWorkerProfiles'));
  final profile = profiles[target];
  if (profile == null ||
      !profile.remoteMediaAvailable ||
      !profile.advertisedEntities.contains(entity) ||
      !profile.enabledEntities.contains(entity)) {
    return null;
  }
  return profile;
}

bool clusterCaptureEntityEnabled(String entity) {
  if (!(prefs?.getBool('rpcClusteringEnabled') ?? false) ||
      !(prefs?.getBool('clusterMultimodalDivision') ?? false)) {
    return true;
  }
  final target = prefs?.getString('clusterMultimodalTarget') ?? 'host';
  if (target.isEmpty || target == 'host') {
    return clusterHostEntityEnabled(entity);
  }
  return activeClusterRemoteMediaWorker(entity) != null;
}

Future<bool> startConfiguredLocalServer() => ServerController.startServer(
    maxLoadedModels: maxLoadedModelsServerValue(configuredMaxLoadedModels()),
    exposeToLan: prefs?.getBool("exposeLocalServerToLan") ?? false,
    computeMode: configuredComputeMode(),
    forcedDevice: configuredForcedDevice(),
    rpcServers: configuredRpcServersForCluster(),
    multimodalBackendDevice: configuredClusterMultimodalBackend(),
    synergyCpuPercent: prefs?.getInt("synergyCpuPercent") ??
        (100 - (prefs?.getInt("synergyGpuPercent") ?? 50)),
    synergyGpuPercent: prefs?.getInt("synergyGpuPercent") ?? 50,
    synergyNpuPercent: prefs?.getBool("synergyNpuEnabled") ?? false
        ? (prefs?.getInt("synergyNpuPercent") ?? 0)
        : 0);

Map<String, dynamic> activeChatRequest(List<llama.Message> history, bool stream,
    {bool? thinkingOverride}) {
  final hasImages =
      history.any((message) => message.images?.isNotEmpty == true);
  return {
    "model": model,
    "messages": history.map((message) => message.toJson()).toList(),
    "stream": stream,
    "think": thinkingOverride ?? activeThinkingEnabled(),
    "keep_alive": activeKeepAlive(),
    "options": activeChatOptions(loadVision: hasImages),
  };
}

Stream<Map<String, dynamic>> generateChatStreamRaw(List<llama.Message> history,
    {bool? thinkingOverride}) async* {
  final client = http.Client();
  cancelActiveChatRequest();
  activeChatHttpClient = client;
  try {
    final request = http.Request("POST", Uri.parse("$host/api/chat"));
    request.headers.addAll({
      ...activeHostHeaders(),
      "Content-Type": "application/json",
    });
    request.body = jsonEncode(
        activeChatRequest(history, true, thinkingOverride: thinkingOverride));
    final response =
        await client.send(request).timeout(activeInferenceTimeout());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = await response.stream.bytesToString();
      throw HttpException("HTTP ${response.statusCode}: $body");
    }
    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .timeout(activeInferenceTimeout())) {
      if (line.trim().isEmpty) continue;
      final decoded = jsonDecode(line);
      if (decoded is! Map) continue;
      final chunk =
          decoded.map((key, value) => MapEntry(key.toString(), value));
      if (chunk["error"] != null) {
        throw HttpException(chunk["error"].toString());
      }
      yield chunk;
    }
  } finally {
    if (identical(activeChatHttpClient, client)) {
      activeChatHttpClient = null;
    }
    client.close();
  }
}

Future<Map<String, dynamic>> generateChatRaw(List<llama.Message> history,
    {bool? thinkingOverride}) async {
  final client = http.Client();
  cancelActiveChatRequest();
  activeChatHttpClient = client;
  try {
    final response = await client
        .post(Uri.parse("$host/api/chat"),
            headers: {
              ...activeHostHeaders(),
              "Content-Type": "application/json",
            },
            body: jsonEncode(activeChatRequest(history, false,
                thinkingOverride: thinkingOverride)))
        .timeout(activeInferenceTimeout());
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException("HTTP ${response.statusCode}: ${response.body}");
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const FormatException("Invalid Ollama response");
    }
    final result = decoded.map((key, value) => MapEntry(key.toString(), value));
    if (result["error"] != null) {
      throw HttpException(result["error"].toString());
    }
    return result;
  } finally {
    if (identical(activeChatHttpClient, client)) {
      activeChatHttpClient = null;
    }
    client.close();
  }
}

String? configuredHost() {
  switch (activeConnectionMode) {
    case connectionModeLocal:
      return localOllamaHost;
    case connectionModeCloud:
      return ollamaCloudHost;
    default:
      return prefs?.getString("externalHost") ?? prefs?.getString("host");
  }
}

String normalizedConnectionMode(
  String? savedMode, {
  required bool isAndroid,
  required bool legacyLocalServer,
  String? savedHost,
  String? externalHost,
}) {
  var mode = (savedMode == connectionModeLocal ||
          savedMode == connectionModeExternal ||
          savedMode == connectionModeCloud)
      ? savedMode!
      : (legacyLocalServer && isAndroid)
          ? connectionModeLocal
          : connectionModeExternal;
  if (mode == connectionModeLocal && !isAndroid) {
    mode = connectionModeExternal;
  }
  if (isAndroid &&
      mode == connectionModeExternal &&
      externalHost == null &&
      savedHost == localOllamaHost) {
    mode = connectionModeLocal;
  }
  return mode;
}

void applyRuntimePreferences(SharedPreferences loadedPreferences) {
  prefs = loadedPreferences;
  model = useModel ? fixedModel : loadedPreferences.getString("model");
  selectedModelCapabilities =
      (loadedPreferences.getStringList("modelCapabilities") ?? const <String>[])
          .map((capability) => capability.toLowerCase())
          .toSet();
  attachmentOverride = model != null &&
      (loadedPreferences.getBool("attachmentOverride:$model") ?? false);
  multimodal = hasModelAttachmentCapabilities(selectedModelCapabilities);
  host = useHost ? fixedHost : configuredHost();
}

Locale? configuredInterfaceLocale() {
  final language = prefs?.getString("interfaceLanguage") ?? "system";
  return switch (language) {
    "en" => const Locale("en"),
    "es" => const Locale("es"),
    _ => null,
  };
}

String effectiveInterfaceLanguage() {
  final configured = prefs?.getString("interfaceLanguage") ?? "system";
  return resolvedInterfaceLanguage(
      configured, ui.PlatformDispatcher.instance.locales);
}

String resolvedInterfaceLanguage(
    String? configured, Iterable<Locale> deviceLocales) {
  if (configured == "es" || configured == "en") return configured!;
  final language = deviceLocales.isEmpty
      ? "en"
      : deviceLocales.first.languageCode.toLowerCase();
  return language == "es" ? "es" : "en";
}

String appText(String english, String spanish) =>
    effectiveInterfaceLanguage() == "es" ? spanish : english;

void configureAppThemes(SharedPreferences loadedPreferences, int? systemSeed) {
  final followsSystem =
      (loadedPreferences.getString("brightness") ?? "system") == "system";
  if (followsSystem) {
    final seed = Color((systemSeed ?? 0xff6750a4) & 0xffffffff);
    theme = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.light,
      ),
    );
    themeDark = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: seed,
        brightness: Brightness.dark,
      ),
    );
    return;
  }
  theme = ThemeData.from(
    useMaterial3: true,
    colorScheme: const ColorScheme(
      brightness: Brightness.light,
      primary: Colors.black,
      onPrimary: Colors.white,
      secondary: Colors.white,
      onSecondary: Colors.black,
      error: Colors.red,
      onError: Colors.white,
      surface: Colors.white,
      onSurface: Colors.black,
    ),
  );
  themeDark = ThemeData.from(
    useMaterial3: true,
    colorScheme: const ColorScheme(
      brightness: Brightness.dark,
      primary: Colors.white,
      onPrimary: Colors.black,
      secondary: Colors.black,
      onSecondary: Colors.white,
      error: Colors.red,
      onError: Colors.black,
      surface: Colors.black,
      onSurface: Colors.white,
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  ServerController.setAssistantEventHandler((method, arguments) async {
    final handler = activeAssistantVoicePlatformEventHandler;
    if (handler != null) await handler(method, arguments);
  });
  runApp(const App());

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    doWhenWindowReady(() {
      appWindow.minSize = const Size(600, 450);
      appWindow.size = const Size(1200, 650);
      appWindow.alignment = Alignment.center;
      appWindow.show();
    });
  }
}

class App extends StatefulWidget {
  const App({super.key});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  @override
  void initState() {
    super.initState();

    void load() async {
      try {
        await FlutterDisplayMode.setHighRefreshRate();
      } catch (_) {}
      SharedPreferences.setPrefix("ollama.");
      SharedPreferences tmp = await SharedPreferences.getInstance();
      final savedMode = tmp.getString("connectionMode");
      final migratedMode = normalizedConnectionMode(
        savedMode,
        isAndroid: Platform.isAndroid,
        legacyLocalServer: tmp.getBool("localServer") ?? false,
        savedHost: tmp.getString("host"),
        externalHost: tmp.getString("externalHost"),
      );
      String? storedCloudApiKey;
      try {
        storedCloudApiKey = await secureStorage.read(
          key: cloudApiKeyStorageKey,
        );
      } catch (_) {}

      activeConnectionMode = useHost ? connectionModeExternal : migratedMode;
      cloudApiKey = storedCloudApiKey;
      await tmp.setString("connectionMode", activeConnectionMode);

      final previousHost = tmp.getString("host");
      if (tmp.getString("externalHost") == null &&
          previousHost != null &&
          previousHost != localOllamaHost &&
          previousHost != ollamaCloudHost) {
        await tmp.setString("externalHost", previousHost);
      }

      applyRuntimePreferences(tmp);
      final systemSeed = Platform.isAndroid
          ? await ServerController.getSystemThemeSeed()
          : null;
      configureAppThemes(tmp, systemSeed);
      if (activeConnectionMode == connectionModeLocal && Platform.isAndroid) {
        await startConfiguredLocalServer();
      }
      if (!mounted) return;
      setState(() {});
    }

    load();
  }

  @override
  Widget build(BuildContext context) {
    final assistantOverlay =
        WidgetsBinding.instance.platformDispatcher.defaultRouteName ==
            "/assistant-overlay";
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: const [Locale("en"), Locale("es")],
      locale: configuredInterfaceLocale(),
      localeListResolutionCallback: (deviceLocales, supportedLocales) {
        return Locale(resolvedInterfaceLanguage(
            "system", deviceLocales ?? const <Locale>[]));
      },
      title: "Ollama",
      theme: theme ?? ThemeData(useMaterial3: true),
      darkTheme: themeDark ??
          ThemeData(brightness: Brightness.dark, useMaterial3: true),
      themeMode: ((prefs?.getString("brightness") ?? "system") == "system")
          ? ThemeMode.system
          : ((prefs!.getString("brightness") == "dark")
              ? ThemeMode.dark
              : ThemeMode.light),
      home: assistantOverlay
          ? const ScreenAssistantVoice(compact: true)
          : const MainApp(),
    );
  }
}

class MainApp extends StatefulWidget {
  const MainApp({super.key});

  @override
  State<MainApp> createState() => _MainAppState();
}

enum _GenerationCancelReason { user, forceAnswer }

class _TelescopeIcon extends StatelessWidget {
  const _TelescopeIcon({this.size = 24});

  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _TelescopeIconPainter(
          IconTheme.of(context).color ??
              Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
}

class _TelescopeIconPainter extends CustomPainter {
  const _TelescopeIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.translate(2.5, 7.5);
    canvas.rotate(-0.32);
    canvas.drawRRect(
        RRect.fromRectAndRadius(
            const Rect.fromLTWH(3, 0, 14.5, 7), const Radius.circular(1.5)),
        paint);
    canvas.drawLine(const Offset(17.5, -1), const Offset(17.5, 8), paint);
    canvas.drawLine(const Offset(1, 2), const Offset(3, 2), paint);
    canvas.drawLine(const Offset(1, 5), const Offset(3, 5), paint);
    canvas.restore();
    canvas.drawCircle(const Offset(12, 14), 1.5, paint);
    canvas.drawLine(const Offset(12, 15.5), const Offset(6.5, 22), paint);
    canvas.drawLine(const Offset(12, 15.5), const Offset(17.5, 22), paint);
    canvas.drawLine(const Offset(12, 15.5), const Offset(12, 22), paint);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TelescopeIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

class ThinkingMessageCard extends StatelessWidget {
  const ThinkingMessageCard(
      {super.key, required this.message, required this.messageWidth});

  final types.CustomMessage message;
  final int messageWidth;

  @override
  Widget build(BuildContext context) {
    final metadata = message.metadata ?? const <String, dynamic>{};
    final thinking = (metadata["thinking"] ?? "").toString();
    final isThinking = metadata["isThinking"] == true;
    final muted = Theme.of(context).colorScheme.onSurface.withAlpha(145);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: messageWidth.toDouble()),
      child: ExpansionTile(
        key: ValueKey("thinking-toggle-${message.id}"),
        leading: isThinking
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : Icon(Icons.psychology_alt_rounded, color: muted),
        title: Text(
            isThinking
                ? appText("Thinking", "Pensando")
                : appText("Reasoning", "Razonamiento"),
            style: TextStyle(color: muted)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                thinking.isEmpty ? "Esperando razonamiento…" : thinking,
                style: TextStyle(color: muted, height: 1.35),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MainAppState extends State<MainApp> with WidgetsBindingObserver {
  bool logoVisible = true;
  bool menuVisible = false;

  int tipId = Random().nextInt(5);
  bool sendable = false;
  bool _groundNextPrompt = false;
  bool _deepExploreNextPrompt = false;
  String? _activeChatTool;
  final ScrollController _chatActivityScrollController = ScrollController();
  _GenerationCancelReason? _generationCancelReason;
  bool _backgroundUnloadStarted = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _backgroundUnloadStarted = false;
      return;
    }
    if (state != AppLifecycleState.hidden &&
        state != AppLifecycleState.paused) {
      return;
    }
    if (_backgroundUnloadStarted || keepModelsLoadedInBackground()) return;
    _backgroundUnloadStarted = true;
    unawaited(unloadAllLocalModels());
  }

  bool get _modelIsThinking => messages.any((message) =>
      message is types.CustomMessage &&
      message.metadata?["kind"] == "thinking" &&
      message.metadata?["isThinking"] == true);

  void _stopGeneration() {
    if (chatAllowed) return;
    _generationCancelReason = _GenerationCancelReason.user;
    HapticFeedback.mediumImpact();
    cancelActiveChatRequest();
  }

  void _forceAnswer() {
    if (chatAllowed || !_modelIsThinking) return;
    _generationCancelReason = _GenerationCancelReason.forceAnswer;
    HapticFeedback.mediumImpact();
    cancelActiveChatRequest();
  }

  Future<void> _showChatControls() async {
    final selectedModel = model;
    if (selectedModel == null || prefs == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(appText(
                "Select a model first", "Selecciona primero un modelo"))),
      );
      return;
    }
    var temperature = _modelDoublePreference("chatTemperature",
        prefs?.getDouble("chatTemperature") ?? defaultChatTemperature);
    var topP = _modelDoublePreference(
        "chatTopP", prefs?.getDouble("chatTopP") ?? defaultChatTopP);
    var topK = _modelIntPreference(
        "chatTopK", prefs?.getInt("chatTopK") ?? defaultChatTopK);
    var maxTokens = _modelIntPreference("chatMaxTokens",
        prefs?.getInt("chatMaxTokens") ?? defaultChatMaxTokens);
    var contextTokens = _modelIntPreference("chatContextTokens",
        prefs?.getInt("chatContextTokens") ?? defaultChatContextTokens);
    var minResponseTokens = _modelIntPreference(
        "chatMinResponseTokens", defaultChatMinResponseTokens);
    var reasoningBudget =
        _modelIntPreference("chatReasoningBudget", defaultChatReasoningBudget);
    var thinking = activeThinkingEnabled();
    final detected =
        (prefs?.getStringList(_detectedModelCapabilitiesKey(selectedModel)) ??
                selectedModelCapabilities.toList())
            .map((capability) => capability.toLowerCase())
            .toSet();
    final capabilities = Set<String>.from(selectedModelCapabilities);
    var useDetected =
        !prefs!.containsKey(_modelCapabilitiesOverrideKey(selectedModel));
    final maxTokensController =
        TextEditingController(text: maxTokens.toString());
    final contextController =
        TextEditingController(text: contextTokens.toString());
    final topKController = TextEditingController(text: topK.toString());
    final minResponseController =
        TextEditingController(text: minResponseTokens.toString());
    final reasoningBudgetController =
        TextEditingController(text: reasoningBudget.toString());

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.9,
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.tune_rounded),
                  title: Text(appText("Settings for $selectedModel",
                      "Ajustes de $selectedModel")),
                  subtitle: Text(appText(
                      "Generation parameters and model capabilities",
                      "Parámetros de generación y capacidades del modelo")),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      Text(appText("Generation", "Generación"),
                          style: Theme.of(sheetContext).textTheme.titleMedium),
                      SwitchListTile(
                        key: const ValueKey("model-settings-thinking"),
                        contentPadding: EdgeInsets.zero,
                        secondary: const Icon(Icons.psychology_alt_rounded),
                        title: Text(appText("Reasoning", "Razonamiento")),
                        subtitle: Text(appText(
                            "Request separate thinking blocks before answering.",
                            "Solicita bloques de pensamiento separados antes de responder.")),
                        value: thinking,
                        onChanged: (value) =>
                            setSheetState(() => thinking = value),
                      ),
                      Text("Temperatura · ${temperature.toStringAsFixed(2)}"),
                      Slider(
                        key: const ValueKey("model-settings-temperature"),
                        min: 0,
                        max: 2,
                        divisions: 40,
                        value: temperature.clamp(0.0, 2.0).toDouble(),
                        label: temperature.toStringAsFixed(2),
                        onChanged: (value) =>
                            setSheetState(() => temperature = value),
                      ),
                      Text("Top P · ${topP.toStringAsFixed(2)}"),
                      Slider(
                        key: const ValueKey("model-settings-top-p"),
                        min: 0.05,
                        max: 1,
                        divisions: 19,
                        value: topP.clamp(0.05, 1.0).toDouble(),
                        label: topP.toStringAsFixed(2),
                        onChanged: (value) => setSheetState(() => topP = value),
                      ),
                      Row(children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey("model-settings-context"),
                            controller: contextController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: appText(
                                  "Context (tokens)", "Contexto (tokens)"),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            key: const ValueKey("model-settings-max-tokens"),
                            controller: maxTokensController,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText:
                                  appText("Maximum output", "Máximo de salida"),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Row(children: [
                        Expanded(
                          child: TextField(
                            key: const ValueKey("model-settings-min-response"),
                            controller: minResponseController,
                            keyboardType:
                                const TextInputType.numberWithOptions(),
                            decoration: InputDecoration(
                              labelText: appText("Minimum response length",
                                  "Extensión mínima"),
                              helperText: appText(
                                  "Approximate tokens; 0 disables the minimum.",
                                  "Tokens orientativos; 0 desactiva el mínimo."),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            key: const ValueKey(
                                "model-settings-reasoning-budget"),
                            controller: reasoningBudgetController,
                            keyboardType: const TextInputType.numberWithOptions(
                                signed: true),
                            decoration: InputDecoration(
                              labelText: appText("Maximum reasoning tokens",
                                  "Máximo de razonamiento"),
                              helperText: appText(
                                  "Tokens: -1 unlimited, 0 immediate. Older servers may ignore it.",
                                  "Tokens: -1 ilimitado, 0 inmediato. Servidores antiguos pueden ignorarlo."),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      TextField(
                        key: const ValueKey("model-settings-top-k"),
                        controller: topKController,
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: "Top K",
                          helperText: appText(
                              "0 disables the limit; common value: 40.",
                              "0 desactiva el límite; valor habitual: 40."),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const Divider(height: 32),
                      Row(children: [
                        Expanded(
                          child: Text(
                              appText("Multimodal capabilities",
                                  "Capacidades multimodales"),
                              style:
                                  Theme.of(sheetContext).textTheme.titleMedium),
                        ),
                        TextButton.icon(
                          onPressed: () {
                            useDetected = true;
                            capabilities
                              ..clear()
                              ..addAll(detected);
                            setSheetState(() {});
                          },
                          icon: const Icon(Icons.auto_fix_high_rounded),
                          label: Text(appText("Detected", "Detectadas")),
                        ),
                      ]),
                      Text(appText(
                          "These controls change how the app treats the model; they do not alter its weights.",
                          "Estos controles cambian cómo la app trata al modelo; no alteran sus pesos.")),
                      ...configurableModelCapabilities.entries
                          .where((entry) =>
                              entry.key != "audio" ||
                              (prefs?.getBool("enableEmbeddedAudioModels") ??
                                  false))
                          .map((entry) => SwitchListTile(
                                key: ValueKey("model-capability-${entry.key}"),
                                contentPadding: EdgeInsets.zero,
                                title: Text(entry.value),
                                subtitle: Text(
                                    modelCapabilityDescriptions[entry.key] ??
                                        entry.key),
                                value: capabilities.contains(entry.key),
                                onChanged: (value) {
                                  useDetected = false;
                                  value
                                      ? capabilities.add(entry.key)
                                      : capabilities.remove(entry.key);
                                  setSheetState(() {});
                                },
                              )),
                      Text(
                        useDetected
                            ? appText(
                                "Using capabilities detected by the server",
                                "Usando las capacidades detectadas por el servidor")
                            : appText(
                                "Using a manual configuration for this model",
                                "Usando una configuración manual para este modelo"),
                        style: TextStyle(
                            color: Theme.of(sheetContext)
                                .colorScheme
                                .onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(sheetContext),
                        child: Text(appText("Cancel", "Cancelar")),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        key: const ValueKey("model-settings-save"),
                        onPressed: () async {
                          contextTokens =
                              int.tryParse(contextController.text.trim()) ?? 0;
                          maxTokens =
                              int.tryParse(maxTokensController.text.trim()) ??
                                  0;
                          topK = int.tryParse(topKController.text.trim()) ?? -1;
                          minResponseTokens =
                              int.tryParse(minResponseController.text.trim()) ??
                                  -1;
                          reasoningBudget = int.tryParse(
                                  reasoningBudgetController.text.trim()) ??
                              -2;
                          if (contextTokens < 128 ||
                              maxTokens < 1 ||
                              topK < 0 ||
                              minResponseTokens < 0 ||
                              minResponseTokens > maxTokens ||
                              reasoningBudget < -1) {
                            ScaffoldMessenger.of(sheetContext).showSnackBar(
                              SnackBar(
                                content: Text(appText(
                                    "Check context, output, minimum length, reasoning and Top K. The minimum cannot exceed the maximum.",
                                    "Revisa contexto, salida, mínimo, razonamiento y Top K. El mínimo no puede superar el máximo.")),
                              ),
                            );
                            return;
                          }
                          await prefs?.setDouble(
                              "chatTemperature:$selectedModel", temperature);
                          await prefs?.setDouble(
                              "chatTopP:$selectedModel", topP);
                          await prefs?.setInt("chatTopK:$selectedModel", topK);
                          await prefs?.setInt(
                              "chatMaxTokens:$selectedModel", maxTokens);
                          await prefs?.setInt(
                              "chatContextTokens:$selectedModel",
                              contextTokens);
                          await prefs?.setInt(
                              "chatMinResponseTokens:$selectedModel",
                              minResponseTokens);
                          await prefs?.setInt(
                              "chatReasoningBudget:$selectedModel",
                              reasoningBudget);
                          await prefs?.setBool(
                              "thinkingEnabled:$selectedModel", thinking);
                          if (useDetected) {
                            await prefs?.remove(
                                _modelCapabilitiesOverrideKey(selectedModel));
                          } else {
                            await prefs?.setStringList(
                                _modelCapabilitiesOverrideKey(selectedModel),
                                capabilities.toList()..sort());
                          }
                          selectedModelCapabilities =
                              Set<String>.from(capabilities);
                          attachmentOverride = prefs?.getBool(
                                  "attachmentOverride:$selectedModel") ??
                              false;
                          multimodal =
                              hasModelAttachmentCapabilities(capabilities);
                          await prefs?.setStringList("modelCapabilities",
                              capabilities.toList()..sort());
                          await prefs?.setBool("multimodal", multimodal);
                          if (sheetContext.mounted) {
                            Navigator.pop(sheetContext);
                          }
                        },
                        icon: const Icon(Icons.save_rounded),
                        label: Text(appText("Save", "Guardar")),
                      ),
                    ),
                  ]),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    maxTokensController.dispose();
    contextController.dispose();
    topKController.dispose();
    minResponseController.dispose();
    reasoningBudgetController.dispose();
    if (mounted) setState(() {});
  }

  bool get _attachmentsDetected =>
      hasModelAttachmentCapabilities(selectedModelCapabilities);

  bool get _chatActionMenuDetected =>
      _attachmentsDetected || selectedModelCapabilities.contains("tools");

  IconData get _chatActionIcon =>
      chatActionIconForCapabilities(selectedModelCapabilities);

  bool get _visualAttachmentsEnabled =>
      selectedModelCapabilities.contains("vision");

  bool _isPendingAttachment(types.Message message) =>
      isDirectMediaAttachment(message) ||
      message.metadata?["attachmentName"]?.toString().isNotEmpty == true;

  List<types.Message> get _pendingAttachments {
    final pending = <types.Message>[];
    for (final message in messages) {
      if (!_isPendingAttachment(message)) break;
      pending.add(message);
    }
    return pending;
  }

  String _pendingAttachmentName(types.Message message) {
    final metadataName = message.metadata?["attachmentName"]?.toString();
    if (metadataName?.isNotEmpty == true) return metadataName!;
    if (message is types.ImageMessage) return message.name;
    if (message is types.FileMessage) return message.name;
    return "Archivo adjunto";
  }

  List<String> _attachmentImages(types.Message message) {
    final encoded = message.metadata?["attachmentImages"];
    if (encoded is List) {
      return encoded
          .map((value) => value.toString())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
    }
    return const <String>[];
  }

  RagDocument? _attachmentDocument(types.Message message) {
    final content = message.metadata?["attachmentContent"]?.toString().trim();
    if (content == null || content.isEmpty) return null;
    return RagDocument(name: _pendingAttachmentName(message), text: content);
  }

  Widget _buildChatActivityBar() {
    final pending = _pendingAttachments;
    final selectedGrounding = _groundNextPrompt && !_deepExploreNextPrompt;
    final selectedExploration = _groundNextPrompt && _deepExploreNextPrompt;
    if (pending.isEmpty &&
        !selectedGrounding &&
        !selectedExploration &&
        _activeChatTool == null) {
      return const SizedBox.shrink();
    }
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: 58,
        child: Scrollbar(
          controller: _chatActivityScrollController,
          thumbVisibility: pending.length > 2,
          interactive: true,
          scrollbarOrientation: ScrollbarOrientation.bottom,
          child: ListView(
            key: const ValueKey("chat-activity-bar"),
            controller: _chatActivityScrollController,
            primary: false,
            physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics()),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            children: [
              if (selectedGrounding) ...[
                InputChip(
                  key: const ValueKey("chat-grounding-toggle"),
                  avatar: const Icon(Icons.public_rounded, size: 18),
                  label: Text(appText("Grounding", "Fundamentación")),
                  onDeleted: chatAllowed
                      ? () => setState(() {
                            _groundNextPrompt = false;
                            _deepExploreNextPrompt = false;
                          })
                      : null,
                ),
                const SizedBox(width: 8),
              ],
              if (selectedExploration) ...[
                InputChip(
                  key: const ValueKey("chat-deep-exploration-toggle"),
                  avatar: const _TelescopeIcon(size: 18),
                  label:
                      Text(appText("Deep Exploration", "Exploración profunda")),
                  onDeleted: chatAllowed
                      ? () => setState(() {
                            _groundNextPrompt = false;
                            _deepExploreNextPrompt = false;
                          })
                      : null,
                ),
                const SizedBox(width: 8),
              ],
              if (_activeChatTool != null) ...[
                Chip(
                  key: const ValueKey("chat-active-tool"),
                  avatar: const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  label: Text(_activeChatTool!),
                ),
                const SizedBox(width: 8),
              ],
              ...pending.map((message) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: InputChip(
                      key: ValueKey("pending-attachment-${message.id}"),
                      avatar: const Icon(Icons.upload_file_rounded, size: 18),
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          _pendingAttachmentName(message),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      onDeleted: chatAllowed
                          ? () => setState(() => messages
                              .removeWhere((item) => item.id == message.id))
                          : null,
                    ),
                  )),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _addImageBytes(
      Uint8List bytes, String name, String mimeType) async {
    final image = await decodeImageFromList(bytes);
    messages.insert(
      0,
      types.ImageMessage(
        author: user,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        height: image.height.toDouble(),
        id: const Uuid().v4(),
        name: name,
        size: bytes.length,
        uri: "data:$mimeType;base64,${base64.encode(bytes)}",
        width: image.width.toDouble(),
      ),
    );
    if (mounted) setState(() {});
    HapticFeedback.selectionClick();
  }

  Future<void> _addImage(XFile picked) async {
    final extension = picked.name.split('.').last.toLowerCase();
    final mimeType = switch (extension) {
      "png" => "image/png",
      "gif" => "image/gif",
      "webp" => "image/webp",
      _ => "image/jpeg",
    };
    await _addImageBytes(await picked.readAsBytes(), picked.name, mimeType);
  }

  Future<void> _pickImage(ImageSource source) async {
    if (source == ImageSource.camera) {
      final rear = activeClusterRemoteMediaWorker(clusterEntityCameraRear);
      final front = activeClusterRemoteMediaWorker(clusterEntityCameraFront);
      final remote = rear ?? front;
      if (remote != null) {
        final bytes = await const ClusterRemoteMediaClient()
            .captureCamera(remote, front: rear == null);
        await _addImageBytes(
          bytes,
          '${remote.name ?? 'cluster-worker'}-${DateTime.now().millisecondsSinceEpoch}.jpg',
          'image/jpeg',
        );
        return;
      }
    }
    final picked = await ImagePicker().pickImage(source: source);
    if (picked != null) await _addImage(picked);
  }

  Future<({Uint8List bytes, String name, String mimeType})> _rasterizeSvg(
      PlatformFile selected, Uint8List source) async {
    final baseName =
        selected.name.replaceFirst(RegExp(r'\.svg$', caseSensitive: false), '');
    return (
      bytes: await convertSvgToPng(source),
      name: "$baseName.png",
      mimeType: "image/png",
    );
  }

  Future<void> _pickSupportedImageFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedImageExtensions,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final selected = result.files.first;
    final bytes = selected.bytes ??
        (selected.path == null
            ? null
            : await File(selected.path!).readAsBytes());
    if (bytes == null) return;
    if (bytes.length > 25 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(appText("Images are limited to 25 MB.",
              "Las imágenes están limitadas a 25 MB.")),
          showCloseIcon: true,
        ));
      }
      return;
    }
    try {
      final extension = selected.extension?.toLowerCase() ?? "";
      if (extension == "svg") {
        final converted = await _rasterizeSvg(selected, bytes);
        await _addImageBytes(
            converted.bytes, converted.name, converted.mimeType);
        return;
      }
      final mimeType = switch (extension) {
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        _ => "image/jpeg",
      };
      await _addImageBytes(bytes, selected.name, mimeType);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(appText("Could not attach image: $error",
              "No se pudo adjuntar la imagen: $error")),
          showCloseIcon: true,
        ));
      }
    }
  }

  Future<void> _pickTextFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const [
        "txt",
        "md",
        "json",
        "csv",
        "tsv",
        "yaml",
        "yml",
        "xml",
        "html",
        "css",
        "js",
        "ts",
        "dart",
        "py",
        "java",
        "kt",
        "c",
        "cpp",
        "h",
        "go",
        "rs",
        "sh",
        "log",
      ],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final selected = result.files.first;
    final bytes = selected.bytes ??
        (selected.path == null
            ? null
            : await File(selected.path!).readAsBytes());
    if (bytes == null) return;
    final content = utf8.decode(bytes, allowMalformed: true);
    messages.insert(
      0,
      types.TextMessage(
        author: user,
        id: const Uuid().v4(),
        text: "Attached file: ${selected.name}",
        metadata: {
          "attachmentName": selected.name,
          "attachmentKind": "text",
          "attachmentContent": content,
        },
      ),
    );
    if (mounted) setState(() {});
    HapticFeedback.selectionClick();
  }

  Future<void> _pickAudioFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedAudioExtensions,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final selected = result.files.first;
    final bytes = selected.bytes ??
        (selected.path == null
            ? null
            : await File(selected.path!).readAsBytes());
    if (bytes == null) return;
    if (bytes.length > 25 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(appText(
              "Audio is limited to 25 MB.", "El audio está limitado a 25 MB.")),
          showCloseIcon: true,
        ));
      }
      return;
    }
    final extension = selected.extension?.toLowerCase() ?? "wav";
    final mime = switch (extension) {
      "mp3" => "audio/mpeg",
      _ => "audio/wav",
    };
    messages.insert(
      0,
      types.FileMessage(
        author: user,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        id: const Uuid().v4(),
        mimeType: mime,
        name: selected.name,
        size: bytes.length,
        uri: "data:$mime;base64,${base64.encode(bytes)}",
        metadata: const {"attachmentKind": "audio"},
      ),
    );
    if (mounted) setState(() {});
    HapticFeedback.selectionClick();
  }

  Future<void> _pickDocument() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedDocumentExtensions,
      withData: !Platform.isAndroid,
    );
    if (result == null || result.files.isEmpty) return;
    final selected = result.files.first;
    final extension = selected.extension?.toLowerCase() ?? "";
    if (extension == "pdf") {
      await _attachPdf(selected);
      return;
    }
    if (selected.size > 150 * 1024 * 1024) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(appText("Documents are limited to 150 MB.",
              "Los documentos están limitados a 150 MB.")),
          showCloseIcon: true,
        ));
      }
      return;
    }
    String text;
    if (Platform.isAndroid && selected.path != null) {
      final processed = await ServerController.processDocument(selected.path!);
      final error = processed["error"]?.toString();
      if (error != null && error.isNotEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(appText("Could not read the document: $error",
                "No se pudo leer el documento: $error")),
            showCloseIcon: true,
          ));
        }
        return;
      }
      text = processed["text"]?.toString().trim() ?? "";
    } else {
      final bytes = selected.bytes ??
          (selected.path == null
              ? null
              : await File(selected.path!).readAsBytes());
      text = bytes == null ? "" : utf8.decode(bytes, allowMalformed: true);
    }
    if (text.trim().isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(appText("The document contains no extractable text.",
              "El documento no contiene texto extraíble.")),
          showCloseIcon: true,
        ));
      }
      return;
    }
    messages.insert(
      0,
      types.TextMessage(
        author: user,
        id: const Uuid().v4(),
        text: "Attached document: ${selected.name}",
        metadata: {
          "attachmentName": selected.name,
          "attachmentKind": "document",
          "attachmentContent": text,
        },
      ),
    );
    if (mounted) setState(() {});
    HapticFeedback.selectionClick();
  }

  Future<void> _attachPdf(PlatformFile selected) async {
    if (!Platform.isAndroid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(appText("PDF processing is available on Android.",
              "El procesamiento PDF está disponible en Android.")),
          showCloseIcon: true,
        ));
      }
      return;
    }
    if (selected.path == null) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            appText("Processing PDF locally…", "Procesando PDF localmente…")),
        duration: const Duration(seconds: 2),
      ));
    }
    final renderPages = _visualAttachmentsEnabled;
    final processed = await ServerController.processPdf(selected.path!,
        renderPages: renderPages, maxPages: 6);
    final error = processed["error"]?.toString();
    if (error != null && error.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(appText("Could not read the PDF: $error",
              "No se pudo leer el PDF: $error")),
          showCloseIcon: true,
        ));
      }
      return;
    }
    final pageCount = (processed["pageCount"] as num?)?.toInt() ?? 0;
    final images = (processed["images"] as List?)
            ?.map((value) => value.toString())
            .where((value) => value.isNotEmpty)
            .toList() ??
        <String>[];
    final text = processed["text"]?.toString().trim() ?? "";
    if (text.isEmpty && images.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              "El PDF no contiene texto extraíble. Activa la capacidad de visión para enviarlo como imágenes."),
          showCloseIcon: true,
        ));
      }
      return;
    }
    messages.insert(
      0,
      types.TextMessage(
        author: user,
        id: const Uuid().v4(),
        text: "Attached PDF: ${selected.name} · $pageCount pages",
        metadata: {
          "attachmentName": selected.name,
          "attachmentKind": "pdf",
          "attachmentContent": text,
          "attachmentImages": images,
          "attachmentPageCount": pageCount,
        },
      ),
    );
    if (mounted && pageCount > images.length && images.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            "Se usarán visualmente las primeras ${images.length} de $pageCount páginas y el texto extraído del documento completo."),
        showCloseIcon: true,
      ));
    }
    if (mounted) setState(() {});
    HapticFeedback.selectionClick();
  }

  Future<void> _pickVideo(ImageSource source) async {
    if (!Platform.isAndroid) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "Video frame extraction is currently available on Android.",
            ),
            showCloseIcon: true,
          ),
        );
      }
      return;
    }
    if (source == ImageSource.camera) {
      final rear = activeClusterRemoteMediaWorker(clusterEntityCameraRear);
      final front = activeClusterRemoteMediaWorker(clusterEntityCameraFront);
      final remote = rear ?? front;
      if (remote != null) {
        for (var index = 0; index < 3; index++) {
          final bytes = await const ClusterRemoteMediaClient()
              .captureCamera(remote, front: rear == null);
          await _addImageBytes(
            bytes,
            '${remote.name ?? 'cluster-worker'}-frame-${index + 1}.jpg',
            'image/jpeg',
          );
          if (index < 2) {
            await Future<void>.delayed(const Duration(milliseconds: 350));
          }
        }
        return;
      }
    }
    final picked = await ImagePicker().pickVideo(
      source: source,
      maxDuration: const Duration(minutes: 2),
    );
    if (picked == null) return;
    final frames = await ServerController.extractVideoFrames(picked.path);
    if (frames.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "No usable frames could be extracted from the video.",
            ),
            showCloseIcon: true,
          ),
        );
      }
      return;
    }
    for (var index = frames.length - 1; index >= 0; index--) {
      final encoded = frames[index];
      messages.insert(
        0,
        types.ImageMessage(
          author: user,
          id: const Uuid().v4(),
          name: "${picked.name}-frame-${index + 1}.jpg",
          size: base64.decode(encoded).length,
          uri: "data:image/jpeg;base64,$encoded",
        ),
      );
    }
    if (mounted) setState(() {});
    HapticFeedback.selectionClick();
  }

  void _showAttachmentSheet() {
    HapticFeedback.selectionClick();
    if (!chatAllowed || model == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final visualEnabled = _visualAttachmentsEnabled;
          final capabilityText = appText(
              "Only types enabled for this model are shown.",
              "Solo se muestran los tipos habilitados para este modelo.");
          Future<void> run(Future<void> Function() action) async {
            Navigator.of(sheetContext).pop();
            await action();
          }

          void toggleGrounding({required bool deep, required bool enabled}) {
            setState(() {
              _groundNextPrompt = enabled;
              _deepExploreNextPrompt = enabled && deep;
            });
            setSheetState(() {});
          }

          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      appText("Attach", "Adjuntar"),
                      style: Theme.of(sheetContext).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(capabilityText),
                  ),
                  const SizedBox(height: 4),
                  if (selectedModelCapabilities.contains("tools")) ...[
                    SwitchListTile(
                      secondary: const Icon(Icons.public_rounded),
                      title: Text(appText("Grounding with the web",
                          "Fundamentación con la web")),
                      value: _groundNextPrompt && !_deepExploreNextPrompt,
                      onChanged: (enabled) => toggleGrounding(
                        deep: false,
                        enabled: enabled,
                      ),
                    ),
                    SwitchListTile(
                      secondary: const _TelescopeIcon(),
                      title: Text(
                          appText("Deep Exploration", "Exploración profunda")),
                      value: _groundNextPrompt && _deepExploreNextPrompt,
                      onChanged: (enabled) => toggleGrounding(
                        deep: true,
                        enabled: enabled,
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (selectedModelCapabilities.contains("files")) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => run(_pickTextFile),
                        icon: const Icon(Icons.description_rounded),
                        label: Text(appText(
                            "Text or code file", "Archivo de texto o código")),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (selectedModelCapabilities.contains("documents")) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => run(_pickDocument),
                        icon: const Icon(Icons.attach_file_rounded),
                        label: Text(
                            appText("Attach document", "Adjuntar documento")),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (selectedModelCapabilities.contains("audio")) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => run(_pickAudioFile),
                        icon: const Icon(Icons.audio_file_rounded),
                        label: Text(appText("Audio file", "Archivo de audio")),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (visualEnabled) ...[
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () => run(_pickSupportedImageFile),
                        icon: const Icon(Icons.image_rounded),
                        label: Text(appText(
                            "Image (JPEG, PNG, GIF, WebP or SVG)",
                            "Imagen (JPEG, PNG, GIF, WebP o SVG)")),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (clusterCaptureEntityEnabled(clusterEntityCameraFront) ||
                        clusterCaptureEntityEnabled(
                            clusterEntityCameraRear)) ...[
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              run(() => _pickImage(ImageSource.camera)),
                          icon: const Icon(Icons.photo_camera_rounded),
                          label:
                              Text(appText("Take a photo", "Hacer una foto")),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            run(() => _pickVideo(ImageSource.gallery)),
                        icon: const Icon(Icons.video_library_rounded),
                        label: Text(appText("Gallery video (3 frames)",
                            "Vídeo de la galería (3 fotogramas)")),
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (clusterCaptureEntityEnabled(clusterEntityCameraFront) ||
                        clusterCaptureEntityEnabled(clusterEntityCameraRear))
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: () =>
                              run(() => _pickVideo(ImageSource.camera)),
                          icon: const Icon(Icons.videocam_rounded),
                          label: Text(appText("Record video (3 frames)",
                              "Grabar vídeo (3 fotogramas)")),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> sidebar(BuildContext context, Function setState) {
    return List.from([
      ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
              MediaQuery.of(context).size.width >= 1000)
          ? const SizedBox.shrink()
          : (Padding(
              padding: const EdgeInsets.only(left: 12, right: 12),
              child: InkWell(
                customBorder: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(50)),
                ),
                onTap: () {},
                child: Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 16),
                  child: Row(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 16, right: 12),
                        child: ImageIcon(AssetImage("assets/logo512.png")),
                      ),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!.appTitle,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            )),
      ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
              MediaQuery.of(context).size.width >= 1000)
          ? const SizedBox.shrink()
          : (!allowMultipleChats && !allowSettings)
              ? const SizedBox.shrink()
              : const Divider(),
      (allowMultipleChats)
          ? (Padding(
              padding: const EdgeInsets.only(left: 12, right: 12),
              child: InkWell(
                customBorder: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(50)),
                ),
                onTap: () {
                  HapticFeedback.selectionClick();
                  if (!(Platform.isWindows ||
                          Platform.isLinux ||
                          Platform.isMacOS) &&
                      MediaQuery.of(context).size.width <= 1000) {
                    Navigator.of(context).pop();
                  }
                  if (!chatAllowed) return;
                  chatUuid = null;
                  messages = [];
                  setState(() {});
                },
                child: Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 16),
                  child: Row(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 16, right: 12),
                        child: Icon(Icons.add_rounded),
                      ),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!.optionNewChat,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            ))
          : const SizedBox.shrink(),
      (allowSettings)
          ? (Padding(
              padding: const EdgeInsets.only(left: 12, right: 12),
              child: InkWell(
                customBorder: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(50)),
                ),
                onTap: () {
                  HapticFeedback.selectionClick();
                  if (!(Platform.isWindows ||
                          Platform.isLinux ||
                          Platform.isMacOS) &&
                      MediaQuery.of(context).size.width <= 1000) {
                    Navigator.of(context).pop();
                  }
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ScreenAssistant(),
                    ),
                  );
                },
                child: const Padding(
                  padding: EdgeInsets.only(top: 16, bottom: 16),
                  child: Row(
                    children: [
                      Padding(
                        padding: EdgeInsets.only(left: 16, right: 12),
                        child: Icon(Icons.assistant_rounded),
                      ),
                      Expanded(
                        child: Text(
                          "Assistant",
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            ))
          : const SizedBox.shrink(),
      (allowSettings)
          ? (Padding(
              padding: const EdgeInsets.only(left: 12, right: 12),
              child: InkWell(
                customBorder: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(50)),
                ),
                onTap: () {
                  HapticFeedback.selectionClick();
                  if (!(Platform.isWindows ||
                          Platform.isLinux ||
                          Platform.isMacOS) &&
                      MediaQuery.of(context).size.width <= 1000) {
                    Navigator.of(context).pop();
                  }
                  setState(() {
                    settingsOpen = true;
                  });
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => const ScreenSettings(),
                    ),
                  );
                },
                child: Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 16),
                  child: Row(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 16, right: 12),
                        child: Icon(Icons.dns_rounded),
                      ),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!.optionSettings,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            ))
          : const SizedBox.shrink(),
      Divider(
        color: ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
                MediaQuery.of(context).size.width >= 1000)
            ? (Theme.of(context).brightness == Brightness.light)
                ? Colors.grey[400]
                : Colors.grey[900]
            : null,
      ),
      ((prefs?.getStringList("chats") ?? []).isNotEmpty)
          ? const SizedBox.shrink()
          : (Padding(
              padding: const EdgeInsets.only(left: 12, right: 12),
              child: InkWell(
                customBorder: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(50)),
                ),
                onTap: () {
                  HapticFeedback.selectionClick();
                },
                child: Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 16),
                  child: Row(
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(left: 16, right: 12),
                        child: Icon(
                          Icons.question_mark_rounded,
                          color: Colors.grey,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!.optionNoChatFound,
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: const TextStyle(
                            fontWeight: FontWeight.w500,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            )),
      Builder(
        builder: (context) {
          String tip = (tipId == 0)
              ? AppLocalizations.of(context)!.tip0
              : (tipId == 1)
                  ? AppLocalizations.of(context)!.tip1
                  : (tipId == 2)
                      ? AppLocalizations.of(context)!.tip2
                      : (tipId == 3)
                          ? AppLocalizations.of(context)!.tip3
                          : AppLocalizations.of(context)!.tip4;
          return (!(prefs?.getBool("tips") ?? true) ||
                  (prefs?.getStringList("chats") ?? []).isNotEmpty ||
                  !allowSettings)
              ? const SizedBox.shrink()
              : (Padding(
                  padding: const EdgeInsets.only(left: 12, right: 12),
                  child: InkWell(
                    splashFactory: NoSplash.splashFactory,
                    highlightColor: Colors.transparent,
                    enableFeedback: false,
                    hoverColor: Colors.transparent,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() {
                        tipId = Random().nextInt(5);
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.only(top: 16, bottom: 16),
                      child: Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(left: 16, right: 12),
                            child: Icon(
                              Icons.tips_and_updates_rounded,
                              color: Colors.grey,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              AppLocalizations.of(context)!.tipPrefix + tip,
                              softWrap: true,
                              maxLines: 3,
                              overflow: TextOverflow.fade,
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                        ],
                      ),
                    ),
                  ),
                ));
        },
      ),
    ])
      ..addAll(
        (prefs?.getStringList("chats") ?? []).map((item) {
          return Dismissible(
            key: Key(jsonDecode(item)["uuid"]),
            direction: (chatAllowed)
                ? DismissDirection.startToEnd
                : DismissDirection.none,
            confirmDismiss: (direction) async {
              bool returnValue = false;
              if (!chatAllowed) return false;

              if (prefs!.getBool("askBeforeDeletion") ?? false) {
                await showDialog(
                  context: context,
                  builder: (context) {
                    return StatefulBuilder(
                      builder: (context, setLocalState) {
                        return AlertDialog(
                          title: Text(
                            AppLocalizations.of(context)!.deleteDialogTitle,
                          ),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                AppLocalizations.of(
                                  context,
                                )!
                                    .deleteDialogDescription,
                              ),
                            ],
                          ),
                          actions: [
                            TextButton(
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                Navigator.of(context).pop();
                                returnValue = false;
                              },
                              child: Text(
                                AppLocalizations.of(context)!
                                    .deleteDialogCancel,
                              ),
                            ),
                            TextButton(
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                Navigator.of(context).pop();
                                returnValue = true;
                              },
                              child: Text(
                                AppLocalizations.of(context)!
                                    .deleteDialogDelete,
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                );
              } else {
                returnValue = true;
              }
              return returnValue;
            },
            onDismissed: (direction) {
              HapticFeedback.selectionClick();
              for (var i = 0;
                  i < (prefs!.getStringList("chats") ?? []).length;
                  i++) {
                if (jsonDecode(
                      (prefs!.getStringList("chats") ?? [])[i],
                    )["uuid"] ==
                    jsonDecode(item)["uuid"]) {
                  List<String> tmp = prefs!.getStringList("chats")!;
                  tmp.removeAt(i);
                  prefs!.setStringList("chats", tmp);
                  break;
                }
              }
              if (chatUuid == jsonDecode(item)["uuid"]) {
                messages = [];
                chatUuid = null;
                if (!(Platform.isWindows ||
                        Platform.isLinux ||
                        Platform.isMacOS) &&
                    MediaQuery.of(context).size.width <= 1000) {
                  Navigator.of(context).pop();
                }
              }
              setState(() {});
            },
            child: Padding(
              padding: const EdgeInsets.only(left: 12, right: 12),
              child: InkWell(
                customBorder: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(50)),
                ),
                onTap: () {
                  HapticFeedback.selectionClick();
                  if (!(Platform.isWindows ||
                          Platform.isLinux ||
                          Platform.isMacOS) &&
                      MediaQuery.of(context).size.width <= 1000) {
                    Navigator.of(context).pop();
                  }
                  if (!chatAllowed) return;
                  loadChat(jsonDecode(item)["uuid"], setState);
                  chatUuid = jsonDecode(item)["uuid"];
                },
                onLongPress: () async {
                  HapticFeedback.selectionClick();
                  if (!chatAllowed) return;
                  if (!allowSettings) return;
                  String oldTitle = jsonDecode(item)["title"];
                  var newTitle = await prompt(
                    context,
                    title: AppLocalizations.of(context)!.dialogEnterNewTitle,
                    value: oldTitle,
                    uuid: jsonDecode(item)["uuid"],
                  );
                  var tmp = (prefs!.getStringList("chats") ?? []);
                  for (var i = 0; i < tmp.length; i++) {
                    if (jsonDecode(
                          (prefs!.getStringList("chats") ?? [])[i],
                        )["uuid"] ==
                        jsonDecode(item)["uuid"]) {
                      var tmp2 = jsonDecode(tmp[i]);
                      tmp2["title"] = newTitle;
                      tmp[i] = jsonEncode(tmp2);
                      break;
                    }
                  }
                  prefs!.setStringList("chats", tmp);
                  setState(() {});
                },
                child: Padding(
                  padding: const EdgeInsets.only(top: 16, bottom: 16),
                  child: Row(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 16, right: 16),
                        child: Icon(
                          (chatUuid == jsonDecode(item)["uuid"])
                              ? Icons.location_on_rounded
                              : Icons.restore_rounded,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          jsonDecode(item)["title"],
                          softWrap: false,
                          overflow: TextOverflow.fade,
                          style: const TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      );
  }

  @override
  void dispose() {
    _chatActivityScrollController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (prefs == null) {
        await Future.doWhile(
          () => Future.delayed(const Duration(milliseconds: 1)).then((_) {
            return prefs == null;
          }),
        );
      }

      void setBrightness() {
        WidgetsBinding.instance.platformDispatcher.onPlatformBrightnessChanged =
            () {
          // invert colors used, because brightness not updated yet
          SystemChrome.setSystemUIOverlayStyle(
            SystemUiOverlayStyle(
              systemNavigationBarColor:
                  (prefs!.getString("brightness") ?? "system") == "system"
                      ? ((MediaQuery.of(context).platformBrightness ==
                              Brightness.light)
                          ? (themeDark ?? ThemeData.dark()).colorScheme.surface
                          : (theme ?? ThemeData()).colorScheme.surface)
                      : (prefs!.getString("brightness") == "dark"
                          ? (themeDark ?? ThemeData()).colorScheme.surface
                          : (theme ?? ThemeData.dark()).colorScheme.surface),
              systemNavigationBarIconBrightness:
                  (((prefs!.getString("brightness") ?? "system") == "system" &&
                              MediaQuery.of(context).platformBrightness ==
                                  Brightness.dark) ||
                          prefs!.getString("brightness") == "light")
                      ? Brightness.dark
                      : Brightness.light,
            ),
          );
        };

        // brightness changed function not run at first startup
        SystemChrome.setSystemUIOverlayStyle(
          SystemUiOverlayStyle(
            systemNavigationBarColor:
                (prefs!.getString("brightness") ?? "system") == "system"
                    ? ((MediaQuery.of(context).platformBrightness ==
                            Brightness.light)
                        ? (theme ?? ThemeData.dark()).colorScheme.surface
                        : (themeDark ?? ThemeData()).colorScheme.surface)
                    : (prefs!.getString("brightness") == "dark"
                        ? (themeDark ?? ThemeData()).colorScheme.surface
                        : (theme ?? ThemeData.dark()).colorScheme.surface),
            systemNavigationBarIconBrightness:
                (((prefs!.getString("brightness") ?? "system") == "system" &&
                            MediaQuery.of(context).platformBrightness ==
                                Brightness.light) ||
                        prefs!.getString("brightness") == "light")
                    ? Brightness.dark
                    : Brightness.light,
          ),
        );
      }

      setBrightness();

      // prefs!.remove("welcomeFinished");
      if (!(prefs!.getBool("welcomeFinished") ?? false) && allowSettings) {
        // ignore: use_build_context_synchronously
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (context) => const ScreenWelcome()),
        );
        return;
      }

      if (!(allowSettings || useHost)) {
        showDialog(
          // ignore: use_build_context_synchronously
          context: context,
          builder: (context) {
            return const PopScope(
              canPop: false,
              child: Dialog.fullscreen(
                backgroundColor: Colors.black,
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    "*Build Error:*\n\nuseHost: $useHost\nallowSettings: $allowSettings\n\nYou created this build? One of them must be set to true or the app is not functional!\n\nYou received this build by someone else? Please contact them and report the issue.",
                    style: TextStyle(color: Colors.red),
                  ),
                ),
              ),
            );
          },
        );
      }

      if (!allowMultipleChats &&
          (prefs!.getStringList("chats") ?? []).isNotEmpty) {
        chatUuid = jsonDecode((prefs!.getStringList("chats") ?? [])[0])["uuid"];
        loadChat(chatUuid!, setState);
      }

      setState(() {
        model = useModel ? fixedModel : prefs!.getString("model");
        chatAllowed = true;
        selectedModelCapabilities =
            (prefs?.getStringList("modelCapabilities") ?? const <String>[])
                .map((capability) => capability.toLowerCase())
                .toSet();
        attachmentOverride = model != null &&
            (prefs?.getBool("attachmentOverride:$model") ?? false);
        multimodal = hasModelAttachmentCapabilities(selectedModelCapabilities);
        host = useHost ? fixedHost : configuredHost();
      });

      if (host == null) {
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            // ignore: use_build_context_synchronously
            content: Text(AppLocalizations.of(context)!.noHostSelected),
            showCloseIcon: true,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    late final void Function(types.PartialText) handleSend;
    Widget selector = InkWell(
      onTap: () {
        if (host == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context)!.noHostSelected),
              showCloseIcon: true,
            ),
          );
          return;
        }
        setModel(context, setState);
      },
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      enableFeedback: false,
      hoverColor: Colors.transparent,
      child: SizedBox(
        height: 200,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                (model ?? AppLocalizations.of(context)!.noSelectedModel).split(
                  ":",
                )[0],
                overflow: TextOverflow.fade,
                style: const TextStyle(fontFamily: "monospace", fontSize: 16),
              ),
            ),
            useModel
                ? const SizedBox.shrink()
                : const Icon(Icons.expand_more_rounded),
          ],
        ),
      ),
    );

    return WindowBorder(
      color: Theme.of(context).colorScheme.surface,
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                  ? SizedBox(width: 85, height: 200, child: MoveWindow())
                  : const SizedBox.shrink(),
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                  ? Expanded(child: SizedBox(height: 200, child: MoveWindow()))
                  : const SizedBox.shrink(),
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                  ? selector
                  : Expanded(child: selector),
              (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                  ? Expanded(child: SizedBox(height: 200, child: MoveWindow()))
                  : const SizedBox.shrink(),
            ],
          ),
          actions: (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
              ? [
                  SizedBox(
                    height: 200,
                    child: WindowTitleBarBox(
                      child: Row(
                        children: [
                          // Expanded(child: MoveWindow()),
                          SizedBox(
                            height: 200,
                            child: MinimizeWindowButton(
                              animate: true,
                              colors: WindowButtonColors(
                                iconNormal: Theme.of(
                                  context,
                                ).colorScheme.primary,
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 72,
                            child: MaximizeWindowButton(
                              animate: true,
                              colors: WindowButtonColors(
                                iconNormal: Theme.of(
                                  context,
                                ).colorScheme.primary,
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 72,
                            child: CloseWindowButton(
                              animate: true,
                              colors: WindowButtonColors(
                                iconNormal: Theme.of(
                                  context,
                                ).colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ]
              : [
                  const SizedBox(width: 4),
                  if (!chatAllowed && _modelIsThinking)
                    IconButton(
                      tooltip: appText("Stop reasoning and answer",
                          "Dejar de razonar y responder"),
                      onPressed: _forceAnswer,
                      icon: const Icon(Icons.fast_forward_rounded),
                    ),
                  if (!chatAllowed)
                    IconButton(
                      tooltip: appText("Stop response", "Detener respuesta"),
                      onPressed: _stopGeneration,
                      icon: const Icon(Icons.stop_circle_outlined),
                    ),
                  IconButton(
                    tooltip: appText("Chat settings", "Ajustes del chat"),
                    onPressed: _showChatControls,
                    icon: const Icon(Icons.tune_rounded),
                  ),
                ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: (!chatAllowed && model != null)
                ? const LinearProgressIndicator()
                : ((Platform.isWindows ||
                            Platform.isLinux ||
                            Platform.isMacOS) &&
                        MediaQuery.of(context).size.width >= 1000)
                    ? AnimatedOpacity(
                        opacity: menuVisible ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 500),
                        child: Divider(
                          height: 2,
                          color:
                              (Theme.of(context).brightness == Brightness.light)
                                  ? Colors.grey[400]
                                  : Colors.grey[900],
                        ),
                      )
                    : const SizedBox.shrink(),
          ),
          leading:
              ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
                      MediaQuery.of(context).size.width >= 1000)
                  ? const SizedBox()
                  : null,
        ),
        body: Row(
          children: [
            ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
                    MediaQuery.of(context).size.width >= 1000)
                ? SizedBox(
                    width: 304,
                    height: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 5),
                      child: VisibilityDetector(
                        key: const Key("menuVisible"),
                        onVisibilityChanged: (VisibilityInfo info) {
                          if (settingsOpen) return;
                          menuVisible = info.visibleFraction > 0;
                          try {
                            setState(() {});
                          } catch (_) {}
                        },
                        child: AnimatedOpacity(
                          opacity: menuVisible ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 500),
                          child: ListView(children: sidebar(context, setState)),
                        ),
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
            ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
                    MediaQuery.of(context).size.width >= 1000)
                ? AnimatedOpacity(
                    opacity: menuVisible ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 500),
                    child: VerticalDivider(
                      width: 2,
                      color: (Theme.of(context).brightness == Brightness.light)
                          ? Colors.grey[400]
                          : Colors.grey[900],
                    ),
                  )
                : const SizedBox.shrink(),
            Expanded(
              child: Chat(
                messages: messages,
                customMessageBuilder: (thinkingMessage,
                        {required messageWidth}) =>
                    ThinkingMessageCard(
                  key: ValueKey(thinkingMessage.id),
                  message: thinkingMessage,
                  messageWidth: messageWidth,
                ),
                textMessageBuilder: (p0,
                    {required messageWidth, required showName}) {
                  if (p0.metadata?["attachmentName"] != null) {
                    return const SizedBox.shrink();
                  }
                  var white = const TextStyle(color: Colors.white);
                  return Padding(
                    padding: const EdgeInsets.only(
                      left: 20,
                      right: 23,
                      top: 17,
                      bottom: 17,
                    ),
                    child: MarkdownBody(
                      data: p0.text,
                      onTapLink: (text, href, title) async {
                        HapticFeedback.selectionClick();
                        try {
                          var url = Uri.parse(href!);
                          if (await canLaunchUrl(url)) {
                            launchUrl(
                              mode: LaunchMode.inAppBrowserView,
                              url,
                            );
                          } else {
                            throw Exception();
                          }
                        } catch (_) {
                          // ignore: use_build_context_synchronously
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                // ignore: use_build_context_synchronously
                                AppLocalizations.of(
                                  context,
                                )!
                                    .settingsHostInvalid("url"),
                              ),
                              showCloseIcon: true,
                            ),
                          );
                        }
                      },
                      extensionSet: md.ExtensionSet(
                        md.ExtensionSet.gitHubFlavored.blockSyntaxes,
                        <md.InlineSyntax>[
                          md.EmojiSyntax(),
                          ...md.ExtensionSet.gitHubFlavored.inlineSyntaxes,
                        ],
                      ),
                      imageBuilder: (uri, title, alt) {
                        if (uri.isAbsolute) {
                          return Image.network(
                            uri.toString(),
                            errorBuilder: (context, error, stackTrace) {
                              return InkWell(
                                onTap: () {
                                  HapticFeedback.selectionClick();
                                  ScaffoldMessenger.of(
                                    context,
                                  ).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        AppLocalizations.of(
                                          context,
                                        )!
                                            .notAValidImage,
                                      ),
                                      showCloseIcon: true,
                                    ),
                                  );
                                },
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    color: Theme.of(context).brightness ==
                                            Brightness.light
                                        ? Colors.white
                                        : Colors.black,
                                  ),
                                  padding: const EdgeInsets.only(
                                    left: 100,
                                    right: 100,
                                    top: 32,
                                  ),
                                  child: const Image(
                                    image: AssetImage(
                                      "assets/logo512error.png",
                                    ),
                                  ),
                                ),
                              );
                            },
                          );
                        } else {
                          return InkWell(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    AppLocalizations.of(
                                      context,
                                    )!
                                        .notAValidImage,
                                  ),
                                  showCloseIcon: true,
                                ),
                              );
                            },
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: Theme.of(context).brightness ==
                                        Brightness.light
                                    ? Colors.white
                                    : Colors.black,
                              ),
                              padding: const EdgeInsets.only(
                                left: 100,
                                right: 100,
                                top: 32,
                              ),
                              child: const Image(
                                image: AssetImage(
                                  "assets/logo512error.png",
                                ),
                              ),
                            ),
                          );
                        }
                      },
                      styleSheet: (p0.author == user)
                          ? MarkdownStyleSheet(
                              p: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                              blockquoteDecoration: BoxDecoration(
                                color: Colors.grey[800],
                                borderRadius: BorderRadius.circular(8),
                              ),
                              code: const TextStyle(
                                color: Colors.black,
                                backgroundColor: Colors.white,
                              ),
                              codeblockDecoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              h1: white,
                              h2: white,
                              h3: white,
                              h4: white,
                              h5: white,
                              h6: white,
                              listBullet: white,
                              horizontalRuleDecoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: Colors.grey[800]!,
                                    width: 1,
                                  ),
                                ),
                              ),
                              tableBorder: TableBorder.all(
                                color: Colors.white,
                              ),
                              tableBody: white,
                            )
                          : (Theme.of(context).brightness == Brightness.light)
                              ? MarkdownStyleSheet(
                                  p: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  blockquoteDecoration: BoxDecoration(
                                    color: Colors.grey[200],
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  code: const TextStyle(
                                    color: Colors.white,
                                    backgroundColor: Colors.black,
                                  ),
                                  codeblockDecoration: BoxDecoration(
                                    color: Colors.black,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  horizontalRuleDecoration: BoxDecoration(
                                    border: Border(
                                      top: BorderSide(
                                        color: Colors.grey[200]!,
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                )
                              : MarkdownStyleSheet(
                                  p: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  blockquoteDecoration: BoxDecoration(
                                    color: Colors.grey[800]!,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  code: const TextStyle(
                                    color: Colors.black,
                                    backgroundColor: Colors.white,
                                  ),
                                  codeblockDecoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  horizontalRuleDecoration: BoxDecoration(
                                    border: Border(
                                      top: BorderSide(
                                        color: Colors.grey[200]!,
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                ),
                    ),
                  );
                },
                imageMessageBuilder: (p0, {required messageWidth}) {
                  return SizedBox(
                    width: ((Platform.isWindows ||
                                Platform.isLinux ||
                                Platform.isMacOS) &&
                            MediaQuery.of(context).size.width >= 1000)
                        ? 360.0
                        : 160.0,
                    child: MarkdownBody(data: "![${p0.name}](${p0.uri})"),
                  );
                },
                disableImageGallery: true,
                // keyboardDismissBehavior:
                //     ScrollViewKeyboardDismissBehavior.onDrag,
                emptyState: Center(
                  child: VisibilityDetector(
                    key: const Key("logoVisible"),
                    onVisibilityChanged: (VisibilityInfo info) {
                      if (settingsOpen) return;
                      logoVisible = info.visibleFraction > 0;
                      try {
                        setState(() {});
                      } catch (_) {}
                    },
                    child: AnimatedOpacity(
                      opacity: logoVisible ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 500),
                      child: const ImageIcon(
                        AssetImage("assets/logo512.png"),
                        size: 44,
                      ),
                    ),
                  ),
                ),
                onSendPressed: handleSend = (p0) async {
                  HapticFeedback.selectionClick();
                  setState(() {
                    sendable = false;
                  });

                  if (host == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          AppLocalizations.of(context)!.noHostSelected,
                        ),
                        showCloseIcon: true,
                      ),
                    );
                    return;
                  }

                  if (!chatAllowed || model == null) {
                    if (model == null) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            AppLocalizations.of(context)!.noModelSelected,
                          ),
                          showCloseIcon: true,
                        ),
                      );
                    }
                    return;
                  }

                  bool newChat = false;
                  if (chatUuid == null) {
                    newChat = true;
                    chatUuid = const Uuid().v4();
                    prefs!.setStringList(
                      "chats",
                      (prefs!.getStringList("chats") ?? []).append([
                        jsonEncode({
                          "title": AppLocalizations.of(context)!.newChatTitle,
                          "uuid": chatUuid,
                          "messages": [],
                        }),
                      ]).toList(),
                    );
                  }

                  var system = applyMinimumResponseLength(
                      prefs?.getString("system") ??
                          "You are a helpful assistant");
                  if (prefs!.getBool("noMarkdown") ?? false) {
                    system +=
                        " You must not use markdown or any other formatting language in any way!";
                  }

                  final supplementalSystemContext = <String>[];
                  final useGrounding =
                      selectedModelCapabilities.contains("tools") &&
                          _groundNextPrompt;
                  final useDeepExploration =
                      useGrounding && _deepExploreNextPrompt;
                  String? groundingEvidence;
                  if (useGrounding) {
                    setState(() {
                      _groundNextPrompt = false;
                      _deepExploreNextPrompt = false;
                      _activeChatTool = useDeepExploration
                          ? "Deep Exploration en curso"
                          : "Buscando en internet";
                    });
                    try {
                      final evidence = await buildWebGroundingEvidence(
                        p0.text.trim(),
                        deep: useDeepExploration,
                        maxLinks: prefs?.getInt("groundingMaxLinks") ?? 3,
                      );
                      groundingEvidence = evidence;
                      supplementalSystemContext
                          .add(assistantWebResultsContext(evidence));
                    } catch (error) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(appText(
                              "Could not obtain web grounding: $error",
                              "No se pudo obtener grounding web: $error")),
                          showCloseIcon: true,
                        ));
                      }
                    } finally {
                      if (mounted) setState(() => _activeChatTool = null);
                    }
                  }
                  final pendingAttachments = _pendingAttachments;
                  final pendingImages = <String>[];
                  final pendingDocuments = <RagDocument>[];
                  for (final attachment in pendingAttachments.reversed) {
                    if (isDirectMediaAttachment(attachment)) {
                      pendingImages.add(await directMediaContent(attachment));
                    }
                    pendingImages.addAll(_attachmentImages(attachment));
                    final document = _attachmentDocument(attachment);
                    if (document != null) pendingDocuments.add(document);
                  }
                  final documentContext = buildDocumentRagContext(
                    p0.text.trim(),
                    pendingDocuments,
                    maxChunks: prefs?.getInt("documentRagMaxChunks") ?? 8,
                    // Keep document prefill proportional to the active model
                    // context. Tiny local models otherwise spend minutes
                    // ingesting excerpts that nearly fill their whole window.
                    maxContextCharacters: min(
                      14000,
                      max(
                        1800,
                        _modelIntPreference(
                              "chatContextTokens",
                              prefs?.getInt("chatContextTokens") ??
                                  defaultChatContextTokens,
                            ) ~/
                            2,
                      ),
                    ),
                  );
                  if (documentContext.isNotEmpty) {
                    supplementalSystemContext.add(documentContext);
                  }

                  // Several templates (notably Qwen 3.5) reject a second
                  // system-role message with HTTP 500. Merge every trusted
                  // context source into the one leading system message.
                  final history = <llama.Message>[
                    llama.Message(
                      role: llama.MessageRole.system,
                      content: mergeSystemContexts(
                          system, supplementalSystemContext),
                    ),
                  ];

                  // Chat UI stores newest messages first. Ollama expects
                  // chronological order, with images attached to the user
                  // text that follows them.
                  final historicalImages = <String>[];
                  for (final message in messages
                      .skip(pendingAttachments.length)
                      .toList()
                      .reversed) {
                    if (isDirectMediaAttachment(message)) {
                      historicalImages.add(await directMediaContent(message));
                      continue;
                    }
                    if (message is! types.TextMessage) continue;
                    history.add(
                      llama.Message(
                        role: (message.author.id == user.id)
                            ? llama.MessageRole.user
                            : llama.MessageRole.assistant,
                        content: message.text,
                        images: historicalImages.isEmpty
                            ? null
                            : List<String>.from(historicalImages),
                      ),
                    );
                    historicalImages.clear();
                  }

                  history.add(
                    llama.Message(
                      role: llama.MessageRole.user,
                      content: pendingDocuments.isEmpty
                          ? p0.text.trim()
                          : "The user attached ${pendingDocuments.map((document) => document.name).join(', ')}. "
                              "Use the retrieved document context to answer this request:\n${p0.text.trim()}",
                      images: pendingImages.isNotEmpty ? pendingImages : null,
                    ),
                  );
                  final attachmentNames = pendingAttachments
                      .map(_pendingAttachmentName)
                      .toList(growable: false);
                  messages.removeWhere((message) => pendingAttachments
                      .any((attachment) => attachment.id == message.id));
                  messages.insert(
                    0,
                    types.TextMessage(
                      author: user,
                      id: const Uuid().v4(),
                      text: p0.text.trim(),
                      metadata: attachmentNames.isEmpty
                          ? null
                          : {"attachedDocuments": attachmentNames},
                    ),
                  );

                  saveChat(chatUuid!, setState);

                  setState(() {});
                  chatAllowed = false;

                  String newId = const Uuid().v4();
                  String thinkingId = const Uuid().v4();
                  llama.OllamaClient client = llama.OllamaClient(
                    headers: activeHostHeaders(),
                    baseUrl: "$host/api",
                  );

                  void replaceGeneratedMessage(types.Message message) {
                    messages.removeWhere((item) => item.id == message.id);
                    messages.insert(0, message);
                  }

                  void renderGeneration(String text, String thinking,
                      {required bool isThinking}) {
                    messages.removeWhere(
                        (item) => item.id == newId || item.id == thinkingId);
                    if (thinking.trim().isNotEmpty || isThinking) {
                      messages.insert(
                        0,
                        types.CustomMessage(
                          author: assistant,
                          createdAt: DateTime.now().millisecondsSinceEpoch,
                          id: thinkingId,
                          metadata: {
                            "kind": "thinking",
                            "thinking": thinking,
                            "isThinking": isThinking,
                          },
                        ),
                      );
                    }
                    if (text.trim().isNotEmpty) {
                      replaceGeneratedMessage(types.TextMessage(
                        author: assistant,
                        id: newId,
                        text: text,
                      ));
                    }
                    if (mounted) setState(() {});
                  }

                  Future<void> runGeneration({bool? thinkingOverride}) async {
                    var text = "";
                    var thinkingText = "";
                    final streaming =
                        (prefs!.getString("requestType") ?? "stream") ==
                            "stream";
                    if (streaming) {
                      await for (final chunk in generateChatStreamRaw(history,
                              thinkingOverride: thinkingOverride)
                          .timeout(activeInferenceTimeout())) {
                        final rawMessage = chunk["message"];
                        final responseMessage = rawMessage is Map
                            ? rawMessage
                            : const <String, dynamic>{};
                        thinkingText += (responseMessage["thinking"] ??
                                chunk["thinking"] ??
                                "")
                            .toString();
                        text += (responseMessage["content"] ?? "").toString();
                        final done = chunk["done"] == true;
                        renderGeneration(text, thinkingText,
                            isThinking: !done && text.trim().isEmpty);
                        HapticFeedback.lightImpact();
                      }
                    } else {
                      final response = await generateChatRaw(history,
                          thinkingOverride: thinkingOverride);
                      final rawMessage = response["message"];
                      final responseMessage = rawMessage is Map
                          ? rawMessage
                          : const <String, dynamic>{};
                      thinkingText = (responseMessage["thinking"] ??
                              response["thinking"] ??
                              "")
                          .toString();
                      text = (responseMessage["content"] ?? "").toString();
                      renderGeneration(text, thinkingText, isThinking: false);
                    }
                    if (text.trim().isEmpty) {
                      throw const FormatException(
                          "El modelo no devolvió una respuesta de texto.");
                    }
                    if (groundingEvidence != null) {
                      text = ensureAssistantWebSources(text, groundingEvidence);
                      renderGeneration(text, thinkingText, isThinking: false);
                    }
                  }

                  try {
                    _generationCancelReason = null;
                    try {
                      await runGeneration();
                    } catch (_) {
                      if (_generationCancelReason !=
                          _GenerationCancelReason.forceAnswer) {
                        rethrow;
                      }
                      _generationCancelReason = null;
                      renderGeneration(
                        "",
                        (messages
                                    .whereType<types.CustomMessage>()
                                    .where((item) => item.id == thinkingId)
                                    .firstOrNull
                                    ?.metadata?["thinking"] ??
                                "")
                            .toString(),
                        isThinking: false,
                      );
                      await runGeneration(thinkingOverride: false);
                    }
                  } catch (e) {
                    for (var i = 0; i < messages.length; i++) {
                      if (messages[i].id == newId ||
                          messages[i].id == thinkingId) {
                        messages.removeAt(i);
                        i--;
                      }
                    }
                    if (_generationCancelReason ==
                        _GenerationCancelReason.user) {
                      _generationCancelReason = null;
                      chatAllowed = true;
                      saveChat(chatUuid!, setState);
                      if (mounted) setState(() {});
                      return;
                    }
                    setState(() {
                      chatAllowed = true;
                      // Keep the user's failed turn visible and put its files
                      // back in the pending strip. This makes failures and
                      // interrupted generations retryable instead of silently
                      // erasing both the question and its documents.
                      final currentIds =
                          messages.map((item) => item.id).toSet();
                      messages.insertAll(
                        0,
                        pendingAttachments.where(
                          (attachment) => !currentIds.contains(attachment.id),
                        ),
                      );
                      if (chatUuid != null) {
                        saveChat(chatUuid!, setState);
                      }
                    });
                    // ignore: use_build_context_synchronously
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        // ignore: use_build_context_synchronously
                        content: Text(
                          AppLocalizations.of(
                            context,
                          )!
                              .settingsHostInvalid(e.toString()),
                        ),
                        showCloseIcon: true,
                      ),
                    );
                    return;
                  }

                  saveChat(chatUuid!, setState);

                  if (newChat && (prefs!.getBool("generateTitles") ?? true)) {
                    void setTitle() async {
                      List<Map<String, String>> history = [];
                      for (var i = 0; i < messages.length; i++) {
                        if (jsonDecode(jsonEncode(messages[i]))["text"] ==
                            null) {
                          continue;
                        }
                        history.add({
                          "role": (messages[i].author == user)
                              ? "user"
                              : "assistant",
                          "content": jsonDecode(
                            jsonEncode(messages[i]),
                          )["text"],
                        });
                      }
                      history = history.reversed.toList();

                      try {
                        final generated = await client.generateCompletion(
                          request: llama.GenerateCompletionRequest(
                            model: model!,
                            options: activeComputeOptions(),
                            prompt:
                                "You must not use markdown or any other formatting language! Create a short title for the subject of the conversation described in the following json object. It is not allowed to be too general; no 'Assistance', 'Help' or similar!\n\n```json\n${jsonEncode(history)}\n```",
                          ),
                        );
                        var title = generated.response!
                            .replaceAll("*", "")
                            .replaceAll("_", "")
                            .trim();
                        var tmp = (prefs!.getStringList("chats") ?? []);
                        for (var i = 0; i < tmp.length; i++) {
                          if (jsonDecode(
                                (prefs!.getStringList("chats") ?? [])[i],
                              )["uuid"] ==
                              chatUuid) {
                            var tmp2 = jsonDecode(tmp[i]);
                            tmp2["title"] = title;
                            tmp[i] = jsonEncode(tmp2);
                            break;
                          }
                        }
                        prefs!.setStringList("chats", tmp);
                      } catch (_) {}

                      setState(() {});
                    }

                    setTitle();
                  }

                  setState(() {});
                  chatAllowed = true;
                },
                onMessageDoubleTap: (context, p1) {
                  HapticFeedback.selectionClick();
                  if (!chatAllowed) return;
                  if (p1.author == assistant) return;
                  for (var i = 0; i < messages.length; i++) {
                    if (messages[i].id == p1.id) {
                      List messageList =
                          (jsonDecode(jsonEncode(messages)) as List)
                              .reversed
                              .toList();
                      bool found = false;
                      List index = [];
                      for (var j = 0; j < messageList.length; j++) {
                        if (messageList[j]["id"] == p1.id) {
                          found = true;
                        }
                        if (found) {
                          index.add(messageList[j]["id"]);
                        }
                      }
                      for (var j = 0; j < index.length; j++) {
                        for (var k = 0; k < messages.length; k++) {
                          if (messages[k].id == index[j]) {
                            messages.removeAt(k);
                          }
                        }
                      }
                      break;
                    }
                  }
                  saveChat(chatUuid!, setState);
                  setState(() {});
                },
                onMessageLongPress: (context, p1) async {
                  HapticFeedback.selectionClick();

                  if (!(prefs!.getBool("enableEditing") ?? false)) {
                    return;
                  }

                  var index = -1;
                  if (!chatAllowed) return;
                  for (var i = 0; i < messages.length; i++) {
                    if (messages[i].id == p1.id) {
                      index = i;
                      break;
                    }
                  }

                  var text = (messages[index] as types.TextMessage).text;
                  var input = await prompt(
                    context,
                    title: AppLocalizations.of(context)!.dialogEditMessageTitle,
                    value: text,
                    keyboard: TextInputType.multiline,
                    maxLines: (text.length >= 100)
                        ? 10
                        : ((text.length >= 50) ? 5 : 3),
                  );
                  if (input == "") return;

                  messages[index] = types.TextMessage(
                    author: p1.author,
                    createdAt: p1.createdAt,
                    id: p1.id,
                    text: input,
                  );
                  setState(() {});
                },
                onAttachmentPressed:
                    _chatActionMenuDetected ? _showAttachmentSheet : null,
                l10n: ChatL10nEn(
                  inputPlaceholder: AppLocalizations.of(
                    context,
                  )!
                      .messageInputPlaceholder,
                ),
                inputOptions: InputOptions(
                  keyboardType: TextInputType.multiline,
                  onTextChanged: (p0) {
                    setState(() {
                      sendable = p0.trim().isNotEmpty;
                    });
                  },
                  sendButtonVisibilityMode: (Platform.isWindows ||
                          Platform.isLinux ||
                          Platform.isMacOS)
                      ? SendButtonVisibilityMode.always
                      : (sendable)
                          ? SendButtonVisibilityMode.always
                          : SendButtonVisibilityMode.hidden,
                ),
                customBottomWidget: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildChatActivityBar(),
                    Input(
                      isAttachmentUploading: false,
                      onAttachmentPressed:
                          _chatActionMenuDetected ? _showAttachmentSheet : null,
                      onSendPressed: handleSend,
                      options: InputOptions(
                        keyboardType: TextInputType.multiline,
                        onTextChanged: (text) {
                          setState(() {
                            sendable = text.trim().isNotEmpty;
                          });
                        },
                        sendButtonVisibilityMode: (Platform.isWindows ||
                                Platform.isLinux ||
                                Platform.isMacOS)
                            ? SendButtonVisibilityMode.always
                            : sendable
                                ? SendButtonVisibilityMode.always
                                : SendButtonVisibilityMode.hidden,
                      ),
                    ),
                  ],
                ),
                user: user,
                hideBackgroundOnEmojiMessages: false,
                theme: (Theme.of(context).brightness == Brightness.light)
                    ? DefaultChatTheme(
                        backgroundColor:
                            (theme ?? ThemeData()).colorScheme.surface,
                        primaryColor:
                            (theme ?? ThemeData()).colorScheme.primary,
                        attachmentButtonIcon: Icon(_chatActionIcon),
                        sendButtonIcon: const SizedBox(
                          height: 24,
                          child: CircleAvatar(
                            backgroundColor: Colors.black,
                            radius: 12,
                            child: Icon(Icons.arrow_upward_rounded),
                          ),
                        ),
                        sendButtonMargin: EdgeInsets.zero,
                        inputBackgroundColor: (theme ?? ThemeData())
                            .colorScheme
                            .onSurface
                            .withAlpha(10),
                        inputTextColor:
                            (theme ?? ThemeData()).colorScheme.onSurface,
                        inputBorderRadius: const BorderRadius.all(
                          Radius.circular(64),
                        ),
                        inputPadding: const EdgeInsets.all(16),
                        inputMargin: EdgeInsets.only(
                          left: 8,
                          right: 8,
                          bottom: (Platform.isWindows ||
                                  Platform.isLinux ||
                                  Platform.isMacOS)
                              ? 8
                              : MediaQuery.of(context).viewInsets.bottom == 0
                                  ? max(8,
                                      MediaQuery.of(context).viewPadding.bottom)
                                  : 8,
                        ),
                        messageMaxWidth: (MediaQuery.of(context).size.width >=
                                1000)
                            ? (MediaQuery.of(context).size.width >= 1600)
                                ? (MediaQuery.of(context).size.width >= 2200)
                                    ? 1900
                                    : 1300
                                : 700
                            : 440,
                      )
                    : DarkChatTheme(
                        backgroundColor:
                            (themeDark ?? ThemeData.dark()).colorScheme.surface,
                        primaryColor: (themeDark ?? ThemeData.dark())
                            .colorScheme
                            .primary
                            .withAlpha(40),
                        secondaryColor: (themeDark ?? ThemeData.dark())
                            .colorScheme
                            .primary
                            .withAlpha(20),
                        attachmentButtonIcon: Icon(_chatActionIcon),
                        sendButtonIcon: const Icon(Icons.send_rounded),
                        inputBackgroundColor: (themeDark ?? ThemeData())
                            .colorScheme
                            .onSurface
                            .withAlpha(40),
                        inputTextColor:
                            (themeDark ?? ThemeData()).colorScheme.onSurface,
                        inputBorderRadius: const BorderRadius.all(
                          Radius.circular(64),
                        ),
                        inputPadding: const EdgeInsets.all(16),
                        inputMargin: EdgeInsets.only(
                          left: 8,
                          right: 8,
                          bottom: (Platform.isWindows ||
                                  Platform.isLinux ||
                                  Platform.isMacOS)
                              ? 8
                              : MediaQuery.of(context).viewInsets.bottom == 0
                                  ? max(8,
                                      MediaQuery.of(context).viewPadding.bottom)
                                  : 8,
                        ),
                        messageMaxWidth: (MediaQuery.of(context).size.width >=
                                1000)
                            ? (MediaQuery.of(context).size.width >= 1600)
                                ? (MediaQuery.of(context).size.width >= 2200)
                                    ? 1900
                                    : 1300
                                : 700
                            : 440,
                      ),
              ),
            ),
          ],
        ),
        drawerEdgeDragWidth:
            (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                ? null
                : MediaQuery.of(context).size.width,
        drawer: Builder(
          builder: (context) {
            if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
                MediaQuery.of(context).size.width >= 1000) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
              });
            }
            return NavigationDrawer(
              onDestinationSelected: (value) {
                if (value == 1) {
                } else if (value == 2) {}
              },
              selectedIndex: 1,
              children: sidebar(context, setState),
            );
          },
        ),
      ),
    );
  }
}
