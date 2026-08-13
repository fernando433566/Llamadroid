import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:ollama_app/l10n/app_localizations.dart';
import 'main.dart';

import 'package:ollama_dart/ollama_dart.dart' as llama;
// ignore: depend_on_referenced_packages
import 'package:flutter_chat_types/flutter_chat_types.dart' as types;
import 'package:uuid/uuid.dart';

Future<bool> _waitForLocalOllama() async {
  if (activeConnectionMode != connectionModeLocal) return true;
  await startConfiguredLocalServer();
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      final response = await http
          .get(Uri.parse("$localOllamaHost/api/tags"))
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) return true;
    } catch (_) {}
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return false;
}

Future<Set<String>> _modelCapabilitiesFromServer(
    String modelName, bool fallbackVision) async {
  final detected = <String>{if (fallbackVision) 'vision'};
  try {
    final response = await http
        .post(Uri.parse('$host/api/show'),
            headers: {
              ...activeHostHeaders(),
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'model': modelName}))
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      return detected;
    }
    final decoded = jsonDecode(response.body);
    if (decoded is Map && decoded['capabilities'] is List) {
      detected.addAll((decoded['capabilities'] as List)
          .map((value) => value.toString().toLowerCase()));
    }
  } catch (_) {}
  return detected;
}

Future<bool> _downloadOllamaModel(BuildContext context) async {
  final modelName = await prompt(
    context,
    title: appText("Download model", "Descargar modelo"),
    description: appText(
        "Enter the exact model name. In local mode it will be stored on this device.",
        "Introduce el nombre exacto del modelo. En modo local se guardará en este dispositivo."),
    placeholder: "qwen3.5:0.8b",
    valueIfCanceled: "",
    validator: (value) async => value.trim().isNotEmpty,
    validatorError:
        appText("Enter a model name", "Introduce un nombre de modelo"),
  );
  if (modelName.trim().isEmpty || !context.mounted) return false;
  if (!await _waitForLocalOllama()) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(appText("The local Ollama server did not start.",
            "El servidor Ollama local no llegó a iniciarse.")),
        showCloseIcon: true,
      ));
    }
    return false;
  }
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ModelPullDialog(modelName: modelName.trim()),
      ) ??
      false;
}

Future<bool> _deleteOllamaModel(BuildContext context, String modelName) async {
  final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          icon: const Icon(Icons.delete_outline_rounded),
          title: Text(appText("Delete model", "Eliminar modelo")),
          content: Text(appText(
              "Delete $modelName from the selected Ollama server?",
              "¿Quieres eliminar $modelName del servidor Ollama seleccionado?")),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(appText("Cancel", "Cancelar")),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(appText("Delete", "Eliminar")),
            ),
          ],
        ),
      ) ??
      false;
  if (!confirmed) return false;
  try {
    final response = await http
        .delete(
          Uri.parse("$host/api/delete"),
          headers: <String, String>{
            ...activeHostHeaders(),
            "Content-Type": "application/json",
          },
          body: jsonEncode(<String, String>{"model": modelName}),
        )
        .timeout(const Duration(minutes: 2));
    if (response.statusCode >= 200 && response.statusCode < 300) return true;
    throw HttpException("${response.statusCode}: ${response.body.trim()}");
  } catch (deleteError) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(appText("Could not delete $modelName: $deleteError",
            "No se pudo eliminar $modelName: $deleteError")),
        showCloseIcon: true,
      ));
    }
    return false;
  }
}

Future<void> _importCustomGguf(BuildContext context) async {
  final modelSelection = await FilePicker.pickFiles(
    dialogTitle: appText("Select the GGUF model", "Selecciona el modelo GGUF"),
    type: FileType.custom,
    allowedExtensions: const ["gguf"],
    allowMultiple: false,
    withData: false,
  );
  if (modelSelection == null || modelSelection.files.isEmpty) return;
  final modelFile = modelSelection.files.single;
  if (modelFile.path == null) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(appText(
              "Android did not provide access to the selected file.",
              "Android no proporcionó acceso al archivo elegido.")),
        ),
      );
    }
    return;
  }

  final suggestedName = modelFile.name
      .replaceFirst(RegExp(r"\.gguf$", caseSensitive: false), "")
      .toLowerCase()
      .replaceAll(RegExp(r"[^a-z0-9._-]+"), "-");
  final modelName = await prompt(
    context,
    title: appText("Custom model name", "Nombre del modelo personalizado"),
    description: appText("Choose the name shown in Ollama. You may add a tag.",
        "Elige el nombre con el que aparecerá en Ollama. Puedes añadir una etiqueta."),
    placeholder: "mi-modelo:latest",
    value: suggestedName,
    valueIfCanceled: "",
    validator: (content) async {
      final name = content.trim();
      return name.isNotEmpty &&
          !name.contains(RegExp(r"\s")) &&
          !name.startsWith(":") &&
          !name.endsWith(":");
    },
    validatorError: appText(
        "Enter a valid model name", "Introduce un nombre de modelo válido"),
  );
  if (modelName.trim().isEmpty || !context.mounted) return;

  final projectorChoice = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      icon: const Icon(Icons.image_outlined),
      title: Text(
          appText("Optional multimodal file", "Archivo multimodal opcional")),
      content: Text(
        appText(
          "If this model needs a GGUF vision projector (mmproj), select it separately. For text models or GGUF files that include it, continue without an additional file.",
          "Si este modelo necesita un proyector de visión GGUF (mmproj), selecciónalo por separado. Para modelos de texto o GGUF que ya lo incorporan, continúa sin archivo adicional.",
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(appText("Cancel", "Cancelar")),
        ),
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: Text(appText("Model only", "Solo el modelo")),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: Text(appText("Add mmproj", "Añadir mmproj")),
        ),
      ],
    ),
  );
  if (projectorChoice == null || !context.mounted) return;

  PlatformFile? projectorFile;
  if (projectorChoice) {
    final projectorSelection = await FilePicker.pickFiles(
      dialogTitle: appText("Select the multimodal GGUF projector",
          "Selecciona el proyector multimodal GGUF"),
      type: FileType.custom,
      allowedExtensions: const ["gguf"],
      allowMultiple: false,
      withData: false,
    );
    if (projectorSelection == null || projectorSelection.files.isEmpty) return;
    projectorFile = projectorSelection.files.single;
    if (projectorFile!.path == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(appText(
              "Android did not provide access to the selected projector.",
              "Android no proporcionó acceso al proyector elegido.",
            )),
          ),
        );
      }
      return;
    }
  }

  if (!context.mounted) return;
  final imported = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CustomModelImportDialog(
          modelName: modelName.trim(),
          modelFile: modelFile,
          projectorFile: projectorFile,
        ),
      ) ??
      false;
  if (imported && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          appText("${modelName.trim()} imported. Open the selector to use it.",
              "${modelName.trim()} importado. Abre el selector para utilizarlo."),
        ),
        showCloseIcon: true,
      ),
    );
  }
}

void setModel(BuildContext context, Function setState) {
  final pageContext = context;
  List<String> models = [];
  List<String> modelsReal = [];
  List<bool> modal = [];
  int usedIndex = -1;
  int addIndex = -1;
  bool loaded = false;
  Function? setModalState;
  void load() async {
    try {
      if (!await _waitForLocalOllama()) {
        throw const HttpException("Ollama local no responde");
      }
      var list = await llama.OllamaClient(
        headers: activeHostHeaders(),
        baseUrl: "$host/api",
      ).listModels().timeout(const Duration(seconds: 20));
      for (var i = 0; i < list.models!.length; i++) {
        models.add(list.models![i].model!.split(":")[0]);
        modelsReal.add(list.models![i].model!);
        modal.add((list.models![i].details!.families ?? []).contains("clip"));
      }
      addIndex = models.length;
      // ignore: use_build_context_synchronously
      models.add(AppLocalizations.of(context)!.modelDialogAddModel);
      // ignore: use_build_context_synchronously
      modelsReal.add(AppLocalizations.of(context)!.modelDialogAddModel);
      modal.add(false);
      for (var i = 0; i < modelsReal.length; i++) {
        if (modelsReal[i] == model) {
          usedIndex = i;
        }
      }
      loaded = true;
      setModalState!(() {});
    } catch (_) {
      // ignore: use_build_context_synchronously
      Navigator.of(context).pop();
      // ignore: use_build_context_synchronously
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          // ignore: use_build_context_synchronously
          content: Text(
            // ignore: use_build_context_synchronously
            AppLocalizations.of(context)!.settingsHostInvalid("timeout"),
          ),
          showCloseIcon: true,
        ),
      );
    }
  }

  load();

  if (useModel) return;
  HapticFeedback.selectionClick();

  var content = StatefulBuilder(
    builder: (context, setLocalState) {
      setModalState = setLocalState;
      return PopScope(
        canPop: loaded,
        onPopInvoked: (didPop) {
          if (!loaded) return;
          if (usedIndex >= 0 &&
              modelsReal[usedIndex] != model &&
              (prefs!.getBool("resetOnModelSelect") ?? true)) {
            messages = [];
          }
          model = (usedIndex >= 0) ? modelsReal[usedIndex] : null;
          chatAllowed = !(model == null);
          if (model != null) {
            prefs?.setString("model", model!);
            final selectedName = model!;
            final initiallyDetected = <String>{
              if (usedIndex >= 0 && modal[usedIndex]) "vision"
            };
            selectedModelCapabilities =
                effectiveModelCapabilities(selectedName, initiallyDetected);
            multimodal =
                hasModelAttachmentCapabilities(selectedModelCapabilities);
            unawaited(_modelCapabilitiesFromServer(
                    selectedName, usedIndex >= 0 && modal[usedIndex])
                .then((detected) async {
              await rememberDetectedModelCapabilities(selectedName, detected);
              if (model != selectedName) return;
              selectedModelCapabilities =
                  effectiveModelCapabilities(selectedName, detected);
              multimodal =
                  hasModelAttachmentCapabilities(selectedModelCapabilities);
              await prefs?.setStringList("modelCapabilities",
                  selectedModelCapabilities.toList()..sort());
              await prefs?.setBool("multimodal", multimodal);
              setState(() {});
            }));
          } else {
            prefs?.remove("model");
            selectedModelCapabilities = <String>{};
            multimodal = false;
          }
          prefs?.setStringList(
              "modelCapabilities", selectedModelCapabilities.toList()..sort());
          prefs?.setBool("multimodal", multimodal);
          setState(() {});
        },
        child: Container(
          width:
              ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
                      MediaQuery.of(context).size.width >= 1000)
                  ? null
                  : double.infinity,
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                ? 16
                : 12,
          ),
          child: (!loaded)
              ? const LinearProgressIndicator()
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: ((Platform.isWindows ||
                                  Platform.isLinux ||
                                  Platform.isMacOS) &&
                              MediaQuery.of(context).size.width >= 1000)
                          ? 300
                          : double.infinity,
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.4,
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.vertical,
                        child: Wrap(
                          spacing: ((Platform.isWindows ||
                                      Platform.isLinux ||
                                      Platform.isMacOS) &&
                                  MediaQuery.of(context).size.width >= 1000)
                              ? 10.0
                              : 5.0,
                          runSpacing: (Platform.isWindows ||
                                  Platform.isLinux ||
                                  Platform.isMacOS)
                              ? (MediaQuery.of(context).size.width >= 1000)
                                  ? 10.0
                                  : 5.0
                              : 0.0,
                          alignment: WrapAlignment.center,
                          children: List<Widget>.generate(models.length, (
                            int index,
                          ) {
                            Future<void> removeModel() async {
                              final removed = await _deleteOllamaModel(
                                  pageContext, modelsReal[index]);
                              if (!removed || !pageContext.mounted) return;
                              final removedModel = modelsReal[index];
                              if (model == removedModel) {
                                model = null;
                                chatAllowed = false;
                                selectedModelCapabilities.clear();
                                await prefs?.remove("model");
                              }
                              models.removeAt(index);
                              modelsReal.removeAt(index);
                              modal.removeAt(index);
                              addIndex -= 1;
                              if (usedIndex == index) usedIndex = -1;
                              if (usedIndex > index) usedIndex -= 1;
                              setLocalState(() {});
                              setState(() {});
                            }

                            return GestureDetector(
                              onLongPress:
                                  addIndex == index ? null : removeModel,
                              child: InputChip(
                                deleteButtonTooltipMessage: "Eliminar modelo",
                                onDeleted:
                                    addIndex == index ? null : removeModel,
                                label: Text(
                                  (prefs!.getBool("modelTags") ?? false)
                                      ? modelsReal[index]
                                      : models[index],
                                ),
                                selected: usedIndex == index,
                                avatar: (usedIndex == index)
                                    ? null
                                    : (addIndex == index)
                                        ? const Icon(Icons.add_rounded)
                                        : ((recommendedModels
                                                .contains(models[index]))
                                            ? const Icon(Icons.star_rounded)
                                            : ((modal[index])
                                                ? const Icon(
                                                    Icons.collections_rounded,
                                                  )
                                                : null)),
                                checkmarkColor: (usedIndex == index)
                                    ? ((MediaQuery.of(
                                              context,
                                            ).platformBrightness ==
                                            Brightness.light)
                                        ? (theme ?? ThemeData())
                                            .colorScheme
                                            .secondary
                                        : (themeDark ?? ThemeData.dark())
                                            .colorScheme
                                            .secondary)
                                    : null,
                                labelStyle: (usedIndex == index)
                                    ? TextStyle(
                                        color: (MediaQuery.of(
                                                  context,
                                                ).platformBrightness ==
                                                Brightness.light)
                                            ? (theme ?? ThemeData())
                                                .colorScheme
                                                .secondary
                                            : (themeDark ?? ThemeData.dark())
                                                .colorScheme
                                                .secondary,
                                      )
                                    : null,
                                selectedColor: (MediaQuery.of(context)
                                            .platformBrightness ==
                                        Brightness.light)
                                    ? (theme ?? ThemeData()).colorScheme.primary
                                    : (themeDark ?? ThemeData.dark())
                                        .colorScheme
                                        .primary,
                                onSelected: (bool selected) async {
                                  if (addIndex == index) {
                                    Navigator.of(context).pop();
                                    if (activeConnectionMode ==
                                            connectionModeLocal &&
                                        ggufImportEnabled()) {
                                      final importGguf =
                                          await showModalBottomSheet<bool>(
                                        context: pageContext,
                                        showDragHandle: true,
                                        builder: (sheetContext) => SafeArea(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              ListTile(
                                                leading: const Icon(Icons
                                                    .cloud_download_rounded),
                                                title: const Text(
                                                    "Descargar desde Ollama"),
                                                subtitle: const Text(
                                                    "Introduce el nombre exacto del modelo en el cuadro de descarga."),
                                                onTap: () => Navigator.pop(
                                                    sheetContext, false),
                                              ),
                                              ListTile(
                                                key: const ValueKey(
                                                    "import-custom-gguf"),
                                                leading: const Icon(
                                                    Icons.file_open_rounded),
                                                title: const Text(
                                                    "Importar modelo GGUF"),
                                                subtitle: const Text(
                                                    "Modelo local y proyector multimodal opcional."),
                                                onTap: () => Navigator.pop(
                                                    sheetContext, true),
                                              ),
                                            ],
                                          ),
                                        ),
                                      );
                                      if (importGguf == true &&
                                          pageContext.mounted) {
                                        await _importCustomGguf(pageContext);
                                      } else if (pageContext.mounted) {
                                        await _downloadOllamaModel(pageContext);
                                      }
                                      return;
                                    }
                                    await _downloadOllamaModel(pageContext);
                                    return;
                                  }
                                  if (!chatAllowed && model != null) {
                                    return;
                                  }
                                  setLocalState(() {
                                    usedIndex = selected ? index : -1;
                                  });
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      );
    },
  );

  if ((Platform.isWindows || Platform.isLinux || Platform.isMacOS) &&
      MediaQuery.of(context).size.width >= 1000) {
    showDialog(
      context: context,
      builder: (context) {
        return Dialog(alignment: Alignment.topCenter, child: content);
      },
    );
  } else {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(top: false, child: content),
    );
  }
}

class _ModelPullDialog extends StatefulWidget {
  const _ModelPullDialog({required this.modelName});

  final String modelName;

  @override
  State<_ModelPullDialog> createState() => _ModelPullDialogState();
}

class _ModelPullDialogState extends State<_ModelPullDialog> {
  http.Client? client;
  String status = "Preparando descarga…";
  double? progress;
  String? error;
  bool finished = false;

  @override
  void initState() {
    super.initState();
    unawaited(_pull());
  }

  Future<void> _pull() async {
    final activeClient = http.Client();
    client = activeClient;
    try {
      final request = http.Request("POST", Uri.parse("$host/api/pull"))
        ..headers.addAll(<String, String>{
          ...activeHostHeaders(),
          "Content-Type": "application/json",
        })
        ..body = jsonEncode(<String, dynamic>{
          "model": widget.modelName,
          "stream": true,
        });
      final response =
          await activeClient.send(request).timeout(const Duration(seconds: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw HttpException("${response.statusCode}: $body");
      }
      await response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach((line) {
        if (line.trim().isEmpty || !mounted) return;
        final event = jsonDecode(line) as Map<String, dynamic>;
        final total = (event["total"] as num?)?.toDouble();
        final completed = (event["completed"] as num?)?.toDouble();
        setState(() {
          status = event["status"]?.toString() ?? status;
          progress = total != null && total > 0 && completed != null
              ? (completed / total).clamp(0.0, 1.0)
              : null;
        });
      });
      if (!mounted) return;
      setState(() {
        finished = true;
        progress = 1;
        status = "${widget.modelName} descargado";
      });
    } catch (pullError) {
      if (!mounted) return;
      setState(() {
        error = pullError.toString();
        status = "No se pudo descargar el modelo";
      });
    } finally {
      client = null;
      activeClient.close();
    }
  }

  @override
  void dispose() {
    client?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text("Descargando ${widget.modelName}"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 16),
            Text(status),
            if (error != null) ...[
              const SizedBox(height: 8),
              SelectableText(error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
        actions: [
          if (!finished && error == null)
            TextButton(
              onPressed: () {
                client?.close();
                Navigator.pop(context, false);
              },
              child: const Text("Cancelar"),
            ),
          if (finished || error != null)
            FilledButton(
              onPressed: () => Navigator.pop(context, finished),
              child: const Text("Cerrar"),
            ),
        ],
      );
}

void saveChat(String uuid, Function setState) async {
  int index = -1;
  for (var i = 0; i < (prefs!.getStringList("chats") ?? []).length; i++) {
    if (jsonDecode((prefs!.getStringList("chats") ?? [])[i])["uuid"] == uuid) {
      index = i;
    }
  }
  if (index == -1) return;
  List<Map<String, String>> history = [];
  for (var i = 0; i < messages.length; i++) {
    if (messages[i] is types.CustomMessage &&
        messages[i].metadata?["kind"] == "thinking") {
      history.add({
        "role": "assistant",
        "type": "thinking",
        "content": (messages[i].metadata?["thinking"] ?? "").toString(),
      });
    } else if ((jsonDecode(jsonEncode(messages[i])) as Map).containsKey(
      "text",
    )) {
      history.add({
        "role": (messages[i].author == user) ? "user" : "assistant",
        "content": jsonDecode(jsonEncode(messages[i]))["text"],
      });
    } else {
      var uri = jsonDecode(jsonEncode(messages[i]))["uri"] as String;
      String content = await imageContentFromUri(uri);
      history.add({
        "role": (messages[i].author == user) ? "user" : "assistant",
        "type": "image",
        "name": (messages[i] as types.ImageMessage).name,
        "size": (messages[i] as types.ImageMessage).size.toString(),
        "content": content,
      });
    }
  }
  if (messages.isEmpty && uuid == chatUuid) {
    for (var i = 0; i < (prefs!.getStringList("chats") ?? []).length; i++) {
      if (jsonDecode((prefs!.getStringList("chats") ?? [])[i])["uuid"] ==
          chatUuid) {
        List<String> tmp = prefs!.getStringList("chats")!;
        tmp.removeAt(i);
        prefs!.setStringList("chats", tmp);
        chatUuid = null;
        return;
      }
    }
  }
  if (jsonDecode(
        (prefs!.getStringList("chats") ?? [])[index],
      )["messages"]
          .length >=
      1) {
    if (jsonDecode(
          jsonDecode((prefs!.getStringList("chats") ?? [])[index])["messages"],
        )[0]["role"] ==
        "system") {
      history.add({
        "role": "system",
        "content": jsonDecode(
          jsonDecode((prefs!.getStringList("chats") ?? [])[index])["messages"],
        )[0]["content"],
      });
    }
  } else {
    var system = prefs?.getString("system") ?? "You are a helpful assistant";
    if (prefs!.getBool("noMarkdown") ?? false) {
      system +=
          " You must not use markdown or any other formatting language in any way!";
    }
    history.add({"role": "system", "content": system});
  }
  history = history.reversed.toList();
  List<String> tmp = prefs!.getStringList("chats") ?? [];
  tmp.removeAt(index);
  tmp.insert(
    0,
    jsonEncode({
      "title": jsonDecode(
        (prefs!.getStringList("chats") ?? [])[index],
      )["title"],
      "uuid": uuid,
      "model": model,
      "messages": jsonEncode(history),
    }),
  );
  prefs!.setStringList("chats", tmp);
  setState(() {});
}

void loadChat(String uuid, Function setState) {
  int index = -1;
  for (var i = 0; i < (prefs!.getStringList("chats") ?? []).length; i++) {
    if (jsonDecode((prefs!.getStringList("chats") ?? [])[i])["uuid"] == uuid) {
      index = i;
    }
  }
  if (index == -1) return;
  messages = [];
  model = null;
  setState(() {});
  var history = jsonDecode(
    jsonDecode((prefs!.getStringList("chats") ?? [])[index])["messages"],
  );
  for (var i = 0; i < history.length; i++) {
    if (history[i]["role"] != "system") {
      if ((history[i] as Map).containsKey("type") &&
          history[i]["type"] == "thinking") {
        messages.insert(
          0,
          types.CustomMessage(
            author: assistant,
            id: const Uuid().v4(),
            metadata: {
              "kind": "thinking",
              "thinking": history[i]["content"],
              "isThinking": false,
            },
          ),
        );
      } else if ((history[i] as Map).containsKey("type") &&
          history[i]["type"] == "image") {
        messages.insert(
          0,
          types.ImageMessage(
            author: (history[i]["role"] == "user") ? user : assistant,
            id: const Uuid().v4(),
            name: history[i]["name"],
            size: int.parse(history[i]["size"]),
            uri: "data:image/jpeg;base64,${history[i]["content"]}",
          ),
        );
      } else {
        messages.insert(
          0,
          types.TextMessage(
            author: (history[i]["role"] == "user") ? user : assistant,
            id: const Uuid().v4(),
            text: history[i]["content"],
          ),
        );
      }
    }
  }
  model = jsonDecode((prefs!.getStringList("chats") ?? [])[index])["model"];
  setState(() {});
}

Future<String> prompt(
  BuildContext context, {
  String description = "",
  String value = "",
  String title = "",
  String? valueIfCanceled,
  TextInputType keyboard = TextInputType.text,
  Icon? prefixIcon,
  int maxLines = 1,
  String? uuid,
  Future<bool> Function(String content)? validator,
  String? validatorError,
  String? placeholder,
}) async {
  var returnText = (valueIfCanceled != null) ? valueIfCanceled : value;
  final TextEditingController controller = TextEditingController(text: value);
  bool loading = false;
  String? error;
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (context) {
      return StatefulBuilder(
        builder: (context, setLocalState) {
          return PopScope(
            child: Container(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom:
                    (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
                        ? 16
                        : max(MediaQuery.of(context).viewInsets.bottom,
                                MediaQuery.of(context).viewPadding.bottom) +
                            16,
              ),
              width: double.infinity,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  (title != "")
                      ? Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        )
                      : const SizedBox.shrink(),
                  (title != "") ? const Divider() : const SizedBox.shrink(),
                  (description != "")
                      ? Text(description)
                      : const SizedBox.shrink(),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    keyboardType: keyboard,
                    maxLines: maxLines,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      hintText: placeholder,
                      errorText: error,
                      suffixIcon: IconButton(
                        onPressed: () async {
                          if (validator != null) {
                            setLocalState(() {
                              error = null;
                            });
                            bool valid = await validator(controller.text);
                            if (!valid) {
                              setLocalState(() {
                                error = validatorError;
                              });
                              return;
                            }
                          }
                          returnText = controller.text;
                          // ignore: use_build_context_synchronously
                          Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.save_rounded),
                      ),
                      prefixIcon: (title ==
                                  AppLocalizations.of(
                                    context,
                                  )!
                                      .dialogEnterNewTitle &&
                              uuid != null)
                          ? IconButton(
                              onPressed: () async {
                                setLocalState(() {
                                  loading = true;
                                });
                                for (var i = 0;
                                    i <
                                        (prefs!.getStringList("chats") ?? [])
                                            .length;
                                    i++) {
                                  if (jsonDecode(
                                        (prefs!.getStringList("chats") ??
                                            [])[i],
                                      )["uuid"] ==
                                      uuid) {
                                    try {
                                      List history = [];
                                      var tmp = jsonDecode(
                                        jsonDecode(
                                          (prefs!.getStringList("chats") ??
                                              [])[i],
                                        )["messages"],
                                      );
                                      for (var j = 0; j < tmp.length; j++) {
                                        if (tmp[j]["text"] == null) {
                                          continue;
                                        }
                                        history.add(tmp[j]["text"]);
                                      }
                                      if (history.isEmpty) {
                                        controller.text = AppLocalizations.of(
                                          context,
                                        )!
                                            .imageOnlyConversation;
                                        setLocalState(() {
                                          loading = false;
                                        });
                                        return;
                                      }

                                      final generated =
                                          await llama.OllamaClient(
                                        headers: activeHostHeaders(),
                                        baseUrl: "$host/api",
                                      ).generateCompletion(
                                        request:
                                            llama.GenerateCompletionRequest(
                                          model: model!,
                                          prompt:
                                              "You must not use markdown or any other formatting language! Create a short title for the subject of the conversation described in the following json object. It is not allowed to be too general; no 'Assistance', 'Help' or similar!\n\n```json\n${jsonEncode(history)}\n```",
                                        ),
                                      );
                                      var title = generated.response!
                                          .replaceAll("*", "")
                                          .replaceAll("_", "")
                                          .trim();
                                      controller.text = title;
                                      setLocalState(() {
                                        loading = false;
                                      });
                                    } catch (_) {}
                                    break;
                                  }
                                }
                              },
                              icon: const Icon(Icons.auto_awesome_rounded),
                            )
                          : prefixIcon,
                    ),
                  ),
                  SizedBox(
                    height: 3,
                    child: (loading)
                        ? const LinearProgressIndicator()
                        : const SizedBox.shrink(),
                  ),
                  (MediaQuery.of(context).viewInsets.bottom != 0)
                      ? const SizedBox(height: 16)
                      : const SizedBox.shrink(),
                ],
              ),
            ),
          );
        },
      );
    },
  );
  return returnText;
}

class _CustomModelImportDialog extends StatefulWidget {
  const _CustomModelImportDialog(
      {required this.modelName,
      required this.modelFile,
      required this.projectorFile});

  final String modelName;
  final PlatformFile modelFile;
  final PlatformFile? projectorFile;

  @override
  State<_CustomModelImportDialog> createState() =>
      _CustomModelImportDialogState();
}

class _CustomModelImportDialogState extends State<_CustomModelImportDialog> {
  final http.Client client = http.Client();
  String status = "Preparando importación…";
  int uploadedBytes = 0;
  int totalBytes = 0;
  String? error;
  bool cancelled = false;

  double? get progress =>
      totalBytes <= 0 ? null : (uploadedBytes / totalBytes).clamp(0.0, 1.0);

  @override
  void initState() {
    super.initState();
    totalBytes = widget.modelFile.size + (widget.projectorFile?.size ?? 0);
    unawaited(_import());
  }

  String _apiError(String body, int statusCode) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map && decoded["error"] != null) {
        return decoded["error"].toString();
      }
    } catch (_) {}
    return body.trim().isEmpty ? "HTTP $statusCode" : body.trim();
  }

  Future<String> _upload(PlatformFile platformFile, String label) async {
    final path = platformFile.path!;
    final file = File(path);
    if (!await file.exists())
      throw FileSystemException("Archivo no encontrado", path);
    if (mounted) setState(() => status = "Calculando SHA-256 de $label…");
    final digest = await sha256.bind(file.openRead()).first;
    if (cancelled) throw const HttpException("Importación cancelada");
    final digestName = "sha256:$digest";
    final blobUri = Uri.parse("$host/api/blobs/$digestName");
    try {
      final existing = await client
          .head(blobUri, headers: activeHostHeaders())
          .timeout(const Duration(seconds: 30));
      if (existing.statusCode >= 200 && existing.statusCode < 300) {
        uploadedBytes += platformFile.size;
        if (mounted) setState(() => status = "$label ya estaba almacenado.");
        return digestName;
      }
    } catch (_) {
      if (cancelled) throw const HttpException("Importación cancelada");
    }

    if (mounted) setState(() => status = "Subiendo $label…");
    final request = http.StreamedRequest("POST", blobUri)
      ..headers.addAll(activeHostHeaders())
      ..contentLength = await file.length();
    final responseFuture = client.send(request);
    await for (final chunk in file.openRead()) {
      if (cancelled) throw const HttpException("Importación cancelada");
      request.sink.add(chunk);
      uploadedBytes += chunk.length;
      if (mounted) setState(() {});
    }
    await request.sink.close();
    final streamedResponse =
        await responseFuture.timeout(const Duration(minutes: 30));
    final body = await streamedResponse.stream.bytesToString();
    if (streamedResponse.statusCode < 200 ||
        streamedResponse.statusCode >= 300) {
      throw HttpException(_apiError(body, streamedResponse.statusCode));
    }
    return digestName;
  }

  String _safeFileName(PlatformFile file, {bool projector = false}) {
    final name = file.name
        .replaceAll("\\", "_")
        .replaceAll("/", "_")
        .replaceAll(RegExp(r"[^A-Za-z0-9._-]"), "_");
    return projector ? "mmproj-$name" : name;
  }

  Future<void> _import() async {
    try {
      final files = <String, String>{};
      files[_safeFileName(widget.modelFile)] =
          await _upload(widget.modelFile, "el modelo");
      final projector = widget.projectorFile;
      if (projector != null) {
        files[_safeFileName(projector, projector: true)] =
            await _upload(projector, "el proyector multimodal");
      }
      if (cancelled) return;
      if (mounted) setState(() => status = "Creando ${widget.modelName}…");
      final response = await client
          .post(Uri.parse("$host/api/create"),
              headers: {
                ...activeHostHeaders(),
                "Content-Type": "application/json"
              },
              body:
                  jsonEncode(customModelCreateRequest(widget.modelName, files)))
          .timeout(const Duration(minutes: 30));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(_apiError(response.body, response.statusCode));
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (importError) {
      if (!mounted || cancelled) return;
      setState(() {
        error = importError.toString();
        status = "No se pudo importar el modelo";
      });
    }
  }

  @override
  void dispose() {
    cancelled = true;
    client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
        canPop: error != null,
        child: AlertDialog(
            title: Text("Importando ${widget.modelName}"),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 16),
              Align(alignment: Alignment.centerLeft, child: Text(status)),
              if (totalBytes > 0) ...[
                const SizedBox(height: 8),
                Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                        "${(uploadedBytes / 1048576).toStringAsFixed(1)} / ${(totalBytes / 1048576).toStringAsFixed(1)} MB",
                        style: Theme.of(context).textTheme.bodySmall))
              ],
              if (error != null) ...[
                const SizedBox(height: 12),
                SelectableText(error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error))
              ]
            ]),
            actions: [
              if (error == null)
                TextButton(
                    onPressed: () {
                      cancelled = true;
                      client.close();
                      Navigator.of(context).pop(false);
                    },
                    child: const Text("Cancelar"))
              else
                FilledButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text("Cerrar"))
            ]));
  }
}
