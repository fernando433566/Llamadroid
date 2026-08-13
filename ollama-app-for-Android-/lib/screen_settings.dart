import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main.dart';
import 'screen_assistant.dart';
import 'assistant_tools.dart';
import 'cluster_devices.dart';
import 'server_controller.dart';
import 'worker_update.dart';
import 'package:ollama_app/worker_setter.dart';
import 'package:ollama_app/l10n/app_localizations.dart';

import 'package:dartx/dartx.dart';
import 'package:http/http.dart' as http;
import 'package:simple_icons/simple_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:restart_app/restart_app.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:version/version.dart';
import 'package:bitsdojo_window/bitsdojo_window.dart';

class ScreenSettings extends StatefulWidget {
  const ScreenSettings({super.key});

  @override
  State<ScreenSettings> createState() => _ScreenSettingsState();
}

class _ScreenSettingsState extends State<ScreenSettings> {
  final hostInputController = TextEditingController(
    text: (useHost)
        ? fixedHost
        : (prefs?.getString("externalHost") ??
            prefs?.getString("host") ??
            "http://192.168.1.2:11434"),
  );
  late final TextEditingController cloudApiKeyController =
      TextEditingController(text: cloudApiKey ?? "");
  late final TextEditingController maxLoadedModelsController =
      TextEditingController(
          text: (prefs?.getInt("maxLoadedModels") ?? 1).toString());
  late final TextEditingController groundingMaxLinksController =
      TextEditingController(
          text: (prefs?.getInt("groundingMaxLinks") ?? 3).toString());
  late final TextEditingController documentRagMaxChunksController =
      TextEditingController(
          text: (prefs?.getInt("documentRagMaxChunks") ?? 8).toString());
  late final TextEditingController groundingPreferredDomainsController =
      TextEditingController(
          text: prefs?.getString("groundingPreferredDomains") ?? "");
  late final TextEditingController groundingAllowedDomainsController =
      TextEditingController(
          text: prefs?.getString("groundingAllowedDomains") ?? "");
  late final TextEditingController groundingBlockedDomainsController =
      TextEditingController(
          text: prefs?.getString("groundingBlockedDomains") ?? "");
  late final TextEditingController rpcServersController =
      TextEditingController(text: prefs?.getString("rpcServers") ?? "");
  late final TextEditingController rpcWorkerPortController =
      TextEditingController(
          text: (prefs?.getInt("rpcWorkerPort") ?? 50052).toString());
  Map<String, dynamic> computeCapabilities = const <String, dynamic>{};
  Map<String, dynamic> rpcWorkerStatus = const <String, dynamic>{};
  Map<String, dynamic> clusterHostInfo = const <String, dynamic>{};
  List<ClusterWorkerDevice> clusterWorkers = const <ClusterWorkerDevice>[];
  bool clusterWorkersLoading = false;
  bool computeCapabilitiesLoading = false;
  bool hostLoading = false;
  bool hostInvalidUrl = false;
  bool hostInvalidHost = false;

  String _rpcWorkerMediaToken() {
    final stored = prefs?.getString('rpcWorkerMediaToken') ?? '';
    if (stored.length >= 8) return stored;
    const alphabet =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
    final random = Random.secure();
    final generated =
        List.generate(16, (_) => alphabet[random.nextInt(alphabet.length)])
            .join();
    unawaited(prefs?.setString('rpcWorkerMediaToken', generated));
    return generated;
  }

  Future<bool> checkHost() async {
    setState(() {
      hostLoading = true;
      hostInvalidUrl = false;
      hostInvalidHost = false;
    });
    var tmpHost = hostInputController.text.trim().removeSuffix("/").trim();

    if (tmpHost.isEmpty || !Uri.parse(tmpHost).isAbsolute) {
      setState(() {
        hostInvalidUrl = true;
        hostLoading = false;
      });
      return false;
    }

    http.Response request;
    try {
      request = await http
          .get(
        Uri.parse(tmpHost),
        headers: (jsonDecode(prefs!.getString("hostHeaders") ?? "{}") as Map)
            .cast<String, String>(),
      )
          .timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          return http.Response("Error", 408);
        },
      );
    } catch (e) {
      setState(() {
        hostInvalidHost = true;
        hostLoading = false;
      });
      return false;
    }
    if ((request.statusCode == 200 && request.body == "Ollama is running") ||
        (Uri.parse(tmpHost).toString() == fixedHost)) {
      setState(() {
        hostLoading = false;
        host = tmpHost;
        if (hostInputController.text != host!) {
          hostInputController.text = host!;
        }
      });
      await prefs?.setString("externalHost", host!);
      await prefs?.setString("host", host!);
      return true;
    } else {
      setState(() {
        hostInvalidHost = true;
        hostLoading = false;
      });
    }
    HapticFeedback.selectionClick();
    return false;
  }

  Future<void> _selectConnectionMode(String mode) async {
    if (mode == connectionModeLocal && !Platform.isAndroid) return;
    HapticFeedback.selectionClick();
    setState(() {
      activeConnectionMode = mode;
      hostInvalidHost = false;
      hostInvalidUrl = false;
    });
    await prefs?.setString("connectionMode", mode);

    if (mode == connectionModeLocal) {
      host = localOllamaHost;
      await prefs?.setString("host", localOllamaHost);
      final started = await startConfiguredLocalServer();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(started
            ? "Ollama local iniciado en $localOllamaHost"
            : "No se pudo iniciar Ollama local"),
      ));
      return;
    }

    if (mode == connectionModeCloud) {
      host = ollamaCloudHost;
      await prefs?.setString("host", ollamaCloudHost);
      return;
    }

    host = hostInputController.text.trim().removeSuffix("/").trim();
    if (host!.isNotEmpty) await prefs?.setString("host", host!);
  }

  Future<void> _saveCloudApiKey() async {
    final key = cloudApiKeyController.text.trim();
    cloudApiKey = key;
    if (key.isEmpty) {
      await secureStorage.delete(key: cloudApiKeyStorageKey);
    } else {
      await secureStorage.write(key: cloudApiKeyStorageKey, value: key);
    }
    if (!mounted) return;
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text(key.isEmpty ? "Clave eliminada" : "Clave guardada")),
    );
  }

  Future<void> _applyLocalServerSettings() async {
    if (!Platform.isAndroid || activeConnectionMode != connectionModeLocal) {
      return;
    }
    await startConfiguredLocalServer();
  }

  Future<void> _setAdvancedBool(String key, bool value,
      {bool restartServer = false}) async {
    HapticFeedback.selectionClick();
    await prefs?.setBool(key, value);
    if (mounted) setState(() {});
    if (restartServer) await _applyLocalServerSettings();
  }

  bool _domainRuleEnabled(String domainsKey, String enabledKey) {
    final source = prefs?.getString(domainsKey) ?? "";
    return prefs?.getBool(enabledKey) ?? source.trim().isNotEmpty;
  }

  Future<bool> _saveDomainSettings() async {
    final invalidDomains = <String>{
      ...invalidWebDomainTokens(groundingAllowedDomainsController.text),
      ...invalidWebDomainTokens(groundingPreferredDomainsController.text),
      ...invalidWebDomainTokens(groundingBlockedDomainsController.text),
    };
    if (invalidDomains.isNotEmpty) {
      if (!mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text("Dominios no válidos: ${invalidDomains.take(3).join(', ')}"),
      ));
      return false;
    }
    final allowedDomains =
        parseWebDomainList(groundingAllowedDomainsController.text);
    final preferredDomains =
        parseWebDomainList(groundingPreferredDomainsController.text);
    final blockedDomains =
        parseWebDomainList(groundingBlockedDomainsController.text);
    groundingAllowedDomainsController.text = allowedDomains.join('\n');
    groundingPreferredDomainsController.text = preferredDomains.join('\n');
    groundingBlockedDomainsController.text = blockedDomains.join('\n');
    await prefs?.setString(
        "groundingAllowedDomains", groundingAllowedDomainsController.text);
    await prefs?.setString(
        "groundingPreferredDomains", groundingPreferredDomainsController.text);
    await prefs?.setString(
        "groundingBlockedDomains", groundingBlockedDomainsController.text);
    return true;
  }

  Future<void> _saveAdvancedTextSettings() async {
    final maxLoaded = int.tryParse(maxLoadedModelsController.text.trim());
    if (maxLoaded == null || maxLoaded == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            "El límite debe ser mayor que 0 o un número negativo para ilimitado."),
      ));
      return;
    }
    final groundingMaxLinks =
        int.tryParse(groundingMaxLinksController.text.trim());
    if (groundingMaxLinks == null || groundingMaxLinks == 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text(
            "El máximo de enlaces debe ser mayor que 0 o negativo para ilimitado."),
      ));
      return;
    }
    final ragChunks = int.tryParse(documentRagMaxChunksController.text.trim());
    if (ragChunks == null || ragChunks < 1 || ragChunks > 32) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("RAG fragments must be between 1 and 32."),
      ));
      return;
    }
    if (!await _saveDomainSettings()) return;
    await prefs?.setInt("maxLoadedModels", maxLoaded);
    await prefs?.setInt("groundingMaxLinks", groundingMaxLinks);
    await prefs?.setInt("documentRagMaxChunks", ragChunks);
    final endpoints = parseClusterRpcEndpoints(rpcServersController.text);
    if (rpcServersController.text.trim().isNotEmpty && endpoints.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Introduce workers con formato IP:puerto."),
      ));
      return;
    }
    rpcServersController.text = endpoints.join(',');
    await prefs?.setString("rpcServers", rpcServersController.text);
    await _refreshClusterWorkers();
    await _applyLocalServerSettings();
    if (!mounted) return;
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Opciones avanzadas guardadas")),
    );
    setState(() {});
  }

  Future<void> _refreshAdvancedHardware() async {
    if (!Platform.isAndroid) return;
    if (mounted) setState(() => computeCapabilitiesLoading = true);
    final results = await Future.wait<dynamic>([
      ServerController.getComputeCapabilities(),
      ServerController.getRpcWorkerStatus(),
      ServerController.getClusterHostInfo(),
    ]);
    if (!mounted) return;
    setState(() {
      computeCapabilities = Map<String, dynamic>.from(results[0] as Map);
      rpcWorkerStatus = Map<String, dynamic>.from(results[1] as Map);
      clusterHostInfo = Map<String, dynamic>.from(results[2] as Map);
      computeCapabilitiesLoading = false;
    });
    await _refreshClusterWorkers();
  }

  Map<String, ClusterWorkerProfile> _clusterProfiles() =>
      decodeClusterWorkerProfiles(prefs?.getString("rpcWorkerProfiles"));

  Future<void> _saveClusterProfiles(
      Map<String, ClusterWorkerProfile> profiles) async {
    await prefs?.setString(
        "rpcWorkerProfiles", encodeClusterWorkerProfiles(profiles));
  }

  Future<void> _refreshClusterWorkers() async {
    final endpoints = parseClusterRpcEndpoints(rpcServersController.text);
    if (endpoints.isEmpty) {
      if (mounted) setState(() => clusterWorkers = const []);
      return;
    }
    if (mounted) setState(() => clusterWorkersLoading = true);
    final profiles = _clusterProfiles();
    const discovery = ClusterWorkerDiscovery();
    final devices = await Future.wait(endpoints.map(
        (endpoint) => discovery.probe(clusterProfileFor(endpoint, profiles))));
    for (final device in devices) {
      profiles[device.profile.endpoint] = device.profile;
    }
    await _saveClusterProfiles(profiles);
    if (!mounted) return;
    setState(() {
      clusterWorkers = devices;
      clusterWorkersLoading = false;
    });
  }

  Future<void> _startRpcWorker() async {
    final port = int.tryParse(rpcWorkerPortController.text.trim());
    if (port == null || port < 1 || port > 65534) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("El puerto RPC no es válido.")));
      return;
    }
    final device = prefs?.getString("rpcWorkerDevice") ?? "auto";
    await prefs?.setInt("rpcWorkerPort", port);
    final started = await ServerController.startRpcWorker(
        port: port,
        device: device,
        useCache: prefs?.getBool("rpcWorkerCache") ?? false,
        shareMedia: prefs?.getBool('rpcWorkerShareMedia') ?? false,
        mediaToken: _rpcWorkerMediaToken());
    await Future<void>.delayed(const Duration(milliseconds: 700));
    await _refreshAdvancedHardware();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(started
          ? "Worker RPC iniciado en 0.0.0.0:$port"
          : "No se pudo iniciar el worker RPC"),
    ));
  }

  Future<void> _stopRpcWorker() async {
    await ServerController.stopRpcWorker();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await _refreshAdvancedHardware();
  }

  final systemInputController = TextEditingController(
    text: prefs?.getString("system") ?? "You are a helpful assistant",
  );

  @override
  void initState() {
    super.initState();
    WidgetsFlutterBinding.ensureInitialized();

    if (activeConnectionMode == connectionModeExternal) checkHost();
    updateStatus = "notAvailable";
    prefs?.setBool("checkUpdateOnSettingsOpen", false);
    unawaited(_refreshAdvancedHardware());
  }

  @override
  void dispose() {
    super.dispose();
    hostInputController.dispose();
    cloudApiKeyController.dispose();
    maxLoadedModelsController.dispose();
    groundingMaxLinksController.dispose();
    documentRagMaxChunksController.dispose();
    groundingAllowedDomainsController.dispose();
    groundingPreferredDomainsController.dispose();
    groundingBlockedDomainsController.dispose();
    rpcServersController.dispose();
    rpcWorkerPortController.dispose();
  }

  String _npuDisplayName() {
    final soc = (computeCapabilities["soc"] ?? "").toString().trim();
    final identity = soc.toLowerCase();
    if (identity.contains("qualcomm") ||
        identity.contains("snapdragon") ||
        RegExp(r"\bsm\d{4}\b").hasMatch(identity)) {
      return soc.isEmpty
          ? "Qualcomm Hexagon NPU (HTP)"
          : "$soc · Hexagon NPU (HTP)";
    }
    if (identity.contains("tensor")) {
      return soc.isEmpty ? "Google Tensor TPU" : "$soc · Tensor TPU";
    }
    if (identity.contains("exynos")) {
      return soc.isEmpty ? "Samsung NPU" : "$soc · Samsung NPU";
    }
    if (identity.contains("mediatek") || identity.contains("dimensity")) {
      return soc.isEmpty ? "MediaTek APU" : "$soc · MediaTek APU";
    }
    if (identity.contains("kirin")) {
      return soc.isEmpty ? "Kirin Da Vinci NPU" : "$soc · Da Vinci NPU";
    }
    return soc.isEmpty ? "NPU no identificada" : "$soc · NPU no identificada";
  }

  Widget _hardwareStatusCard({
    required Key key,
    required String title,
    required String deviceName,
    required bool detected,
    required bool supported,
    required String supportedDetails,
    required String unsupportedDetails,
  }) {
    final IconData icon;
    final String status;
    if (supported) {
      icon = Icons.check_circle_outline_rounded;
      status = appText("Supported", "Compatible");
    } else if (detected) {
      icon = Icons.error_outline_rounded;
      status = appText("Unsupported", "No compatible");
    } else {
      icon = Icons.cancel_outlined;
      status = appText("Not detected", "No detectado");
    }
    final details = supported ? supportedDetails : unsupportedDetails;
    return ListTile(
      key: key,
      dense: true,
      visualDensity: VisualDensity.compact,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      minLeadingWidth: 24,
      leading: Icon(
        icon,
        size: 20,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      title: Text("$title · $status", maxLines: 1),
      subtitle: Text(
        "$deviceName · $details",
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _hardwareCompatibilityCards() {
    if (!Platform.isAndroid) return const SizedBox.shrink();
    if (computeCapabilitiesLoading && computeCapabilities.isEmpty) {
      return ListTile(
        dense: true,
        leading: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        title: Text(appText("Detecting GPU and NPU…", "Detectando GPU y NPU…")),
      );
    }
    final gpuName =
        (computeCapabilities["gpuRenderer"] ?? "GPU no identificada")
            .toString();
    final gpuDetected =
        gpuName.trim().isNotEmpty && gpuName.toLowerCase() != "no identificado";
    final gpuSupported = computeCapabilities["gpu"] == true;
    final npuDetected = computeCapabilities["npuDetected"] == true;
    final npuSupported = computeCapabilities["npuBackend"] == true;
    final npuReason = (computeCapabilities["htpReason"] ??
            "No hay un backend NPU compatible disponible.")
        .toString();
    return Column(children: [
      Row(children: [
        Expanded(
          child: Text(
              appText("Device acceleration", "Aceleración del dispositivo"),
              style: Theme.of(context).textTheme.titleMedium),
        ),
        IconButton(
          key: const ValueKey("hardware-refresh"),
          tooltip: appText("Detect again", "Volver a detectar"),
          onPressed:
              computeCapabilitiesLoading ? null : _refreshAdvancedHardware,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ]),
      _hardwareStatusCard(
        key: const ValueKey("hardware-gpu-status"),
        title: "GPU",
        deviceName: gpuName,
        detected: gpuDetected || gpuSupported,
        supported: gpuSupported,
        supportedDetails: appText("Vulkan available", "Vulkan disponible"),
        unsupportedDetails: gpuDetected
            ? appText("Vulkan unavailable", "Vulkan no disponible")
            : appText("No compatible GPU was detected",
                "No se ha detectado una GPU compatible"),
      ),
      const Divider(height: 1, indent: 40),
      _hardwareStatusCard(
        key: const ValueKey("hardware-npu-status"),
        title: "NPU",
        deviceName: _npuDisplayName(),
        detected: npuDetected,
        supported: npuSupported,
        supportedDetails:
            appText("HTP backend available", "Backend HTP disponible"),
        unsupportedDetails: npuDetected
            ? npuReason
            : appText("No compatible NPU was detected",
                "No se ha detectado una NPU compatible"),
      ),
    ]);
  }

  IconData _clusterDeviceIcon(String kind) => switch (kind) {
        'phone' => Icons.phone_android_rounded,
        'tablet' => Icons.tablet_android_rounded,
        'desktop' => Icons.computer_rounded,
        _ => Icons.dns_rounded,
      };

  Set<String> _entitiesFromMetadata(Map<String, dynamic> metadata) {
    final raw = metadata['entities'];
    if (raw is! Map) return const <String>{clusterEntityCompute};
    final entities = <String>{clusterEntityCompute};
    final values = Map<String, dynamic>.from(raw);
    for (final entity in const <String>{
      clusterEntityCameraFront,
      clusterEntityCameraRear,
      clusterEntityMicrophone,
      clusterEntityScreen,
    }) {
      if (values[entity] == true) entities.add(entity);
    }
    return entities;
  }

  String _clusterEntityLabel(String entity) => switch (entity) {
        clusterEntityCompute => appText('Model compute', 'Cómputo del modelo'),
        clusterEntityCameraFront => appText('Front camera', 'Cámara frontal'),
        clusterEntityCameraRear => appText('Rear camera', 'Cámara trasera'),
        clusterEntityMicrophone => appText('Microphone', 'Micrófono'),
        clusterEntityScreen => appText('Screen', 'Pantalla'),
        _ => entity,
      };

  IconData _clusterEntityIcon(String entity) => switch (entity) {
        clusterEntityCompute => Icons.memory_rounded,
        clusterEntityCameraFront => Icons.camera_front_rounded,
        clusterEntityCameraRear => Icons.photo_camera_back_rounded,
        clusterEntityMicrophone => Icons.mic_rounded,
        clusterEntityScreen => Icons.screenshot_monitor_rounded,
        _ => Icons.extension_rounded,
      };

  Future<void> _showClusterDeviceSettings({
    ClusterWorkerDevice? worker,
    bool hostDevice = false,
  }) async {
    final profile = worker?.profile;
    final key = hostDevice ? 'host' : profile!.endpoint;
    final advertised = hostDevice
        ? _entitiesFromMetadata(clusterHostInfo)
        : profile!.advertisedEntities;
    var enabled = hostDevice
        ? (prefs?.getStringList('clusterHostEntities')?.toSet() ?? advertised)
        : profile!.enabledEntities.toSet();
    var target = prefs?.getString('clusterMultimodalTarget') ?? 'host';
    var routeProjectorHere = target == key;
    var modalities = (prefs?.getStringList('clusterMandatoryModalities') ??
            const <String>[clusterModalityAudio, clusterModalityVision])
        .toSet();
    var hostBackend =
        prefs?.getString('clusterHostMultimodalDevice') ?? 'LOCAL_GPU';
    final mediaTokenController =
        TextEditingController(text: profile?.mediaToken ?? '');
    if ((hostBackend == 'LOCAL_GPU' && computeCapabilities['gpu'] != true) ||
        (hostBackend == 'LOCAL_NPU' &&
            computeCapabilities['npuBackend'] != true)) {
      hostBackend = 'LOCAL_CPU';
    }
    final preciseRemoteRouting = hostDevice ||
        (profile!.managedByOllama && profile.singleDeviceGuaranteed);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) => AlertDialog(
          title: Text(hostDevice
              ? (clusterHostInfo['name']?.toString() ?? 'Este dispositivo')
              : (profile!.name?.isNotEmpty == true
                  ? profile.name!
                  : profile.endpoint)),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hostDevice
                        ? 'Host del cluster · ${clusterHostInfo['model'] ?? 'Android'}'
                        : '${profile!.endpoint} · ${profile.computeDevice ?? 'procesador no anunciado'}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Text('Entidades autorizadas',
                      style: Theme.of(context).textTheme.titleSmall),
                  if (!hostDevice)
                    Padding(
                      padding: EdgeInsets.only(top: 4, bottom: 4),
                      child: Text(
                        profile!.remoteMediaAvailable
                            ? 'Este worker puede capturar su cámara y micrófono para el host autenticado. La pantalla requiere autorización MediaProjection en el propio worker.'
                            : 'Activa Compartir cámara y micrófono en este worker para que sus sensores acompañen al proyector multimodal.',
                      ),
                    ),
                  for (final entity in const <String>[
                    clusterEntityCompute,
                    clusterEntityCameraFront,
                    clusterEntityCameraRear,
                    clusterEntityMicrophone,
                    clusterEntityScreen,
                  ])
                    if (advertised.contains(entity) &&
                        !(hostDevice && entity == clusterEntityCompute))
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        secondary: Icon(_clusterEntityIcon(entity), size: 20),
                        title: Text(_clusterEntityLabel(entity)),
                        value: enabled.contains(entity),
                        onChanged: (value) => updateDialog(() {
                          if (value) {
                            enabled.add(entity);
                          } else {
                            enabled.remove(entity);
                          }
                        }),
                      ),
                  if (!hostDevice && profile!.remoteMediaAvailable) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: mediaTokenController,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Clave multimedia del worker',
                        helperText:
                            'Cópiala desde Advanced options del dispositivo worker.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  if (hostDevice)
                    const ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.hub_rounded, size: 20),
                      title: Text('Coordinación y cómputo base'),
                      subtitle: Text(
                          'El host coordina el cluster y conserva el fallback CPU.'),
                    ),
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Fijar el proyector multimodal aquí'),
                    subtitle: Text(preciseRemoteRouting
                        ? 'Obliga a libmtmd a procesar audio nativo y visión en este dispositivo.'
                        : 'Selecciona un procesador explícito al iniciar este worker para poder identificar un único dispositivo RPC.'),
                    value: routeProjectorHere,
                    onChanged: preciseRemoteRouting
                        ? (value) => updateDialog(() {
                              routeProjectorHere = value;
                              target = value ? key : '';
                            })
                        : null,
                  ),
                  if (routeProjectorHere) ...[
                    if (hostDevice)
                      DropdownButtonFormField<String>(
                        initialValue: hostBackend,
                        decoration: const InputDecoration(
                          labelText: 'Procesador local para el proyector',
                          border: OutlineInputBorder(),
                        ),
                        items: [
                          const DropdownMenuItem(
                              value: 'LOCAL_CPU', child: Text('CPU')),
                          if (computeCapabilities['gpu'] == true)
                            const DropdownMenuItem(
                                value: 'LOCAL_GPU', child: Text('GPU')),
                          if (computeCapabilities['npuBackend'] == true)
                            const DropdownMenuItem(
                                value: 'LOCAL_NPU', child: Text('NPU')),
                        ],
                        onChanged: (value) => updateDialog(
                            () => hostBackend = value ?? 'LOCAL_CPU'),
                      ),
                    const SizedBox(height: 12),
                    Text('Capas que deben permanecer aquí',
                        style: Theme.of(context).textTheme.titleSmall),
                    Wrap(spacing: 8, children: [
                      FilterChip(
                        label: const Text('Audio nativo'),
                        avatar: const Icon(Icons.graphic_eq_rounded, size: 18),
                        selected: modalities.contains(clusterModalityAudio),
                        onSelected: (value) => updateDialog(() => value
                            ? modalities.add(clusterModalityAudio)
                            : modalities.remove(clusterModalityAudio)),
                      ),
                      FilterChip(
                        label: const Text('Visión'),
                        avatar: const Icon(Icons.visibility_rounded, size: 18),
                        selected: modalities.contains(clusterModalityVision),
                        onSelected: (value) => updateDialog(() => value
                            ? modalities.add(clusterModalityVision)
                            : modalities.remove(clusterModalityVision)),
                      ),
                    ]),
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'libmtmd usa un único proyector compartido: si el modelo combina audio y visión, ambas rutas se ejecutarán en este mismo dispositivo.',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              onPressed: () async {
                if (hostDevice) {
                  await prefs?.setStringList(
                      'clusterHostEntities', enabled.toList()..sort());
                  await prefs?.setString(
                      'clusterHostMultimodalDevice', hostBackend);
                } else {
                  final profiles = _clusterProfiles();
                  profiles[key] = profile!.copyWith(
                    enabledEntities: enabled,
                    mediaToken: mediaTokenController.text.trim(),
                  );
                  await _saveClusterProfiles(profiles);
                }
                if (routeProjectorHere) {
                  await prefs?.setString('clusterMultimodalTarget', key);
                  await prefs?.setStringList('clusterMandatoryModalities',
                      modalities.toList()..sort());
                } else if ((prefs?.getString('clusterMultimodalTarget') ??
                        'host') ==
                    key) {
                  await prefs?.setString('clusterMultimodalTarget', '');
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
                await _refreshClusterWorkers();
                await _applyLocalServerSettings();
              },
              child: const Text('Guardar'),
            ),
          ],
        ),
      ),
    );
    mediaTokenController.dispose();
  }

  Widget _clusterDeviceList() {
    final hostName = clusterHostInfo['name']?.toString() ?? 'Este dispositivo';
    final hostKind = clusterHostInfo['type']?.toString() ?? 'phone';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(children: [
        ListTile(
          key: const ValueKey('cluster-host-device'),
          leading: Icon(_clusterDeviceIcon(hostKind)),
          title: Text(hostName),
          subtitle: Text(
              'Host · ${clusterHostInfo['model'] ?? 'Android'} · coordinador'),
          trailing: IconButton(
            tooltip: 'Configurar host',
            onPressed: () => _showClusterDeviceSettings(hostDevice: true),
            icon: const Icon(Icons.tune_rounded),
          ),
        ),
        if (clusterWorkersLoading) const LinearProgressIndicator(),
        for (final worker in clusterWorkers)
          ListTile(
            key: ValueKey('cluster-worker-${worker.profile.endpoint}'),
            leading: Icon(_clusterDeviceIcon(worker.profile.kind)),
            title: Text(worker.profile.name?.isNotEmpty == true
                ? worker.profile.name!
                : worker.profile.endpoint),
            subtitle: Text(
              '${worker.profile.endpoint} · ${worker.online ? 'conectado' : 'sin conexión'}'
              '${worker.controlPlaneAvailable ? ' · Ollama Android' : ' · sin metadatos'}',
              maxLines: 2,
            ),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(worker.online
                  ? Icons.check_circle_outline_rounded
                  : Icons.error_outline_rounded),
              IconButton(
                tooltip: 'Configurar dispositivo',
                onPressed: () => _showClusterDeviceSettings(worker: worker),
                icon: const Icon(Icons.tune_rounded),
              ),
            ]),
          ),
        if (!clusterWorkersLoading && clusterWorkers.isEmpty)
          const ListTile(
            leading: Icon(Icons.devices_other_rounded),
            title: Text('No hay workers configurados'),
            subtitle: Text('Añade al menos una dirección IP:puerto.'),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: clusterWorkersLoading ? null : _refreshClusterWorkers,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Detectar dispositivos'),
          ),
        ),
      ]),
    );
  }

  Widget _advancedOptionsCard() {
    final extraModes = extraComputeModesEnabled();
    final computeMode = configuredComputeMode();
    final forcedDevice = configuredForcedDevice();
    final synergyGpu = (prefs?.getInt("synergyGpuPercent") ?? 50).clamp(0, 100);
    final npuBackend = computeCapabilities["npuBackend"] == true;
    final npuDetected = computeCapabilities["npuDetected"] == true;
    final synergyNpuEnabled =
        (prefs?.getBool("synergyNpuEnabled") ?? false) && npuBackend;
    final synergyCpu = (prefs?.getInt("synergyCpuPercent") ??
            (synergyNpuEnabled
                ? (100 - synergyGpu - (prefs?.getInt("synergyNpuPercent") ?? 0))
                : 100 - synergyGpu))
        .clamp(0, 100 - synergyGpu);
    final synergyNpu =
        synergyNpuEnabled ? (100 - synergyCpu - synergyGpu).clamp(0, 100) : 0;
    final clustering = prefs?.getBool("rpcClusteringEnabled") ?? false;
    final multimodalDivision =
        prefs?.getBool("clusterMultimodalDivision") ?? false;
    final workerRunning = rpcWorkerStatus["running"] == true;
    final rpcWorkerDevice = prefs?.getString("rpcWorkerDevice") ?? "auto";
    final rpcWorkerShareMedia = prefs?.getBool('rpcWorkerShareMedia') ?? false;
    final rpcWorkerMediaToken = _rpcWorkerMediaToken();
    final assistantKeepsModelsLoaded = assistantForcesBackgroundRetention();

    return Card(
      key: const ValueKey("advanced-options-menu"),
      margin: const EdgeInsets.only(top: 20),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: const Icon(Icons.tune_rounded),
        title: Text(appText("Advanced options", "Opciones avanzadas")),
        subtitle: Text(appText(
            "Local server, GGUF models and experimental compute",
            "Servidor local, modelos GGUF y cálculo experimental")),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
        children: [
          SwitchListTile(
            key: const ValueKey("advanced-expose-lan"),
            secondary: const Icon(Icons.lan_rounded),
            title: Text(appText("Expose Ollama to the local network",
                "Exponer Ollama en la red local")),
            subtitle: Text(
              prefs?.getBool("exposeLocalServerToLan") ?? false
                  ? appText(
                      "Listening on 0.0.0.0:11434. Use trusted networks only.",
                      "Escucha en 0.0.0.0:11434. Usa solo redes de confianza.")
                  : appText("Ollama remains on 127.0.0.1:11434.",
                      "Ollama permanece en 127.0.0.1:11434."),
            ),
            value: prefs?.getBool("exposeLocalServerToLan") ?? false,
            onChanged: (value) => _setAdvancedBool(
              "exposeLocalServerToLan",
              value,
              restartServer: true,
            ),
          ),
          SwitchListTile(
            key: const ValueKey("advanced-enable-gguf"),
            secondary: const Icon(Icons.inventory_2_outlined),
            title: Text(appText("Enable GGUF Models", "Activar modelos GGUF")),
            subtitle: Text(appText("Shows .gguf model import in Add model.",
                "Muestra la importación de modelos .gguf en Añadir modelo.")),
            value: prefs?.getBool("enableGgufModels") ?? false,
            onChanged: (value) => _setAdvancedBool("enableGgufModels", value),
          ),
          SwitchListTile(
            key: const ValueKey("advanced-embedded-audio"),
            secondary: const Icon(Icons.graphic_eq_rounded),
            title: Text(appText("Embedded audio", "Audio integrado")),
            subtitle: Text(appText(
                "Allows models to receive audio directly without STT. Using Embedded audio disables automatic device actions, relying only on model tool use.",
                "Permite que los modelos reciban audio directamente sin STT. El audio integrado desactiva las acciones automáticas del dispositivo y depende de las herramientas del modelo.")),
            value: prefs?.getBool("enableEmbeddedAudioModels") ?? false,
            onChanged: (value) =>
                _setAdvancedBool("enableEmbeddedAudioModels", value),
          ),
          SwitchListTile(
            key: const ValueKey("advanced-keep-models-loaded-background"),
            secondary: const Icon(Icons.memory_rounded),
            title: Text(appText("Keep models loaded in RAM",
                "Mantener modelos cargados en RAM")),
            subtitle: Text(
              assistantKeepsModelsLoaded
                  ? appText(
                      "Enabled automatically while Assistant capabilities are active.",
                      "Se activa automáticamente mientras haya funciones del asistente activas.")
                  : (prefs?.getBool("keepModelLoadedInBackground") ?? false)
                      ? appText(
                          "Models remain loaded when the app enters the background. This uses more RAM and battery.",
                          "Los modelos permanecen cargados al poner la app en segundo plano. Esto consume más RAM y batería.")
                      : appText(
                          "Unload local models from RAM when the app enters the background.",
                          "Descarga los modelos locales de la RAM al poner la app en segundo plano."),
            ),
            value: keepModelsLoadedInBackground(),
            onChanged: (value) async {
              if (shouldWarnBeforeDisablingBackgroundRetention(value)) {
                HapticFeedback.mediumImpact();
                await showDialog<void>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    icon: const Icon(Icons.error_outline_rounded),
                    title: Text(appText("Keep models loaded in RAM",
                        "Mantener modelos cargados en RAM")),
                    content: Text(appText(assistantBackgroundRetentionWarning,
                        "Desactivar esta opción hará que las respuestas sean más lentas en funciones externas a la app, como el asistente")),
                    actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    actions: [
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              shape: const StadiumBorder(),
                            ),
                            onPressed: () => Navigator.pop(dialogContext),
                            child: Text(appText("OK", "Aceptar")),
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(48),
                              shape: const StadiumBorder(),
                            ),
                            onPressed: () async {
                              Navigator.pop(dialogContext);
                              HapticFeedback.mediumImpact();
                              await prefs?.setBool(
                                  "keepModelLoadedInBackground", false);
                              await prefs?.setBool(
                                  "allowAssistantBackgroundUnload", true);
                              if (mounted) setState(() {});
                            },
                            child: Text(appText("Disable Anyways",
                                "Desactivar de todos modos")),
                          ),
                        ],
                      ),
                    ],
                  ),
                );
                return;
              }
              await prefs?.setBool("allowAssistantBackgroundUnload", false);
              await _setAdvancedBool("keepModelLoadedInBackground", value);
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.memory_rounded),
            title: Text(
                appText("Maximum loaded models", "Máximo de modelos cargados")),
            subtitle: Text(appText("A negative value means unlimited.",
                "Un valor negativo significa ilimitado.")),
            trailing: SizedBox(
              width: 96,
              child: TextField(
                key: const ValueKey("advanced-max-loaded-models"),
                controller: maxLoadedModelsController,
                keyboardType:
                    const TextInputType.numberWithOptions(signed: true),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),
          ListTile(
            key: const ValueKey("advanced-rag-max-chunks"),
            leading: const Icon(Icons.manage_search_rounded),
            title: Text(appText(
                "Document RAG fragments", "Fragmentos RAG de documentos")),
            subtitle: Text(appText(
                "Maximum relevant fragments injected per question (1–32).",
                "Máximo de fragmentos relevantes añadidos por pregunta (1–32).")),
            trailing: SizedBox(
              width: 96,
              child: TextField(
                controller: documentRagMaxChunksController,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),
          ListTile(
            key: const ValueKey("advanced-domain-rules"),
            leading: const Icon(Icons.public_off_outlined),
            title: Text(appText("Domains used in web search",
                "Dominios usados en búsquedas web")),
            subtitle: Text(appText(
                "Limit, block or prioritize domains used by web-search tools.",
                "Limita, bloquea o prioriza los dominios usados por las herramientas de búsqueda.")),
            onTap: () {
              var allowedEnabled = _domainRuleEnabled(
                  "groundingAllowedDomains", "groundingAllowedDomainsEnabled");
              var preferredEnabled = _domainRuleEnabled(
                  "groundingPreferredDomains",
                  "groundingPreferredDomainsEnabled");
              var blockedEnabled = _domainRuleEnabled(
                  "groundingBlockedDomains", "groundingBlockedDomainsEnabled");
              showDialog<void>(
                context: context,
                builder: (dialogContext) => StatefulBuilder(
                  builder: (dialogContext, setDialogState) => AlertDialog(
                    title: Text(appText("Domains used in web search",
                        "Dominios usados en búsquedas web")),
                    content: SizedBox(
                      width: 520,
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SwitchListTile(
                              key: const ValueKey(
                                  "advanced-allowed-domains-enabled"),
                              contentPadding: EdgeInsets.zero,
                              title: Text(appText("Allowed", "Permitidos")),
                              subtitle: Text(appText(
                                  "Exclusive allowlist: disables Preferred and Blocked.",
                                  "Lista blanca exclusiva: desactiva Preferidos y Bloqueados.")),
                              value: allowedEnabled,
                              onChanged: (value) {
                                allowedEnabled = value;
                                if (value) {
                                  preferredEnabled = false;
                                  blockedEnabled = false;
                                }
                                setDialogState(() {});
                              },
                            ),
                            TextField(
                              key: const ValueKey("advanced-allowed-domains"),
                              controller: groundingAllowedDomainsController,
                              enabled: allowedEnabled,
                              minLines: 3,
                              maxLines: 6,
                              decoration: InputDecoration(
                                hintText: "wikipedia.org\nrae.es\ngithub.com",
                                helperText: appText(
                                    "Only these domains and their subdomains may be used.",
                                    "Solo se pueden usar estos dominios y sus subdominios."),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            SwitchListTile(
                              key: const ValueKey(
                                  "advanced-preferred-domains-enabled"),
                              contentPadding: EdgeInsets.zero,
                              title: Text(appText("Preferred", "Preferidos")),
                              subtitle: Text(appText(
                                  "Prioritizes domains and can be combined with Blocked.",
                                  "Prioriza dominios y puede combinarse con Bloqueados.")),
                              value: preferredEnabled,
                              onChanged: (value) {
                                preferredEnabled = value;
                                if (value) allowedEnabled = false;
                                setDialogState(() {});
                              },
                            ),
                            TextField(
                              key: const ValueKey("advanced-preferred-domains"),
                              controller: groundingPreferredDomainsController,
                              enabled: preferredEnabled,
                              minLines: 3,
                              maxLines: 6,
                              decoration: InputDecoration(
                                hintText: "wikipedia.org\nopen-meteo.com",
                                helperText: appText(
                                    "Results from these domains appear first.",
                                    "Los resultados de estos dominios aparecen primero."),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            SwitchListTile(
                              key: const ValueKey(
                                  "advanced-blocked-domains-enabled"),
                              contentPadding: EdgeInsets.zero,
                              title: Text(appText("Blocked", "Bloqueados")),
                              subtitle: Text(appText(
                                  "Excludes domains and can be combined with Preferred.",
                                  "Excluye dominios y puede combinarse con Preferidos.")),
                              value: blockedEnabled,
                              onChanged: (value) {
                                blockedEnabled = value;
                                if (value) allowedEnabled = false;
                                setDialogState(() {});
                              },
                            ),
                            TextField(
                              key: const ValueKey("advanced-blocked-domains"),
                              controller: groundingBlockedDomainsController,
                              enabled: blockedEnabled,
                              minLines: 3,
                              maxLines: 6,
                              decoration: InputDecoration(
                                hintText: "example.com\nspam.invalid",
                                helperText: appText(
                                    "The domain and its subdomains are never shown or read.",
                                    "El dominio y sus subdominios nunca se muestran ni se leen."),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: Text(appText("Cancel", "Cancelar")),
                      ),
                      FilledButton(
                        onPressed: () async {
                          if (!await _saveDomainSettings() ||
                              !dialogContext.mounted) {
                            return;
                          }
                          await prefs?.setBool(
                              "groundingAllowedDomainsEnabled", allowedEnabled);
                          await prefs?.setBool(
                              "groundingPreferredDomainsEnabled",
                              preferredEnabled);
                          await prefs?.setBool(
                              "groundingBlockedDomainsEnabled", blockedEnabled);
                          if (!dialogContext.mounted || !mounted) return;
                          Navigator.pop(dialogContext);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text(appText("Domain settings saved",
                                    "Configuración de dominios guardada"))),
                          );
                        },
                        child: Text(appText("Save", "Guardar")),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          ListTile(
            key: const ValueKey("advanced-grounding-max-links"),
            leading: const Icon(Icons.manage_search_rounded),
            title: Text(appText("Maximum links in Deep Exploration",
                "Máximo de enlaces en Deep Exploration")),
            subtitle: Text(appText(
                "Limits pages read per query; a negative value allows all available results.",
                "Limita las páginas leídas por consulta; un valor negativo permite usar todos los resultados disponibles.")),
            trailing: SizedBox(
              width: 96,
              child: TextField(
                controller: groundingMaxLinksController,
                keyboardType:
                    const TextInputType.numberWithOptions(signed: true),
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
          ),
          SwitchListTile(
            key: const ValueKey("advanced-extra-compute"),
            secondary: const Icon(Icons.developer_board_rounded),
            title: Text(appText("Extra ways to run a model",
                "Formas adicionales de ejecutar un modelo")),
            subtitle: Text(appText("Enables Synergy and experimental controls.",
                "Habilita Synergy y controles experimentales.")),
            value: extraModes,
            onChanged: (value) async {
              await _setAdvancedBool("enableExtraComputeModes", value);
              if (!value && configuredComputeMode() == computeModeSynergy) {
                await prefs?.setString("computeMode", computeModeAdaptive);
                await _applyLocalServerSettings();
              }
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: DropdownButtonFormField<String>(
              key: const ValueKey("advanced-compute-mode"),
              initialValue: computeMode == computeModeSynergy && !extraModes
                  ? computeModeAdaptive
                  : computeMode,
              decoration: InputDecoration(
                labelText:
                    appText("Local compute engine", "Motor de cálculo local"),
                border: const OutlineInputBorder(),
              ),
              items: [
                DropdownMenuItem(
                    value: computeModeAdaptive,
                    child: Text(appText("Automatic", "Automático"))),
                DropdownMenuItem(
                    value: computeModeForced,
                    child: Text(appText("Force device", "Forzar dispositivo"))),
                if (extraModes)
                  const DropdownMenuItem(
                      value: computeModeSynergy, child: Text("Synergy")),
              ],
              onChanged: (value) async {
                if (value == null) return;
                await prefs?.setString("computeMode", value);
                setState(() {});
                await _applyLocalServerSettings();
              },
            ),
          ),
          if (computeMode == computeModeForced)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SegmentedButton<String>(
                key: const ValueKey("advanced-forced-device"),
                segments: [
                  const ButtonSegment(value: "cpu", label: Text("CPU")),
                  const ButtonSegment(value: "gpu", label: Text("GPU")),
                  ButtonSegment(
                      value: "npu",
                      enabled: npuBackend,
                      label: const Text("NPU")),
                ],
                selected: {
                  forcedDevice == "npu" && !npuBackend ? "cpu" : forcedDevice
                },
                onSelectionChanged: (selection) async {
                  await prefs?.setString(
                      "forcedComputeDevice", selection.first);
                  setState(() {});
                  await _applyLocalServerSettings();
                },
              ),
            ),
          if (extraModes && computeMode == computeModeSynergy) ...[
            SwitchListTile(
              key: const ValueKey("advanced-synergy-npu"),
              secondary: const Icon(Icons.auto_awesome_rounded),
              title: Text(appText(
                  "Add NPU to processing", "Añadir NPU al procesamiento")),
              subtitle: Text(npuBackend
                  ? appText("Splits the model across CPU, NPU and GPU.",
                      "Divide el modelo entre CPU, NPU y GPU.")
                  : (computeCapabilities["htpReason"]?.toString() ??
                      (npuDetected
                          ? appText(
                              "NPU detected, but no compatible backend is installed.",
                              "NPU detectada, pero no hay un backend compatible instalado.")
                          : appText("No compatible NPU was detected.",
                              "No se ha detectado una NPU compatible.")))),
              value: synergyNpuEnabled,
              onChanged: npuBackend
                  ? (value) async {
                      await prefs?.setBool("synergyNpuEnabled", value);
                      if (value) {
                        final cpu = (100 - synergyGpu) ~/ 2;
                        await prefs?.setInt("synergyCpuPercent", cpu);
                        await prefs?.setInt(
                            "synergyNpuPercent", 100 - synergyGpu - cpu);
                      }
                      setState(() {});
                      await _applyLocalServerSettings();
                    }
                  : null,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: synergyNpuEnabled
                  ? Column(children: [
                      const Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [Text("CPU"), Text("NPU"), Text("GPU")],
                      ),
                      RangeSlider(
                        key: const ValueKey("advanced-synergy-triple-slider"),
                        min: 0,
                        max: 100,
                        divisions: 20,
                        labels: RangeLabels("$synergyCpu% CPU",
                            "$synergyGpu% GPU · $synergyNpu% NPU"),
                        values: RangeValues(synergyCpu.toDouble(),
                            (100 - synergyGpu).toDouble()),
                        onChanged: (values) async {
                          final cpu = values.start.round();
                          final gpu = 100 - values.end.round();
                          final npu = 100 - cpu - gpu;
                          await prefs?.setInt("synergyCpuPercent", cpu);
                          await prefs?.setInt("synergyGpuPercent", gpu);
                          await prefs?.setInt("synergyNpuPercent", npu);
                          setState(() {});
                        },
                        onChangeEnd: (_) => _applyLocalServerSettings(),
                      ),
                    ])
                  : Row(children: [
                      const Text("CPU"),
                      Expanded(
                        child: Slider(
                          key: const ValueKey("advanced-synergy-slider"),
                          min: 0,
                          max: 100,
                          divisions: 20,
                          label: "$synergyGpu% GPU",
                          value: synergyGpu.toDouble(),
                          onChanged: (value) async {
                            await prefs?.setInt(
                                "synergyGpuPercent", value.round());
                            await prefs?.setInt(
                                "synergyCpuPercent", 100 - value.round());
                            setState(() {});
                          },
                          onChangeEnd: (_) => _applyLocalServerSettings(),
                        ),
                      ),
                      const Text("GPU"),
                    ]),
            ),
            Text(synergyNpuEnabled
                ? "CPU $synergyCpu% · NPU $synergyNpu% · GPU $synergyGpu%"
                : "CPU ${100 - synergyGpu}% · GPU $synergyGpu%"),
          ],
          const Divider(),
          _hardwareCompatibilityCards(),
          const Divider(),
          SwitchListTile(
            key: const ValueKey("advanced-rpc-clustering"),
            secondary: const Icon(Icons.hub_rounded),
            title: Text(appText("Enable RPC Cluster", "Activar Cluster RPC")),
            subtitle: Text(appText(
                "This device coordinates llama.cpp RPC workers on a trusted local network.",
                "Este dispositivo coordina workers llama.cpp RPC de una red local de confianza.")),
            value: clustering,
            onChanged: (value) => _setAdvancedBool(
              "rpcClusteringEnabled",
              value,
              restartServer: true,
            ),
          ),
          if (clustering)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: TextField(
                key: const ValueKey("advanced-rpc-servers"),
                controller: rpcServersController,
                decoration: InputDecoration(
                  labelText: "Workers RPC",
                  hintText: "192.168.1.133:50052,192.168.1.186:50052",
                  helperText: appText("Separate multiple workers with commas.",
                      "Separa varios workers con comas."),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
          if (clustering)
            SwitchListTile(
              key: const ValueKey('advanced-multimodal-device-division'),
              secondary: const Icon(Icons.account_tree_rounded),
              title: Text(appText('Multimodal device division',
                  'División multimodal por dispositivo')),
              subtitle: Text(appText(
                  'Assigns the audio/vision projector and authorizes sensors per device.',
                  'Asigna el proyector de audio/visión y autoriza sensores por dispositivo.')),
              value: multimodalDivision,
              onChanged: (value) => _setAdvancedBool(
                'clusterMultimodalDivision',
                value,
                restartServer: true,
              ),
            ),
          if (clustering && multimodalDivision) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: MaterialBanner(
                padding: const EdgeInsets.all(12),
                leading: const Icon(Icons.security_rounded),
                content: Text(appText(
                    'Use only a trusted LAN. Compute travels over RPC; camera and microphone data use the authenticated Ollama Android channel when shared by the worker.',
                    'Usa solo una LAN de confianza. El cálculo viaja por RPC; cámara y micrófono viajan por el canal autenticado de Ollama Android cuando el worker los comparte.')),
                actions: const [SizedBox.shrink()],
              ),
            ),
            _clusterDeviceList(),
          ],
          const Divider(),
          ListTile(
            leading: Icon(workerRunning
                ? Icons.sensors_rounded
                : Icons.sensors_off_rounded),
            title: Text(appText("Expose this device as a worker",
                "Exponer este dispositivo como worker")),
            subtitle: Text(workerRunning
                ? appText(
                    "Worker active on port ${rpcWorkerStatus["port"] ?? 50052}",
                    "Worker activo en el puerto ${rpcWorkerStatus["port"] ?? 50052}")
                : (rpcWorkerStatus["error"]?.toString().isNotEmpty == true
                    ? "Error: ${rpcWorkerStatus["error"]}"
                    : appText(
                        "Allows another cluster device to use its processors.",
                        "Permite que otro dispositivo del cluster use sus procesadores."))),
            trailing: computeCapabilitiesLoading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : IconButton(
                    tooltip: appText("Refresh status", "Actualizar estado"),
                    onPressed: _refreshAdvancedHardware,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(children: [
              Expanded(
                child: TextField(
                  key: const ValueKey("advanced-rpc-worker-port"),
                  controller: rpcWorkerPortController,
                  enabled: !workerRunning,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: appText("Worker port", "Puerto del worker"),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String>(
                  key: const ValueKey("advanced-rpc-worker-device"),
                  initialValue: rpcWorkerDevice,
                  decoration: InputDecoration(
                    labelText: appText("Processor", "Procesador"),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                        value: "auto",
                        child: Text(appText("Automatic", "Automático"))),
                    const DropdownMenuItem(value: "CPU", child: Text("CPU")),
                    if (computeCapabilities["gpu"] == true ||
                        rpcWorkerDevice == "Vulkan0")
                      const DropdownMenuItem(
                          value: "Vulkan0", child: Text("GPU Vulkan")),
                    if (computeCapabilities["adrenoDetected"] == true ||
                        rpcWorkerDevice == "GPUOpenCL")
                      const DropdownMenuItem(
                          value: "GPUOpenCL", child: Text("GPU OpenCL")),
                    if (npuBackend || rpcWorkerDevice == "HTP0")
                      const DropdownMenuItem(
                          value: "HTP0", child: Text("NPU HTP")),
                  ],
                  onChanged: workerRunning
                      ? null
                      : (value) async {
                          if (value != null) {
                            await prefs?.setString("rpcWorkerDevice", value);
                            setState(() {});
                          }
                        },
                ),
              ),
            ]),
          ),
          SwitchListTile(
            title: Text(
                appText("Worker tensor cache", "Caché de tensores del worker")),
            subtitle: Text(appText("Uses more storage to reuse data.",
                "Aumenta el uso de almacenamiento para reutilizar datos.")),
            value: prefs?.getBool("rpcWorkerCache") ?? false,
            onChanged: workerRunning
                ? null
                : (value) => _setAdvancedBool("rpcWorkerCache", value),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.perm_camera_mic_rounded),
            title: Text(appText(
                'Share camera and microphone', 'Compartir cámara y micrófono')),
            subtitle: Text(appText(
                'Allows captures requested by a paired host while this worker is active.',
                'Permite capturas solicitadas por un host emparejado mientras este worker está activo.')),
            value: rpcWorkerShareMedia,
            onChanged: workerRunning
                ? null
                : (value) => _setAdvancedBool('rpcWorkerShareMedia', value),
          ),
          if (rpcWorkerShareMedia)
            ListTile(
              leading: const Icon(Icons.key_rounded),
              title: Text(
                  appText('Worker media key', 'Clave multimedia del worker')),
              subtitle: SelectableText(rpcWorkerMediaToken),
              trailing: IconButton(
                tooltip: appText('Copy key', 'Copiar clave'),
                icon: const Icon(Icons.copy_rounded),
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: rpcWorkerMediaToken));
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(appText(
                          'Media key copied', 'Clave multimedia copiada'))));
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: SizedBox(
              width: double.infinity,
              child: workerRunning
                  ? OutlinedButton.icon(
                      key: const ValueKey("advanced-stop-rpc-worker"),
                      onPressed: _stopRpcWorker,
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: Text(appText("Stop worker", "Detener worker")),
                    )
                  : FilledButton.tonalIcon(
                      key: const ValueKey("advanced-start-rpc-worker"),
                      onPressed: computeCapabilities["rpcBackend"] == false
                          ? null
                          : _startRpcWorker,
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text(
                          appText("Start RPC worker", "Iniciar worker RPC")),
                    ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              key: const ValueKey("advanced-save"),
              onPressed: _saveAdvancedTextSettings,
              icon: const Icon(Icons.save_rounded),
              label: Text(appText(
                  "Save advanced options", "Guardar opciones avanzadas")),
            ),
          ),
        ],
      ),
    );
  }

  Widget toggle(String text, bool value, Function(bool value) onChanged) {
    var space = "⁣"; // Invisible character: U+2063
    var spacePlus = "    $space";
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16, right: 16, top: 12),
          child: Divider(
            color: (Theme.of(context).brightness == Brightness.light)
                ? Colors.grey[300]
                : Colors.grey[900],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.max,
          children: [
            Expanded(
              child: Text(
                text + spacePlus,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  backgroundColor:
                      (Theme.of(context).brightness == Brightness.light)
                          ? (theme ?? ThemeData()).colorScheme.surface
                          : (themeDark ?? ThemeData.dark()).colorScheme.surface,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.only(left: 16),
              color: (Theme.of(context).brightness == Brightness.light)
                  ? (theme ?? ThemeData()).colorScheme.surface
                  : (themeDark ?? ThemeData.dark()).colorScheme.surface,
              child: SizedBox(
                height: 40,
                child: Switch(value: value, onChanged: onChanged),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget title(String text, {double top = 16, double bottom = 16}) {
    return Padding(
      padding: EdgeInsets.only(left: 8, right: 8, top: top, bottom: bottom),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.only(left: 24, right: 24),
            child: Text(text),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !hostLoading,
      onPopInvoked: (didPop) {
        settingsOpen = false;
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: WindowBorder(
        color: Theme.of(context).colorScheme.surface,
        child: Scaffold(
          appBar: AppBar(
            title: Row(
              children: [
                Text(AppLocalizations.of(context)!.optionSettings),
                Expanded(child: SizedBox(height: 200, child: MoveWindow())),
              ],
            ),
            actions:
                (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                    ? [
                        SizedBox(
                          height: 200,
                          child: WindowTitleBarBox(
                            child: Row(
                              children: [
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
                    : null,
          ),
          body: Padding(
            padding: const EdgeInsets.only(left: 16, right: 16),
            child: ListView(
              children: [
                Text(
                  appText("Connection mode", "Modo de conexión"),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  key: const ValueKey("connection-mode-selector"),
                  showSelectedIcon: false,
                  emptySelectionAllowed: false,
                  segments: [
                    const ButtonSegment<String>(
                      value: connectionModeLocal,
                      icon: Icon(Icons.smartphone_rounded),
                      label: Text("Local"),
                    ),
                    ButtonSegment<String>(
                      value: connectionModeExternal,
                      icon: const Icon(Icons.dns_rounded),
                      label: Text(appText("Server", "Servidor")),
                    ),
                    const ButtonSegment<String>(
                      value: connectionModeCloud,
                      icon: Icon(Icons.cloud_rounded),
                      label: Text("Cloud"),
                    ),
                  ],
                  selected: <String>{activeConnectionMode},
                  onSelectionChanged: (selection) =>
                      _selectConnectionMode(selection.first),
                ),
                const SizedBox(height: 12),
                if (activeConnectionMode == connectionModeLocal)
                  Card(
                    key: const ValueKey("connection-local-panel"),
                    child: ListTile(
                      leading: const Icon(Icons.memory_rounded),
                      title: Text(appText("Ollama on this device",
                          "Ollama en este dispositivo")),
                      subtitle: Text(
                        Platform.isAndroid
                            ? appText("$localOllamaHost · no Google services",
                                "$localOllamaHost · sin servicios de Google")
                            : appText(
                                "The built-in local server is only available on Android.",
                                "El servidor local integrado solo está disponible en Android."),
                      ),
                      trailing: Platform.isAndroid
                          ? IconButton(
                              tooltip: appText(
                                  "Start or restart", "Iniciar o reiniciar"),
                              onPressed: () =>
                                  _selectConnectionMode(connectionModeLocal),
                              icon: const Icon(Icons.restart_alt_rounded),
                            )
                          : null,
                    ),
                  ),
                if (activeConnectionMode == connectionModeExternal)
                  TextField(
                    key: const ValueKey("external-server-host"),
                    controller: hostInputController,
                    keyboardType: TextInputType.url,
                    readOnly: useHost,
                    onSubmitted: (_) => checkHost(),
                    decoration: InputDecoration(
                      labelText: appText(
                          "Ollama server URL", "URL del servidor Ollama"),
                      hintText: "http://192.168.1.10:11434",
                      prefixIcon: IconButton(
                        tooltip: appText("HTTP headers", "Cabeceras HTTP"),
                        onPressed: () async {
                          final value = await prompt(
                            context,
                            placeholder: "{\"Authorization\": \"Bearer ...\"}",
                            title: AppLocalizations.of(context)!
                                .settingsHostHeaderTitle,
                            value: prefs!.getString("hostHeaders") ?? "{}",
                            valueIfCanceled: "{}",
                            validator: (content) async {
                              try {
                                final decoded = jsonDecode(content);
                                return decoded is Map;
                              } catch (_) {
                                return false;
                              }
                            },
                            validatorError: AppLocalizations.of(context)!
                                .settingsHostHeaderInvalid,
                          );
                          await prefs!.setString("hostHeaders", value);
                        },
                        icon: const Icon(Icons.http_rounded),
                      ),
                      suffixIcon: hostLoading
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              tooltip: appText(
                                  "Check and save", "Comprobar y guardar"),
                              onPressed: checkHost,
                              icon: const Icon(Icons.save_rounded),
                            ),
                      border: const OutlineInputBorder(),
                      errorText: hostInvalidUrl
                          ? appText("The URL is invalid", "La URL no es válida")
                          : hostInvalidHost
                              ? appText("Could not connect to Ollama",
                                  "No se pudo conectar con Ollama")
                              : null,
                      helperText: appText(
                          "It must respond as a compatible Ollama server.",
                          "Debe responder como un servidor Ollama compatible."),
                    ),
                  ),
                if (activeConnectionMode == connectionModeCloud)
                  Column(
                    key: const ValueKey("connection-cloud-panel"),
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        key: const ValueKey("ollama-cloud-api-key"),
                        controller: cloudApiKeyController,
                        obscureText: true,
                        enableSuggestions: false,
                        autocorrect: false,
                        decoration: InputDecoration(
                          labelText: "Ollama Cloud API key",
                          hintText: appText("Enter the exact key",
                              "Introduce la clave exacta"),
                          prefixIcon: const Icon(Icons.key_rounded),
                          suffixIcon: IconButton(
                            tooltip: appText("Save key", "Guardar clave"),
                            onPressed: _saveCloudApiKey,
                            icon: const Icon(Icons.save_rounded),
                          ),
                          border: const OutlineInputBorder(),
                          helperText: appText(
                              "The key is stored in Android secure storage.",
                              "La clave se guarda en el almacén seguro de Android."),
                        ),
                        onSubmitted: (_) => _saveCloudApiKey(),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "Endpoint: $ollamaCloudHost",
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                const SizedBox(height: 8),
                title(
                  AppLocalizations.of(context)!.settingsTitleBehavior,
                  bottom: 24,
                ),
                TextField(
                  controller: systemInputController,
                  keyboardType: TextInputType.multiline,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(
                      context,
                    )!
                        .settingsSystemMessage,
                    hintText: "You are a helpful assistant",
                    suffixIcon: IconButton(
                      onPressed: () {
                        HapticFeedback.selectionClick();
                        prefs?.setString(
                          "system",
                          (systemInputController.text.isNotEmpty)
                              ? systemInputController.text
                              : "You are a helpful assistant",
                        );
                      },
                      icon: const Icon(Icons.save_rounded),
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                toggle(
                  AppLocalizations.of(context)!.settingsDisableMarkdown,
                  (prefs!.getBool("noMarkdown") ?? false),
                  (value) {
                    HapticFeedback.selectionClick();
                    prefs!.setBool("noMarkdown", value);
                    setState(() {});
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(Icons.warning_rounded, color: Colors.grey),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        AppLocalizations.of(
                          context,
                        )!
                            .settingsBehaviorNotUpdatedForOlderChats,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  ],
                ),
                title(AppLocalizations.of(context)!.settingsTitleInterface),
                DropdownButtonFormField<String>(
                  key: const ValueKey("interface-language"),
                  initialValue:
                      prefs?.getString("interfaceLanguage") ?? "system",
                  decoration: InputDecoration(
                    labelText: appText("Language", "Idioma"),
                    prefixIcon: const Icon(Icons.language_rounded),
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem(
                        value: "system",
                        child: Text(appText("System", "Sistema"))),
                    const DropdownMenuItem(value: "en", child: Text("English")),
                    const DropdownMenuItem(value: "es", child: Text("Español")),
                  ],
                  onChanged: (value) async {
                    if (value == null) return;
                    await prefs?.setString("interfaceLanguage", value);
                    await Restart.restartApp();
                  },
                ),
                const SizedBox(height: 16),
                SegmentedButton(
                  segments: [
                    ButtonSegment(
                      value: "stream",
                      label: Text(appText("Stream", "Flujo")),
                      icon: const Icon(Icons.stream_rounded),
                    ),
                    ButtonSegment(
                      value: "request",
                      label: Text(appText("Request", "Solicitud")),
                      icon: const Icon(Icons.send_rounded),
                    ),
                  ],
                  selected: {prefs!.getString("requestType") ?? "stream"},
                  onSelectionChanged: (p0) {
                    HapticFeedback.selectionClick();
                    setState(() {
                      prefs!.setString("requestType", p0.elementAt(0));
                    });
                  },
                ),
                const SizedBox(height: 16),
                toggle(
                  AppLocalizations.of(context)!.settingsGenerateTitles,
                  (prefs!.getBool("generateTitles") ?? true),
                  (value) {
                    HapticFeedback.selectionClick();
                    prefs!.setBool("generateTitles", value);
                    setState(() {});
                  },
                ),
                toggle(
                  AppLocalizations.of(context)!.settingsAskBeforeDelete,
                  (prefs!.getBool("askBeforeDeletion") ?? false),
                  (value) {
                    HapticFeedback.selectionClick();
                    prefs!.setBool("askBeforeDeletion", value);
                    setState(() {});
                  },
                ),
                toggle(
                  AppLocalizations.of(context)!.settingsResetOnModelChange,
                  (prefs!.getBool("resetOnModelSelect") ?? true),
                  (value) {
                    HapticFeedback.selectionClick();
                    prefs!.setBool("resetOnModelSelect", value);
                    setState(() {});
                  },
                ),
                toggle(
                  AppLocalizations.of(context)!.settingsEnableEditing,
                  (prefs!.getBool("enableEditing") ?? false),
                  (value) {
                    HapticFeedback.selectionClick();
                    prefs!.setBool("enableEditing", value);
                    setState(() {});
                  },
                ),
                toggle(
                  AppLocalizations.of(context)!.settingsShowTips,
                  (prefs!.getBool("tips") ?? true),
                  (value) {
                    HapticFeedback.selectionClick();
                    prefs!.setBool("tips", value);
                    setState(() {});
                  },
                ),
                toggle(
                  AppLocalizations.of(context)!.settingsShowModelTags,
                  (prefs!.getBool("modelTags") ?? false),
                  (value) {
                    HapticFeedback.selectionClick();
                    prefs!.setBool("modelTags", value);
                    setState(() {});
                  },
                ),
                const SizedBox(height: 16),
                SegmentedButton(
                  segments: [
                    ButtonSegment(
                      value: "dark",
                      label: Text(
                        AppLocalizations.of(context)!.settingsBrightnessDark,
                      ),
                      icon: const Icon(Icons.brightness_4_rounded),
                    ),
                    ButtonSegment(
                      value: "system",
                      label: Text(
                        AppLocalizations.of(context)!.settingsBrightnessSystem,
                      ),
                      icon: const Icon(Icons.brightness_auto_rounded),
                    ),
                    ButtonSegment(
                      value: "light",
                      label: Text(
                        AppLocalizations.of(context)!.settingsBrightnessLight,
                      ),
                      icon: const Icon(Icons.brightness_high_rounded),
                    ),
                  ],
                  selected: {prefs!.getString("brightness") ?? "system"},
                  onSelectionChanged: (p0) {
                    HapticFeedback.selectionClick();
                    var tmp = prefs!.getString("brightness") ?? "system";
                    prefs!.setString("brightness", p0.elementAt(0));
                    setState(() {});
                    showDialog(
                      context: context,
                      builder: (context) {
                        return StatefulBuilder(
                          builder: (context, setLocalState) {
                            return PopScope(
                              onPopInvoked: (didPop) {
                                prefs!.setString("brightness", tmp);
                                setState(() {});
                              },
                              child: AlertDialog(
                                title: Text(
                                  AppLocalizations.of(
                                    context,
                                  )!
                                      .settingsBrightnessRestartTitle,
                                ),
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      AppLocalizations.of(
                                        context,
                                      )!
                                          .settingsBrightnessRestartDescription,
                                    ),
                                  ],
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () {
                                      HapticFeedback.selectionClick();
                                      Navigator.of(context).pop();
                                    },
                                    child: Text(
                                      AppLocalizations.of(
                                        context,
                                      )!
                                          .settingsBrightnessRestartCancel,
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () async {
                                      HapticFeedback.selectionClick();
                                      await prefs!.setString(
                                        "brightness",
                                        p0.elementAt(0),
                                      );
                                      if (Platform.isWindows ||
                                          Platform.isLinux ||
                                          Platform.isMacOS) {
                                        exit(0);
                                      } else {
                                        Restart.restartApp();
                                      }
                                    },
                                    child: Text(
                                      AppLocalizations.of(
                                        context,
                                      )!
                                          .settingsBrightnessRestartRestart,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
                title(AppLocalizations.of(context)!.settingsTitleExport),
                InkWell(
                  onTap: () async {
                    var path = await FilePicker.saveFile(
                      type: FileType.custom,
                      allowedExtensions: ["json"],
                      fileName:
                          "ollama-export-${DateFormat('yyyy-MM-dd-H-m-s').format(DateTime.now())}.json",
                      bytes: utf8.encode(
                        jsonEncode(prefs!.getStringList("chats") ?? []),
                      ),
                    );
                    if (path == null) return;
                    if (Platform.isWindows ||
                        Platform.isLinux ||
                        Platform.isMacOS) {
                      File(path).writeAsString(
                        jsonEncode(prefs!.getStringList("chats") ?? []),
                      );
                    }
                  },
                  child: Row(
                    children: [
                      const Icon(Icons.upload_rounded),
                      const SizedBox(width: 16, height: 42),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!.settingsExportChats,
                        ),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () {
                    showDialog(
                      context: context,
                      builder: (context) {
                        return AlertDialog(
                          title: Text(
                            AppLocalizations.of(
                              context,
                            )!
                                .settingsImportChatsTitle,
                          ),
                          content: Text(
                            AppLocalizations.of(
                              context,
                            )!
                                .settingsImportChatsDescription,
                          ),
                          actions: [
                            TextButton(
                              onPressed: () {
                                HapticFeedback.selectionClick();
                                Navigator.of(context).pop();
                              },
                              child: Text(
                                AppLocalizations.of(
                                  context,
                                )!
                                    .settingsImportChatsCancel,
                              ),
                            ),
                            TextButton(
                              onPressed: () async {
                                HapticFeedback.selectionClick();
                                FilePickerResult? result =
                                    await FilePicker.pickFiles(
                                  type: FileType.custom,
                                  allowedExtensions: ["json"],
                                );
                                if (result == null) {
                                  // ignore: use_build_context_synchronously
                                  Navigator.of(context).pop();
                                  return;
                                }

                                File file = File(result.files.single.path!);
                                var content = await file.readAsString();
                                List<dynamic> tmpHistory = jsonDecode(content);
                                List<String> history = [];

                                for (var i = 0; i < tmpHistory.length; i++) {
                                  history.add(tmpHistory[i]);
                                }

                                prefs!.setStringList("chats", history);

                                messages = [];
                                chatUuid = null;

                                setState(() {});

                                // ignore: use_build_context_synchronously
                                Navigator.of(context).pop();
                                // ignore: use_build_context_synchronously
                                Navigator.of(context).pop();
                                // ignore: use_build_context_synchronously
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      AppLocalizations
                                              // ignore: use_build_context_synchronously
                                              .of(context)!
                                          .settingsImportChatsSuccess,
                                    ),
                                    showCloseIcon: true,
                                  ),
                                );
                              },
                              child: Text(
                                AppLocalizations.of(
                                  context,
                                )!
                                    .settingsImportChatsImport,
                              ),
                            ),
                          ],
                        );
                      },
                    );
                  },
                  child: Row(
                    children: [
                      const Icon(Icons.download_rounded),
                      const SizedBox(width: 16, height: 42),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!.settingsImportChats,
                        ),
                      ),
                    ],
                  ),
                ),
                title(AppLocalizations.of(context)!.settingsTitleContact),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  enabled: false,
                  leading: Icon(Icons.update_rounded),
                  title: Text("Check for updates"),
                  subtitle: Text("Temporarily disabled"),
                ),
                (updateStatus == "notAvailable")
                    ? const SizedBox.shrink()
                    : InkWell(
                        onTap: () {
                          if (updateLoading) return;
                          if ((Version.parse(latestVersion ?? "1.0.0") >
                                  Version.parse(currentVersion ?? "2.0.0")) &&
                              (updateStatus == "ok")) {
                            updateDialog(context, title);
                          } else {
                            checkUpdate(setState);
                            return;
                          }
                        },
                        child: Row(
                          children: [
                            updateLoading
                                ? SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: Transform.scale(
                                      scale: 0.5,
                                      child: const CircularProgressIndicator(),
                                    ),
                                  )
                                : Icon(
                                    (updateStatus != "ok")
                                        ? Icons.warning_rounded
                                        : (Version.parse(
                                                  latestVersion ?? "1.0.0",
                                                ) >
                                                Version.parse(
                                                  currentVersion ?? "2.0.0",
                                                ))
                                            ? Icons.info_outline_rounded
                                            : Icons.update_rounded,
                                  ),
                            const SizedBox(width: 16, height: 42),
                            Expanded(
                              child: Text(
                                !updateChecked
                                    ? AppLocalizations.of(
                                        context,
                                      )!
                                        .settingsUpdateCheck
                                    : updateLoading
                                        ? AppLocalizations.of(
                                            context,
                                          )!
                                            .settingsUpdateChecking
                                        : (updateStatus == "rateLimit")
                                            ? AppLocalizations.of(
                                                context,
                                              )!
                                                .settingsUpdateRateLimit
                                            : (updateStatus != "ok")
                                                ? AppLocalizations.of(
                                                    context,
                                                  )!
                                                    .settingsUpdateIssue
                                                : (Version.parse(
                                                            latestVersion ??
                                                                "1.0.0") >
                                                        Version.parse(
                                                          currentVersion ??
                                                              "2.0.0",
                                                        ))
                                                    ? AppLocalizations.of(
                                                        context,
                                                      )!
                                                        .settingsUpdateAvailable(
                                                            latestVersion!)
                                                    : AppLocalizations.of(
                                                        context,
                                                      )!
                                                        .settingsUpdateLatest,
                              ),
                            ),
                          ],
                        ),
                      ),
                (updateStatus == "notAvailable")
                    ? const SizedBox.shrink()
                    : toggle(
                        AppLocalizations.of(context)!.settingsCheckForUpdates,
                        (prefs!.getBool("checkUpdateOnSettingsOpen") ?? false),
                        (value) {
                          HapticFeedback.selectionClick();
                          prefs!.setBool("checkUpdateOnSettingsOpen", value);
                          setState(() {});
                        },
                      ),
                InkWell(
                  onTap: () {
                    launchUrl(
                      mode: LaunchMode.inAppBrowserView,
                      Uri.parse(repoUrl),
                    );
                  },
                  child: Row(
                    children: [
                      const Icon(SimpleIcons.github),
                      const SizedBox(width: 16, height: 42),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!.settingsGithub,
                        ),
                      ),
                    ],
                  ),
                ),
                InkWell(
                  onTap: () {
                    launchUrl(
                      mode: LaunchMode.inAppBrowserView,
                      Uri.parse(repoUrl.substring(0, repoUrl.lastIndexOf('/'))),
                    );
                  },
                  child: Row(
                    children: [
                      const Icon(Icons.developer_board_rounded),
                      const SizedBox(width: 16, height: 42),
                      Expanded(
                        child: Text(
                          AppLocalizations.of(context)!.settingsMainDeveloper,
                        ),
                      ),
                    ],
                  ),
                ),
                _advancedOptionsCard(),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
