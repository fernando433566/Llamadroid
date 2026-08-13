import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import 'main.dart';
import 'assistant_tools.dart';
import 'assistant_voice_engines.dart';
import 'screen_assistant_voice.dart';
import 'server_controller.dart';

const supertonicModelDownloadUrl =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2";

Map<String, (String, String, IconData)> get assistantCapabilityDefinitions =>
    <String, (String, String, IconData)>{
      "voiceSession": (
        appText("Voice conversation", "Conversación por voz"),
        appText("Listen, generate a response and play it using speech.",
            "Escuchar, generar la respuesta y reproducirla por voz."),
        Icons.record_voice_over_rounded
      ),
      "wakeWord": (
        appText("Wake-up word (experimental)",
            "Palabra de activación (experimental)"),
        appText(
            "microWakeWord provides training and models for microcontrollers, not a ready-to-use Android service.",
            "microWakeWord proporciona entrenamiento y modelos para microcontroladores, no un servicio Android listo para usar."),
        Icons.hearing_rounded
      ),
      "screen": (
        appText("View screen", "Ver la pantalla"),
        appText("Share screenshots with vision-capable models.",
            "Compartir capturas de pantalla con modelos que admitan visión."),
        Icons.screen_share_rounded
      ),
      "frontCamera": (
        appText("Front camera", "Cámara frontal"),
        appText("Allow front-camera images during a session.",
            "Permitir imágenes de la cámara frontal durante una sesión."),
        Icons.camera_front_rounded
      ),
      "rearCamera": (
        appText("Rear camera", "Cámara trasera"),
        appText("Allow rear-camera images during a session.",
            "Permitir imágenes de la cámara trasera durante una sesión."),
        Icons.camera_rear_rounded
      ),
      "email": (
        appText("Send email", "Enviar correos"),
        appText("Prepare an email and open a compatible app for confirmation.",
            "Preparar un correo y abrir una aplicación compatible para confirmarlo."),
        Icons.email_outlined
      ),
      "calls": (
        appText("Calls", "Llamadas"),
        appText(
            "Prepare or make calls with confirmation and system permission.",
            "Preparar o realizar llamadas con confirmación y permiso del sistema."),
        Icons.call_outlined
      ),
      "timers": (
        appText("Timers", "Temporizadores"),
        appText("Create, view and cancel timers.",
            "Crear, consultar y cancelar temporizadores."),
        Icons.timer_outlined
      ),
      "openApps": (
        appText("Open apps", "Abrir aplicaciones"),
        appText("Find installed apps and open the selected one.",
            "Buscar aplicaciones instaladas y abrir la elegida."),
        Icons.apps_rounded
      ),
      "dateTime": (
        appText("Date and time", "Hora y fecha"),
        appText("Get the device time, date and time zone.",
            "Consultar la hora, fecha y zona horaria del dispositivo."),
        Icons.schedule_rounded
      ),
      "webSearch": (
        appText("Grounding with the web", "Fundamentación con la web"),
        appText("Search and read a web source to ground the answer.",
            "Buscar y leer una fuente web para fundamentar la respuesta."),
        Icons.travel_explore_rounded
      ),
      "alarms": (
        appText("Alarms", "Alarmas"),
        appText("Open the device alarm provider to create an alarm.",
            "Abrir el proveedor de alarmas del dispositivo para crear una alarma."),
        Icons.alarm_rounded
      ),
      "calendar": (
        appText("Calendar and reminders", "Calendario y recordatorios"),
        appText("Read or propose events using the selected calendar provider.",
            "Leer o proponer eventos mediante el proveedor de calendario elegido."),
        Icons.calendar_month_outlined
      ),
      "weather": (
        appText("Weather (Open-Meteo)", "El tiempo (Open-Meteo)"),
        appText("Get the forecast for the configured location.",
            "Consultar la previsión para la ubicación configurada."),
        Icons.cloud_outlined
      ),
      "customFunctions": (
        appText("Custom functions", "Funciones propias"),
        appText("Allow user-created tool definitions.",
            "Permitir definiciones de herramientas creadas por el usuario."),
        Icons.extension_outlined
      ),
    };

String assistantCapabilityPreferenceKey(String capability) =>
    "assistantCapability:$capability";

bool assistantCapabilityEnabled(String capability) =>
    prefs?.getBool(assistantCapabilityPreferenceKey(capability)) ?? false;

bool assistantFunctionsRequireLoadedModels() =>
    assistantCapabilityDefinitions.keys.any(assistantCapabilityEnabled);

bool assistantForcesBackgroundRetention() =>
    assistantFunctionsRequireLoadedModels() &&
    !(prefs?.getBool("allowAssistantBackgroundUnload") ?? false);

bool keepModelsLoadedInBackground() =>
    assistantForcesBackgroundRetention() ||
    (prefs?.getBool("keepModelLoadedInBackground") ?? false);

const assistantBackgroundRetentionWarning =
    "Disabling this option will make responses slower in features outside the app such as the assistant";

bool shouldWarnBeforeDisablingBackgroundRetention(bool requestedValue) =>
    !requestedValue && assistantForcesBackgroundRetention();

class ScreenAssistant extends StatefulWidget {
  const ScreenAssistant({super.key});

  @override
  State<ScreenAssistant> createState() => _ScreenAssistantState();
}

class _ScreenAssistantState extends State<ScreenAssistant> {
  final modelController = TextEditingController();
  final ttsLanguageController = TextEditingController();
  final weatherLocationController = TextEditingController();
  final followUpController = TextEditingController();
  final customFunctionsController = TextEditingController();
  List<String> availableModels = <String>[];
  bool loadingModels = true;
  String? modelError;
  String? installingVoiceEngine;
  String? voiceDownloadFile;
  double? voiceDownloadProgress;
  final Set<String> automaticVoiceInstallFailed = <String>{};

  @override
  void initState() {
    super.initState();
    modelController.text = prefs?.getString("assistantModel") ?? model ?? "";
    ttsLanguageController.text =
        prefs?.getString("assistantTtsLanguage") ?? "es";
    weatherLocationController.text =
        prefs?.getString("assistantWeatherLocation") ?? "";
    followUpController.text =
        (prefs?.getInt("assistantFollowUpSeconds") ?? 10).toString();
    customFunctionsController.text =
        prefs?.getString("assistantCustomFunctions") ?? "";
    _loadModels();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final engine = prefs?.getString("assistantSttEngine");
      if ((engine == "parakeet" ||
              engine == "whisper" ||
              engine == "nemotron") &&
          !assistantVoiceModelInstalled(engine!)) {
        _installVoiceModel(engine);
      }
    });
  }

  Future<void> _selectSttEngine(String engine) async {
    await prefs?.setString("assistantSttEngine", engine);
    if (mounted) setState(() {});
    if ((engine == "parakeet" || engine == "whisper" || engine == "nemotron") &&
        !assistantVoiceModelInstalled(engine)) {
      await _installVoiceModel(engine);
    }
  }

  Future<void> _installVoiceModel(String engine) async {
    if (installingVoiceEngine != null) return;
    setState(() {
      installingVoiceEngine = engine;
      voiceDownloadFile = null;
      voiceDownloadProgress = null;
      automaticVoiceInstallFailed.remove(engine);
    });
    try {
      final message = await downloadAssistantVoiceModel(engine,
          onProgress: (file, received, total) {
        if (!mounted) return;
        setState(() {
          voiceDownloadFile = file;
          voiceDownloadProgress = total == null || total <= 0
              ? null
              : (received / total).clamp(0.0, 1.0);
        });
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (!mounted) return;
      automaticVoiceInstallFailed.add(engine);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          duration: const Duration(seconds: 12),
          content: Text("La instalación automática falló: $error. "
              "Ahora puedes importar los archivos manualmente.")));
    } finally {
      if (mounted) {
        setState(() {
          installingVoiceEngine = null;
          voiceDownloadFile = null;
          voiceDownloadProgress = null;
        });
      }
    }
  }

  Future<void> _loadModels() async {
    try {
      final response = await http
          .get(Uri.parse("$host/api/tags"), headers: activeHostHeaders())
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception("HTTP ${response.statusCode}");
      }
      final decoded = jsonDecode(response.body);
      final names = <String>[];
      if (decoded is Map && decoded["models"] is List) {
        for (final item in decoded["models"] as List) {
          if (item is Map) {
            final name = (item["model"] ?? item["name"])?.toString();
            if (name != null && name.trim().isNotEmpty) names.add(name);
          }
        }
      }
      names.sort();
      if (!mounted) return;
      setState(() {
        availableModels = names;
        loadingModels = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        loadingModels = false;
        modelError = error.toString();
      });
    }
  }

  Future<void> _saveModel(String value) async {
    final normalized = value.trim();
    modelController.text = normalized;
    if (normalized.isEmpty) {
      await prefs?.remove("assistantModel");
    } else {
      await prefs?.setString("assistantModel", normalized);
    }
    if (mounted) setState(() {});
  }

  Future<void> _validateVoiceModel(String engine) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        duration: const Duration(minutes: 2),
        content: Row(children: [
          SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 12),
          Text(appText("Validating local engine…", "Validando el motor local…"))
        ])));
    final error = await validateAssistantVoiceModel(engine);
    if (!mounted) return;
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(SnackBar(
        content: Text(error == null
            ? appText("Engine validated with a local inference",
                "Motor validado mediante una inferencia local")
            : appText(
                "Validation failed: $error", "No se pudo validar: $error"))));
  }

  Widget _sectionTitle(String title) => Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium));

  Future<void> _editAutomaticPhrases(String capability) async {
    final variables = assistantAutomaticTriggerVariables[capability];
    if (variables == null) return;
    final saved = assistantAutomaticTriggerTemplates(capability);
    final templates = <List<TextEditingController>>[
      for (final parts in saved)
        [for (final part in parts) TextEditingController(text: part)],
    ];
    if (templates.isEmpty) {
      templates.add(
          List.generate(variables.length + 1, (_) => TextEditingController()));
    }
    final definition = assistantCapabilityDefinitions[capability]!;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, updateDialog) => AlertDialog(
          title: Text(appText("Automatic phrases · ${definition.$1}",
              "Frases automáticas · ${definition.$1}")),
          content: SizedBox(
            width: 620,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(appText(
                      "Build one or more phrases. Text boxes without ASCII characters are ignored. Variables capture the text spoken between boxes.",
                      "Crea una o varias frases. Los cuadros sin caracteres ASCII se ignoran. Las variables capturan el texto pronunciado entre cuadros.")),
                  const SizedBox(height: 12),
                  for (var templateIndex = 0;
                      templateIndex < templates.length;
                      templateIndex++)
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(children: [
                          Row(children: [
                            Text(
                                appText("Phrase ${templateIndex + 1}",
                                    "Frase ${templateIndex + 1}"),
                                style: Theme.of(dialogContext)
                                    .textTheme
                                    .titleSmall),
                            const Spacer(),
                            IconButton(
                              tooltip:
                                  appText("Remove phrase", "Eliminar frase"),
                              onPressed: templates.length == 1
                                  ? null
                                  : () => updateDialog(() {
                                        final removed =
                                            templates.removeAt(templateIndex);
                                        for (final controller in removed) {
                                          controller.dispose();
                                        }
                                      }),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          ]),
                          TextField(
                            controller: templates[templateIndex][0],
                            decoration: InputDecoration(
                              labelText:
                                  appText("Text before", "Texto anterior"),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                          for (var variableIndex = 0;
                              variableIndex < variables.length;
                              variableIndex++) ...[
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Chip(
                                avatar: const Icon(Icons.data_object_rounded,
                                    size: 18),
                                label: Text(
                                    "${appText("Variable", "Variable")} · ${variables[variableIndex]}"),
                              ),
                            ),
                            TextField(
                              controller: templates[templateIndex]
                                  [variableIndex + 1],
                              decoration: InputDecoration(
                                labelText: variableIndex == variables.length - 1
                                    ? appText("Text after", "Texto posterior")
                                    : appText("Text between variables",
                                        "Texto entre variables"),
                                border: const OutlineInputBorder(),
                              ),
                            ),
                          ],
                        ]),
                      ),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => updateDialog(() => templates.add(
                          List.generate(variables.length + 1,
                              (_) => TextEditingController()))),
                      icon: const Icon(Icons.add_rounded),
                      label: Text(appText("Add phrase", "Añadir frase")),
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
                final encoded = templates
                    .map((template) =>
                        template.map((controller) => controller.text).toList())
                    .where((parts) => parts
                        .any((part) => RegExp(r'[\x20-\x7E]').hasMatch(part)))
                    .toList();
                await prefs?.setString(
                    assistantAutomaticTriggersKey(capability),
                    jsonEncode(encoded));
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: Text(appText("Save", "Guardar")),
            ),
          ],
        ),
      ),
    );
    for (final template in templates) {
      for (final controller in template) {
        controller.dispose();
      }
    }
    if (mounted) setState(() {});
  }

  Widget _capability(String id) {
    final definition = assistantCapabilityDefinitions[id]!;
    final enabled = assistantCapabilityEnabled(id);
    final customizable = assistantAutomaticTriggerVariables.containsKey(id);
    final phraseCount = assistantAutomaticTriggerTemplates(id).length;
    return Column(children: [
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          secondary: Icon(definition.$3),
          title: Text(definition.$1),
          subtitle: Text(definition.$2),
          value: enabled,
          onChanged: (value) async {
            if (value && (id == "frontCamera" || id == "rearCamera")) {
              final granted =
                  await ServerController.requestAssistantCameraPermission();
              if (!granted) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(appText(
                          "Camera permission is required by the external assistant.",
                          "El asistente externo necesita permiso para usar la cámara."))));
                }
                return;
              }
            }
            await prefs?.setBool(assistantCapabilityPreferenceKey(id), value);
            if (value) {
              await prefs?.setBool("keepModelLoadedInBackground", true);
              await prefs?.setBool("allowAssistantBackgroundUnload", false);
            }
            if (mounted) setState(() {});
          }),
      if (enabled && customizable)
        ListTile(
          dense: true,
          contentPadding: const EdgeInsets.only(left: 56),
          leading: const Icon(Icons.short_text_rounded),
          title: Text(appText("Customize automatic phrases",
              "Personalizar frases automáticas")),
          subtitle: Text(phraseCount == 0
              ? appText("Default phrases only", "Solo frases predeterminadas")
              : appText(
                  "$phraseCount custom phrase${phraseCount == 1 ? '' : 's'}",
                  "$phraseCount frase${phraseCount == 1 ? '' : 's'} personalizada${phraseCount == 1 ? '' : 's'}")),
          trailing: const Icon(Icons.chevron_right_rounded),
          onTap: () => _editAutomaticPhrases(id),
        ),
    ]);
  }

  @override
  void dispose() {
    modelController.dispose();
    ttsLanguageController.dispose();
    weatherLocationController.dispose();
    followUpController.dispose();
    customFunctionsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final selectedModel = modelController.text.trim();
    final dropdownValues = <String>{...availableModels};
    if (selectedModel.isNotEmpty) dropdownValues.add(selectedModel);
    final sttEngine = prefs?.getString("assistantSttEngine") ?? "device";
    final sttLanguage = prefs?.getString("assistantSttLanguage") ?? "auto";
    final sttSilenceMs =
        (prefs?.getInt("assistantSttSilenceMs") ?? 1200).clamp(800, 3000);
    final ttsEngine = prefs?.getString("assistantTtsEngine") ?? "device";
    final assistantModelCapabilities = selectedModel.isEmpty
        ? <String>{}
        : effectiveModelCapabilities(
            selectedModel,
            (prefs?.getStringList("detectedModelCapabilities:$selectedModel") ??
                    const <String>[])
                .map((capability) => capability.toLowerCase())
                .toSet());
    final usesEmbeddedAudio = assistantModelCapabilities.contains("audio");

    return Scaffold(
        appBar: AppBar(title: Text(appText("Assistant", "Asistente"))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text(appText("Assistant capabilities", "Funciones del asistente"),
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          Text(
              appText(
                  "Each capability is controlled separately. Android will still request permissions and confirmations for sensitive actions.",
                  "Cada función se controla por separado. Android seguirá mostrando permisos y confirmaciones para acciones sensibles."),
              style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 12),
          SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.assistant_rounded),
              title: Text(appText("Enable assistant capabilities",
                  "Activar funciones de asistente")),
              subtitle: Text(appText(
                  "Enables assistant entry without automatically enabling any action.",
                  "Habilita la entrada de asistente sin activar automáticamente ninguna acción.")),
              value: prefs?.getBool("assistantEnabled") ?? false,
              onChanged: (value) async {
                await prefs?.setBool("assistantEnabled", value);
                if (mounted) setState(() {});
              }),
          Row(children: [
            Expanded(
                child: FilledButton.icon(
                    onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            fullscreenDialog: true,
                            builder: (_) => const ScreenAssistantVoice())),
                    icon: const Icon(Icons.mic_rounded),
                    label:
                        Text(appText("Test assistant", "Probar asistente")))),
            const SizedBox(width: 12),
            Expanded(
                child: OutlinedButton.icon(
                    onPressed: ServerController.openAssistantSettings,
                    icon: const Icon(Icons.settings_voice_rounded),
                    label: Text(
                        appText("System assistant", "Asistente del sistema")))),
          ]),
          _sectionTitle(appText("Assistant model", "Modelo del asistente")),
          if (loadingModels) const LinearProgressIndicator(),
          if (dropdownValues.isNotEmpty)
            DropdownButtonFormField<String>(
                key: ValueKey("$selectedModel:${dropdownValues.length}"),
                initialValue: selectedModel.isEmpty ? null : selectedModel,
                decoration: InputDecoration(
                    labelText: appText("Model", "Modelo"),
                    prefixIcon: const Icon(Icons.smart_toy_outlined),
                    border: const OutlineInputBorder()),
                items: dropdownValues
                    .map((name) =>
                        DropdownMenuItem(value: name, child: Text(name)))
                    .toList(),
                onChanged: (value) {
                  if (value != null) _saveModel(value);
                }),
          const SizedBox(height: 12),
          TextField(
              controller: modelController,
              textInputAction: TextInputAction.done,
              onSubmitted: _saveModel,
              decoration: InputDecoration(
                  labelText:
                      appText("Exact model name", "Nombre exacto del modelo"),
                  helperText: activeConnectionMode == connectionModeCloud
                      ? appText(
                          "Use this for Ollama Cloud models missing from the list.",
                          "Úsalo para modelos de Ollama Cloud que no aparezcan en la lista.")
                      : appText("You can also select a server model manually.",
                          "También permite seleccionar manualmente un modelo del servidor."),
                  errorText: modelError == null
                      ? null
                      : appText(
                          "The list could not be loaded; enter the exact name.",
                          "No se pudo obtener la lista; introduce el nombre exacto."),
                  suffixIcon: IconButton(
                      tooltip: appText("Save model", "Guardar modelo"),
                      onPressed: () => _saveModel(modelController.text),
                      icon: const Icon(Icons.save_rounded)),
                  border: const OutlineInputBorder())),
          _sectionTitle(appText("Voice and interaction", "Voz e interacción")),
          _capability("voiceSession"),
          DropdownButtonFormField<String>(
              initialValue: sttEngine,
              decoration: InputDecoration(
                  labelText: appText("Speech recognition (STT)",
                      "Reconocimiento de voz (STT)"),
                  border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem(
                    value: "device",
                    child: Text(appText("Device voice input",
                        "Entrada de voz del dispositivo"))),
                const DropdownMenuItem(
                    value: "parakeet", child: Text("NVIDIA Parakeet local")),
                const DropdownMenuItem(
                    value: "nemotron",
                    child: Text("NVIDIA Nemotron local (English)")),
                const DropdownMenuItem(
                    value: "whisper",
                    child: Text("Whisper local (sherpa-onnx)")),
              ],
              onChanged: usesEmbeddedAudio
                  ? null
                  : (value) => value == null ? null : _selectSttEngine(value)),
          if (usesEmbeddedAudio)
            Card(
              child: ListTile(
                  contentPadding: const EdgeInsets.all(12),
                  leading: const Icon(Icons.warning_amber_rounded),
                  title: Text(appText(
                      "Embedded audio active", "Audio integrado activo")),
                  subtitle: Text(appText(
                      "Using Embedded audio disables automatic device actions, relying only on the model's tool use. Audio is sent directly to the model and is not transformed into text.",
                      "Usar audio integrado desactiva las acciones automáticas del dispositivo y depende únicamente del uso de herramientas del modelo. El audio se envía directamente al modelo y no se transforma en texto."))),
            ),
          if (sttEngine == "nemotron")
            Column(children: [
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(assistantVoiceModelInstalled("nemotron")
                      ? Icons.check_circle_rounded
                      : Icons.download_for_offline_outlined),
                  title: Text(installingVoiceEngine == "nemotron"
                      ? "Instalando Nemotron Speech…"
                      : assistantVoiceModelInstalled("nemotron")
                          ? "Nemotron Speech instalado"
                          : "Instalar Nemotron Speech INT8"),
                  subtitle: Text(installingVoiceEngine == "nemotron"
                      ? (voiceDownloadFile ?? "Preparando…")
                      : "La app descarga y configura automáticamente el modelo streaming de 560 ms. Este modelo es solo para inglés."),
                  trailing: installingVoiceEngine == "nemotron"
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download_for_offline_rounded),
                  onTap: installingVoiceEngine != null ||
                          assistantVoiceModelInstalled("nemotron")
                      ? null
                      : () => _installVoiceModel("nemotron")),
              if (installingVoiceEngine == "nemotron")
                LinearProgressIndicator(value: voiceDownloadProgress),
              if (automaticVoiceInstallFailed.contains("nemotron"))
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(appText("Import files manually",
                        "Importar archivos manualmente")),
                    subtitle: Text(appText(
                        "Recovery: encoder, decoder, joiner and tokens.txt.",
                        "Recuperación: encoder, decoder, joiner y tokens.txt.")),
                    trailing: const Icon(Icons.folder_open_rounded),
                    onTap: () async {
                      final message =
                          await importAssistantVoiceModel("nemotron");
                      if (!context.mounted) return;
                      setState(() {});
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(message)));
                    }),
              if (assistantVoiceModelInstalled("nemotron"))
                Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                        onPressed: () => _validateVoiceModel("nemotron"),
                        icon: const Icon(Icons.fact_check_outlined),
                        label:
                            Text(appText("Validate engine", "Validar motor")))),
            ]),
          if (sttEngine == "parakeet")
            Column(children: [
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(assistantVoiceModelInstalled("parakeet")
                      ? Icons.check_circle_rounded
                      : Icons.download_for_offline_outlined),
                  title: Text(installingVoiceEngine == "parakeet"
                      ? "Instalando NVIDIA STT…"
                      : assistantVoiceModelInstalled("parakeet")
                          ? "NVIDIA STT instalado"
                          : "Instalar NVIDIA Parakeet/Nemotron STT"),
                  subtitle: Text(installingVoiceEngine == "parakeet"
                      ? (voiceDownloadFile ?? 'Preparando…')
                      : "La app descarga y configura automáticamente el paquete INT8 compatible."),
                  trailing: installingVoiceEngine == "parakeet"
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download_for_offline_rounded),
                  onTap: installingVoiceEngine != null ||
                          assistantVoiceModelInstalled("parakeet")
                      ? null
                      : () => _installVoiceModel("parakeet")),
              if (installingVoiceEngine == "parakeet")
                LinearProgressIndicator(value: voiceDownloadProgress),
              if (automaticVoiceInstallFailed.contains("parakeet"))
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(appText("Import files manually",
                        "Importar archivos manualmente")),
                    subtitle: Text(appText(
                        "Recovery: encoder, decoder, joiner and tokens.txt.",
                        "Recuperación: encoder, decoder, joiner y tokens.txt.")),
                    trailing: const Icon(Icons.folder_open_rounded),
                    onTap: () async {
                      final message =
                          await importAssistantVoiceModel("parakeet");
                      if (!context.mounted) return;
                      setState(() {});
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(message)));
                    }),
              Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(children: [
                    if (assistantVoiceModelInstalled("parakeet"))
                      TextButton.icon(
                          onPressed: () => _validateVoiceModel("parakeet"),
                          icon: const Icon(Icons.fact_check_outlined),
                          label: Text(
                              appText("Validate engine", "Validar motor"))),
                  ])),
            ]),
          if (sttEngine == "whisper")
            Column(children: [
              ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(assistantVoiceModelInstalled("whisper")
                      ? Icons.check_circle_rounded
                      : Icons.download_for_offline_outlined),
                  title: Text(installingVoiceEngine == "whisper"
                      ? "Instalando Whisper Small INT8…"
                      : assistantVoiceModelInstalled("whisper")
                          ? "Whisper Small INT8 instalado"
                          : "Instalar Whisper Small INT8"),
                  subtitle: Text(installingVoiceEngine == "whisper"
                      ? (voiceDownloadFile ?? 'Preparando…')
                      : "Descarga automática directa de encoder, decoder y tokens compatibles con sherpa-onnx."),
                  trailing: installingVoiceEngine == "whisper"
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.download_for_offline_rounded),
                  onTap: installingVoiceEngine != null ||
                          assistantVoiceModelInstalled("whisper")
                      ? null
                      : () => _installVoiceModel("whisper")),
              if (installingVoiceEngine == "whisper")
                LinearProgressIndicator(value: voiceDownloadProgress),
              if (automaticVoiceInstallFailed.contains("whisper"))
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(appText("Import files manually",
                        "Importar archivos manualmente")),
                    subtitle: Text(appText(
                        "Recovery: sherpa-onnx packages with tokens.txt only.",
                        "Recuperación: solo paquetes sherpa-onnx con tokens.txt.")),
                    trailing: const Icon(Icons.folder_open_rounded),
                    onTap: () async {
                      final message =
                          await importAssistantVoiceModel("whisper");
                      if (!context.mounted) return;
                      setState(() {});
                      ScaffoldMessenger.of(context)
                          .showSnackBar(SnackBar(content: Text(message)));
                    }),
              Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(children: [
                    if (assistantVoiceModelInstalled("whisper"))
                      TextButton.icon(
                          onPressed: () => _validateVoiceModel("whisper"),
                          icon: const Icon(Icons.fact_check_outlined),
                          label: Text(
                              appText("Validate engine", "Validar motor"))),
                  ])),
            ]),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
              initialValue: sttLanguage,
              decoration: InputDecoration(
                  labelText: appText(
                      "Recognition language", "Idioma del reconocimiento"),
                  helperText: sttEngine == "parakeet"
                      ? appText(
                          "The current Parakeet package determines its own language; this option applies to device STT and Whisper.",
                          "El paquete Parakeet actual determina su propio idioma; esta opción se aplica al STT del dispositivo y a Whisper.")
                      : appText(
                          "Multilingual detects the language; selecting one prevents interpretations in another language.",
                          "Multilingual detecta el idioma; elegir uno evita interpretaciones en otro idioma."),
                  border: const OutlineInputBorder()),
              items: const [
                DropdownMenuItem(
                    value: "auto", child: Text("Multilingual / automático")),
                DropdownMenuItem(value: "es-ES", child: Text("Español")),
                DropdownMenuItem(value: "en-US", child: Text("English")),
                DropdownMenuItem(value: "de-DE", child: Text("Deutsch")),
                DropdownMenuItem(value: "fr-FR", child: Text("Français")),
                DropdownMenuItem(value: "it-IT", child: Text("Italiano")),
                DropdownMenuItem(value: "pt-PT", child: Text("Português")),
                DropdownMenuItem(value: "zh-CN", child: Text("中文")),
                DropdownMenuItem(value: "ja-JP", child: Text("日本語")),
                DropdownMenuItem(value: "ko-KR", child: Text("한국어")),
              ],
              onChanged: (value) async {
                if (value == null) return;
                await prefs?.setString("assistantSttLanguage", value);
                if (mounted) setState(() {});
              }),
          const SizedBox(height: 12),
          ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(appText("Finish when silence is detected",
                  "Finalizar al detectar silencio")),
              subtitle: Text(appText(
                  "Waits ${(sttSilenceMs / 1000).toStringAsFixed(1)} s after you stop speaking.",
                  "Espera ${(sttSilenceMs / 1000).toStringAsFixed(1)} s después de que dejes de hablar."))),
          Slider(
              value: sttSilenceMs.toDouble(),
              min: 800,
              max: 3000,
              divisions: 22,
              label: "${(sttSilenceMs / 1000).toStringAsFixed(1)} s",
              onChanged: (value) async {
                await prefs?.setInt(
                    "assistantSttSilenceMs", (value / 100).round() * 100);
                if (mounted) setState(() {});
              }),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
              initialValue: ttsEngine,
              decoration: InputDecoration(
                  labelText: appText(
                      "Speech synthesis (TTS)", "Síntesis de voz (TTS)"),
                  border: const OutlineInputBorder()),
              items: [
                DropdownMenuItem(
                    value: "device",
                    child: Text(appText("Device TTS", "TTS del dispositivo"))),
                const DropdownMenuItem(
                    value: "supertonic", child: Text("Supertonic local")),
              ],
              onChanged: (value) async {
                if (value == null) return;
                await prefs?.setString("assistantTtsEngine", value);
                if (mounted) setState(() {});
              }),
          if (ttsEngine == "supertonic") ...[
            const SizedBox(height: 12),
            TextField(
                controller: ttsLanguageController,
                onChanged: (value) =>
                    prefs?.setString("assistantTtsLanguage", value.trim()),
                decoration: InputDecoration(
                    labelText:
                        appText("Supertonic language", "Idioma de Supertonic"),
                    hintText: "es, en, ko…",
                    border: const OutlineInputBorder())),
            ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(assistantVoiceModelInstalled("supertonic")
                    ? Icons.check_circle_rounded
                    : Icons.download_for_offline_outlined),
                title: Text(assistantVoiceModelInstalled("supertonic")
                    ? "Supertonic instalado"
                    : "Importar Supertonic 3"),
                subtitle: const Text(
                    "Selecciona los cuatro ONNX, tts.json, unicode_indexer.bin y voice.bin del paquete sherpa-onnx."),
                trailing: const Icon(Icons.folder_open_rounded),
                onTap: () async {
                  final message = await importAssistantVoiceModel("supertonic");
                  if (!context.mounted) return;
                  setState(() {});
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text(message)));
                }),
            Align(
                alignment: Alignment.centerLeft,
                child: Wrap(children: [
                  TextButton.icon(
                      onPressed: () => launchUrl(
                          Uri.parse(supertonicModelDownloadUrl),
                          mode: LaunchMode.externalApplication),
                      icon: const Icon(Icons.download_rounded),
                      label: Text(appText("Download official package",
                          "Descargar paquete oficial"))),
                  if (assistantVoiceModelInstalled("supertonic"))
                    TextButton.icon(
                        onPressed: () => _validateVoiceModel("supertonic"),
                        icon: const Icon(Icons.fact_check_outlined),
                        label:
                            Text(appText("Validate engine", "Validar motor"))),
                ])),
          ],
          const SizedBox(height: 12),
          TextField(
              controller: followUpController,
              keyboardType: TextInputType.number,
              onSubmitted: (value) {
                final seconds = int.tryParse(value);
                if (seconds != null && seconds >= 0) {
                  prefs?.setInt("assistantFollowUpSeconds", seconds);
                }
              },
              decoration: InputDecoration(
                  labelText: appText("Seconds to continue speaking",
                      "Segundos para continuar hablando"),
                  helperText: appText("10 seconds by default.",
                      "10 segundos de forma predeterminada."),
                  border: const OutlineInputBorder())),
          _capability("screen"),
          _capability("frontCamera"),
          _capability("rearCamera"),
          _sectionTitle(appText("Device actions", "Acciones del dispositivo")),
          for (final id in const [
            "email",
            "calls",
            "timers",
            "openApps",
            "dateTime",
            "alarms",
            "calendar"
          ])
            _capability(id),
          _sectionTitle(
              appText("Information and network", "Información y red")),
          _capability("webSearch"),
          _capability("weather"),
          if (assistantCapabilityEnabled("weather"))
            TextField(
                controller: weatherLocationController,
                onChanged: (value) =>
                    prefs?.setString("assistantWeatherLocation", value.trim()),
                decoration: InputDecoration(
                    labelText:
                        appText("Weather location", "Ubicación para el tiempo"),
                    hintText: "Madrid, España",
                    border: const OutlineInputBorder())),
          _sectionTitle(appText("Advanced", "Avanzado")),
          _capability("customFunctions"),
          if (assistantCapabilityEnabled("customFunctions")) ...[
            const SizedBox(height: 8),
            TextField(
                controller: customFunctionsController,
                minLines: 6,
                maxLines: 14,
                autocorrect: false,
                onChanged: (value) {
                  prefs?.setString("assistantCustomFunctions", value);
                  setState(() {});
                },
                decoration: InputDecoration(
                    labelText: appText("Custom HTTP functions (JSON)",
                        "Funciones HTTP propias (JSON)"),
                    alignLabelWithHint: true,
                    helperMaxLines: 4,
                    helperText:
                        'Lista de objetos con name, description, url, method y parameters. Se aceptan URL http/https; la respuesta se limita a 16 KB.',
                    errorText:
                        customFunctionsController.text.trim().isNotEmpty &&
                                parseCustomAssistantFunctions(
                                        customFunctionsController.text)
                                    .isEmpty
                            ? "JSON no válido o sin funciones válidas"
                            : null,
                    suffixIcon: IconButton(
                        tooltip: appText("Insert example", "Insertar ejemplo"),
                        onPressed: () {
                          const example =
                              '[{"name":"consultar_sensor","description":"Consulta un sensor propio","url":"https://example.com/api/sensor","method":"GET","parameters":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}}]';
                          customFunctionsController.text = example;
                          prefs?.setString("assistantCustomFunctions", example);
                          setState(() {});
                        },
                        icon: const Icon(Icons.data_object_rounded)),
                    border: const OutlineInputBorder())),
          ],
          const SizedBox(height: 32),
        ]));
  }
}
