import 'package:flutter/services.dart';

class ServerController {
  static const _channel = MethodChannel('com.example.ollama/server');

  static Future<bool> startServer(
      {int maxLoadedModels = 1,
      bool exposeToLan = false,
      String computeMode = "adaptive",
      String forcedDevice = "gpu",
      String rpcServers = "",
      String multimodalBackendDevice = "",
      int synergyCpuPercent = 50,
      int synergyGpuPercent = 50,
      int synergyNpuPercent = 0,
      bool forceCpuSafe = false,
      bool loadVision = false}) async {
    try {
      final bool result = await _channel.invokeMethod('startServer', {
        'maxLoadedModels': maxLoadedModels,
        'exposeToLan': exposeToLan,
        'computeMode': computeMode,
        'forcedDevice': forcedDevice,
        'rpcServers': rpcServers,
        'multimodalBackendDevice': multimodalBackendDevice,
        'synergyCpuPercent': synergyCpuPercent,
        'synergyGpuPercent': synergyGpuPercent,
        'synergyNpuPercent': synergyNpuPercent,
        'forceCpuSafe': forceCpuSafe,
        'loadVision': loadVision,
      });
      return result;
    } on PlatformException catch (e) {
      print("Failed to start server: '${e.message}'.");
      return false;
    }
  }

  static Future<int?> getSystemThemeSeed() async {
    try {
      return await _channel.invokeMethod<int>('getSystemThemeSeed');
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> startRpcWorker(
      {int port = 50052,
      String device = "auto",
      bool useCache = false,
      bool shareMedia = false,
      String mediaToken = ""}) async {
    try {
      return await _channel.invokeMethod<bool>('startRpcWorker', {
            'port': port,
            'device': device,
            'useCache': useCache,
            'shareMedia': shareMedia,
            'mediaToken': mediaToken,
          }) ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> stopRpcWorker() async {
    try {
      return await _channel.invokeMethod<bool>('stopRpcWorker') ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> updateAssistantPanelState(String label, bool busy) async {
    try {
      await _channel.invokeMethod<void>('updateAssistantPanelState', {
        'label': label,
        'busy': busy,
      });
    } on PlatformException {
      // The in-app assistant has no system VoiceInteractionSession panel.
    }
  }

  static Future<Map<String, dynamic>> getRpcWorkerStatus() async {
    try {
      return await _channel
              .invokeMapMethod<String, dynamic>('getRpcWorkerStatus') ??
          <String, dynamic>{'running': false};
    } on PlatformException {
      return <String, dynamic>{'running': false};
    }
  }

  static Future<Map<String, dynamic>> getComputeCapabilities() async {
    try {
      return await _channel
              .invokeMapMethod<String, dynamic>('getComputeCapabilities') ??
          <String, dynamic>{};
    } on PlatformException {
      return <String, dynamic>{
        'cpu': true,
        'gpu': false,
        'npuDetected': false,
        'npuBackend': false,
        'rpcBackend': false,
      };
    }
  }

  static Future<Map<String, dynamic>> getClusterHostInfo() async {
    try {
      return await _channel
              .invokeMapMethod<String, dynamic>('getClusterHostInfo') ??
          <String, dynamic>{};
    } on PlatformException {
      return <String, dynamic>{};
    }
  }

  static Future<Map<String, dynamic>> getMemoryInfo() async {
    try {
      return await _channel.invokeMapMethod<String, dynamic>('getMemoryInfo') ??
          <String, dynamic>{};
    } on PlatformException {
      return <String, dynamic>{};
    }
  }

  static Future<bool> stopServer() async {
    try {
      final bool result = await _channel.invokeMethod('stopServer');
      return result;
    } on PlatformException catch (e) {
      print("Failed to stop server: '${e.message}'.");
      return false;
    }
  }

  static Future<bool> setKeepScreenOn(bool enabled) async {
    try {
      final bool result =
          await _channel.invokeMethod('setKeepScreenOn', {'enabled': enabled});
      return result;
    } on PlatformException catch (e) {
      print("Failed to update screen wake state: '${e.message}'.");
      return false;
    }
  }

  static void setAssistantEventHandler(
      Future<void> Function(String method, dynamic arguments) handler) {
    _channel
        .setMethodCallHandler((call) => handler(call.method, call.arguments));
  }

  static Future<bool> consumeInitialAssistantInvocation() async {
    try {
      return await _channel
              .invokeMethod<bool>("getInitialAssistantInvocation") ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<String?> consumeAssistantScreenshot() async {
    try {
      return await _channel.invokeMethod<String>("consumeAssistantScreenshot");
    } on PlatformException {
      return null;
    }
  }

  static Future<bool> requestAssistantCameraPermission() async {
    try {
      return await _channel
              .invokeMethod<bool>("requestAssistantCameraPermission") ??
          false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> setAssistantVoiceSessionState(
      {required bool active}) async {
    try {
      await _channel
          .invokeMethod("setAssistantVoiceSessionActive", {"active": active});
    } on PlatformException {
      // Ignore: the overlay may not be running.
    }
  }

  static Future<bool> isAssistantActive() async {
    try {
      return await _channel.invokeMethod<bool>("isAssistantActive") ?? false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> finishAssistantOverlay() async {
    await _channel.invokeMethod("finishAssistantOverlay");
  }

  static Future<Map<String, dynamic>> recognizeAssistantSpeech(
      {String? language,
      bool onDevice = true,
      int silenceMillis = 1200}) async {
    final result = await _channel
            .invokeMapMethod<String, dynamic>("recognizeAssistantSpeech", {
          "language": language,
          "onDevice": onDevice,
          "silenceMillis": silenceMillis,
        }) ??
        <String, dynamic>{};
    return result;
  }

  static Future<bool> speakAssistantText(String text,
      {String? language}) async {
    return await _channel.invokeMethod<bool>(
            "speakAssistantText", {"text": text, "language": language}) ??
        false;
  }

  static Future<void> stopAssistantAudio() async {
    await _channel.invokeMethod("stopAssistantAudio");
  }

  static Future<bool> isOnDeviceSpeechRecognitionAvailable() async {
    return await _channel
            .invokeMethod<bool>("isOnDeviceSpeechRecognitionAvailable") ??
        false;
  }

  static Future<void> openAssistantSettings() async {
    await _channel.invokeMethod("openAssistantSettings");
  }

  static Future<Map<String, dynamic>> executeAssistantAction(
      String action, Map<String, dynamic> arguments) async {
    return await _channel
            .invokeMapMethod<String, dynamic>("executeAssistantAction", {
          "action": action,
          "arguments": arguments,
        }) ??
        <String, dynamic>{"ok": false, "error": "Sin respuesta de Android"};
  }

  static Future<bool> playAssistantAudio(String path) async {
    return await _channel
            .invokeMethod<bool>("playAssistantAudio", {"path": path}) ??
        false;
  }

  static Future<List<String>> extractVideoFrames(String path,
      {int count = 3}) async {
    try {
      final result = await _channel.invokeListMethod<String>(
          'extractVideoFrames', {'path': path, 'count': count});
      return result ?? <String>[];
    } on PlatformException catch (e) {
      print("Failed to extract video frames: '${e.message}'.");
      return <String>[];
    }
  }

  static Future<Map<String, dynamic>> processPdf(String path,
      {bool renderPages = false, int maxPages = 6}) async {
    try {
      return await _channel.invokeMapMethod<String, dynamic>('processPdf', {
            'path': path,
            'renderPages': renderPages,
            'maxPages': maxPages,
          }) ??
          <String, dynamic>{};
    } on PlatformException catch (error) {
      return <String, dynamic>{
        'error': error.message ?? error.code,
        'images': <String>[],
        'text': '',
      };
    }
  }

  static Future<Map<String, dynamic>> processDocument(String path) async {
    try {
      return await _channel.invokeMapMethod<String, dynamic>(
              'processDocument', {'path': path}) ??
          <String, dynamic>{};
    } on PlatformException catch (error) {
      return <String, dynamic>{
        'error': error.message ?? error.code,
        'text': '',
      };
    }
  }
}
