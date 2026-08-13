import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'main.dart';
import 'server_controller.dart';

AudioRecorder? _activeRecorder;
Completer<void>? _stopRecording;
int _localTtsGeneration = 0;

typedef CapturedAssistantAudio = ({Float32List samples, int sampleRate});

typedef AssistantModelDownloadProgress = void Function(
    String fileName, int receivedBytes, int? totalBytes);

const assistantVoiceModelSources = <String, Map<String, String>>{
  "nemotron": {
    "encoder.onnx":
        "https://huggingface.co/csukuangfj2/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25/resolve/main/encoder.int8.onnx?download=true",
    "decoder.onnx":
        "https://huggingface.co/csukuangfj2/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25/resolve/main/decoder.int8.onnx?download=true",
    "joiner.onnx":
        "https://huggingface.co/csukuangfj2/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25/resolve/main/joiner.int8.onnx?download=true",
    "tokens.txt":
        "https://huggingface.co/csukuangfj2/sherpa-onnx-nemotron-speech-streaming-en-0.6b-560ms-int8-2026-04-25/resolve/main/tokens.txt?download=true",
  },
  "parakeet": {
    "encoder.onnx":
        "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/encoder.int8.onnx?download=true",
    "decoder.onnx":
        "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/decoder.int8.onnx?download=true",
    "joiner.onnx":
        "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/joiner.int8.onnx?download=true",
    "tokens.txt":
        "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8/resolve/main/tokens.txt?download=true",
  },
  "whisper": {
    "encoder.onnx":
        "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-encoder.int8.onnx?download=true",
    "decoder.onnx":
        "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-decoder.int8.onnx?download=true",
    "tokens.txt":
        "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main/small-tokens.txt?download=true",
  },
};

/// Downloads the exact sherpa-onnx graphs used by the bundled runtime.
/// Partial files are retained so a failed mobile download can resume.
Future<String> downloadAssistantVoiceModel(String engine,
    {AssistantModelDownloadProgress? onProgress}) async {
  final sources = assistantVoiceModelSources[engine];
  if (sources == null) throw ArgumentError.value(engine, "engine");
  final support = await getApplicationSupportDirectory();
  final target = Directory(p.join(support.path, "assistant_models", engine));
  await target.create(recursive: true);

  for (final entry in sources.entries) {
    final destination = File(p.join(target.path, entry.key));
    if (await destination.exists() && await destination.length() > 0) {
      onProgress?.call(
          entry.key, await destination.length(), await destination.length());
      continue;
    }
    await _downloadAssistantModelFile(
        Uri.parse(entry.value), destination, onProgress);
  }

  final validationError =
      await validateAssistantVoiceModel(engine, modelRoot: target.path);
  if (validationError != null) {
    throw StateError("El modelo descargado no se pudo abrir: $validationError");
  }
  await prefs?.setString("assistantVoiceModelPath:$engine", target.path);
  return engine == "whisper"
      ? "Whisper Small INT8 instalado correctamente"
      : engine == "nemotron"
          ? "NVIDIA Nemotron Speech instalado correctamente"
          : "NVIDIA Parakeet instalado correctamente";
}

Future<void> _downloadAssistantModelFile(Uri uri, File destination,
    AssistantModelDownloadProgress? onProgress) async {
  final partial = File("${destination.path}.part");
  var existing = await partial.exists() ? await partial.length() : 0;
  final client = http.Client();
  IOSink? sink;
  try {
    final request = http.Request("GET", uri);
    if (existing > 0) request.headers["Range"] = "bytes=$existing-";
    final response = await client.send(request);
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException(
          "HTTP ${response.statusCode} al descargar ${destination.uri.pathSegments.last}",
          uri: uri);
    }
    final resumed = response.statusCode == 206 && existing > 0;
    if (!resumed) existing = 0;
    final expected = response.contentLength == null
        ? null
        : existing + response.contentLength!;
    sink = partial.openWrite(mode: resumed ? FileMode.append : FileMode.write);
    var received = existing;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(destination.uri.pathSegments.last, received, expected);
    }
    await sink.flush();
    await sink.close();
    sink = null;
    if (expected != null && await partial.length() != expected) {
      throw const HttpException("La descarga terminó antes de completarse");
    }
    if (await destination.exists()) await destination.delete();
    await partial.rename(destination.path);
  } finally {
    await sink?.close();
    client.close();
  }
}

Future<void> stopLocalAssistantVoiceEngine() async {
  _localTtsGeneration++;
  if (!(_stopRecording?.isCompleted ?? true)) _stopRecording?.complete();
  await _activeRecorder?.stop();
}

class StreamingSpeechChunker {
  String _buffer = "";

  List<String> add(String delta) {
    _buffer += delta;
    final chunks = <String>[];
    final boundary = RegExp(r'''[.!?;]+(?:["»”')\]]+)?(?:\s+|$)|\n+''');
    while (true) {
      final match = boundary.firstMatch(_buffer);
      if (match == null) break;
      final chunk = cleanTextForSpeech(_buffer.substring(0, match.end));
      _buffer = _buffer.substring(match.end);
      if (chunk.isNotEmpty) chunks.add(chunk);
    }
    if (_buffer.length > 220) {
      final split = _buffer.lastIndexOf(RegExp(r'[, :]'), 180);
      if (split > 40) {
        final chunk = cleanTextForSpeech(_buffer.substring(0, split + 1));
        _buffer = _buffer.substring(split + 1);
        if (chunk.isNotEmpty) chunks.add(chunk);
      }
    }
    return chunks;
  }

  String takeRemainder() {
    final remainder = cleanTextForSpeech(_buffer);
    _buffer = "";
    return remainder;
  }
}

String cleanTextForSpeech(String source) => source
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^\)]+\)'), (match) => match[1]!)
    .replaceAll(RegExp(r'[`*_#>]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

String assistantSttLanguagePreference() =>
    prefs?.getString("assistantSttLanguage") ?? "auto";

String? assistantDeviceSttLanguage() {
  final language = assistantSttLanguagePreference().trim();
  return language.isEmpty || language == "auto" ? null : language;
}

String assistantWhisperLanguage() {
  final language = assistantSttLanguagePreference().trim();
  if (language.isEmpty || language == "auto") return "";
  return language.split(RegExp(r'[-_]')).first.toLowerCase();
}

Future<String> importAssistantVoiceModel(String engine) async {
  final picked = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: const ["onnx", "txt", "json", "bin"]);
  if (picked == null) return "Importación cancelada";
  if (engine == "whisper" &&
      isRTranslatorWhisperPackage(picked.files.map((file) => file.name))) {
    return "Este paquete usa el formato RTranslator (initializer, cache y "
        "detokenizer ONNX). No es compatible con el runtime sherpa-onnx de "
        "la app y no se puede solucionar añadiendo tokens.txt. Descarga el "
        "paquete Whisper de sherpa-onnx indicado en esta pantalla.";
  }
  final support = await getApplicationSupportDirectory();
  final target = Directory(p.join(support.path, "assistant_models", engine));
  await target.create(recursive: true);
  final mappings = engine == "parakeet" || engine == "nemotron"
      ? <String, String>{
          "encoder": "encoder.onnx",
          "decoder": "decoder.onnx",
          "joiner": "joiner.onnx",
          "tokens": "tokens.txt",
        }
      : engine == "whisper"
          ? <String, String>{
              "encoder": "encoder.onnx",
              "decoder": "decoder.onnx",
              "tokens": "tokens.txt",
            }
          : <String, String>{
              "duration_predictor": "duration_predictor.onnx",
              "text_encoder": "text_encoder.onnx",
              "vector_estimator": "vector_estimator.onnx",
              "vocoder": "vocoder.onnx",
              "tts.json": "tts.json",
              "unicode_indexer": "unicode_indexer.bin",
              "voice": "voice.bin",
            };
  for (final entry in mappings.entries) {
    final candidates = picked.files
        .where((file) =>
            file.path != null &&
            matchesAssistantModelFile(file.name.toLowerCase(), entry.key))
        .toList()
      ..sort((left, right) {
        final leftInt8 = left.name.toLowerCase().contains("int8") ? 0 : 1;
        final rightInt8 = right.name.toLowerCase().contains("int8") ? 0 : 1;
        return leftInt8.compareTo(rightInt8);
      });
    if (candidates.isEmpty) continue;
    await File(candidates.first.path!).copy(p.join(target.path, entry.value));
  }
  final missing = mappings.values
      .where((name) => !File(p.join(target.path, name)).existsSync())
      .toList();
  if (missing.isNotEmpty) {
    return "Faltan archivos: ${missing.join(', ')}";
  }
  final validationError = await validateAssistantVoiceModel(
    engine,
    modelRoot: target.path,
  );
  if (validationError != null) {
    return "Los archivos están completos, pero el motor no pudo abrirlos: "
        "$validationError";
  }
  await prefs?.setString("assistantVoiceModelPath:$engine", target.path);
  return engine == "parakeet"
      ? "Parakeet instalado correctamente"
      : engine == "nemotron"
          ? "Nemotron instalado correctamente"
          : engine == "whisper"
              ? "Whisper instalado correctamente"
              : "Supertonic instalado correctamente";
}

bool matchesAssistantModelFile(String fileName, String modelPart) {
  return fileName == modelPart ||
      fileName.startsWith(modelPart) ||
      fileName.contains("-$modelPart") ||
      fileName.contains("_$modelPart");
}

bool isRTranslatorWhisperPackage(Iterable<String> fileNames) {
  final names = fileNames.map((name) => name.toLowerCase()).toSet();
  return names.any((name) => name.contains("whisper_detokenizer")) &&
      names.any((name) =>
          name.contains("whisper_initializer") ||
          name.contains("whisper_cache_initializer"));
}

/// Loads the complete native inference pipeline, not just the file names.
/// Returns null on success or a user-facing diagnostic on failure.
Future<String?> validateAssistantVoiceModel(String engine,
    {String? modelRoot}) async {
  final root = modelRoot ?? prefs?.getString("assistantVoiceModelPath:$engine");
  if (root == null || root.trim().isEmpty) {
    return "No hay ningún modelo importado";
  }
  final required = _assistantVoiceModelFiles(engine);
  if (required == null) return "Motor desconocido: $engine";
  final missing =
      required.where((name) => !File(p.join(root, name)).existsSync()).toList();
  if (missing.isNotEmpty) return "Faltan archivos: ${missing.join(', ')}";

  try {
    if (engine == "parakeet" || engine == "whisper" || engine == "nemotron") {
      if (engine == "nemotron") {
        await Isolate.run(_OnlineNemotronDecodeTask(
          root: root,
          samples: Float32List(1600),
          sampleRate: 16000,
          numThreads: 2,
        ).run);
      } else {
        await Isolate.run(_OfflineAsrDecodeTask(
          engine: engine,
          root: root,
          samples: Float32List(1600),
          sampleRate: 16000,
          numThreads: 2,
          language: engine == "whisper" ? assistantWhisperLanguage() : "",
        ).run);
      }
    } else {
      await Isolate.run(() {
        sherpa.initBindings();
        final tts = sherpa.OfflineTts(
            sherpa.OfflineTtsConfig(model: _supertonicConfig(root, 2)));
        final audio = tts.generateWithConfig(
            text: "<es>Prueba.</es>",
            config: const sherpa.OfflineTtsGenerationConfig(numSteps: 2));
        tts.free();
        if (audio.samples.isEmpty || audio.sampleRate <= 0) {
          throw StateError("el motor devolvió audio vacío");
        }
      });
    }
    return null;
  } catch (error) {
    return error.toString().replaceFirst("Exception: ", "");
  }
}

List<String>? _assistantVoiceModelFiles(String engine) {
  if (engine == "parakeet" || engine == "nemotron") {
    return const ["encoder.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"];
  }
  if (engine == "whisper") {
    return const ["encoder.onnx", "decoder.onnx", "tokens.txt"];
  }
  if (engine == "supertonic") {
    return const [
      "duration_predictor.onnx",
      "text_encoder.onnx",
      "vector_estimator.onnx",
      "vocoder.onnx",
      "tts.json",
      "unicode_indexer.bin",
      "voice.bin"
    ];
  }
  return null;
}

bool assistantVoiceModelInstalled(String engine) {
  final root = prefs?.getString("assistantVoiceModelPath:$engine");
  if (root == null) return false;
  final required = _assistantVoiceModelFiles(engine);
  if (required == null) return false;
  return required.every((name) => File(p.join(root, name)).existsSync());
}

sherpa.OfflineModelConfig _parakeetConfig(String root, {int numThreads = 4}) =>
    sherpa.OfflineModelConfig(
        transducer: sherpa.OfflineTransducerModelConfig(
          encoder: p.join(root, "encoder.onnx"),
          decoder: p.join(root, "decoder.onnx"),
          joiner: p.join(root, "joiner.onnx"),
        ),
        tokens: p.join(root, "tokens.txt"),
        numThreads: numThreads,
        debug: false,
        modelType: "nemo_transducer");

sherpa.OfflineModelConfig _whisperConfig(String root,
        {required String language, int numThreads = 4}) =>
    sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: p.join(root, "encoder.onnx"),
          decoder: p.join(root, "decoder.onnx"),
          language: language,
          task: "transcribe",
        ),
        tokens: p.join(root, "tokens.txt"),
        numThreads: numThreads,
        debug: false,
        modelType: "whisper");

sherpa.OfflineTtsModelConfig _supertonicConfig(String root, int numThreads) =>
    sherpa.OfflineTtsModelConfig(
        supertonic: sherpa.OfflineTtsSupertonicModelConfig(
          durationPredictor: p.join(root, "duration_predictor.onnx"),
          textEncoder: p.join(root, "text_encoder.onnx"),
          vectorEstimator: p.join(root, "vector_estimator.onnx"),
          vocoder: p.join(root, "vocoder.onnx"),
          ttsJson: p.join(root, "tts.json"),
          unicodeIndexer: p.join(root, "unicode_indexer.bin"),
          voiceStyle: p.join(root, "voice.bin"),
        ),
        numThreads: numThreads,
        debug: false);

/// A sendable isolate task. Keeping this separate prevents the isolate from
/// capturing recorder Completers and StreamSubscriptions from the caller.
class _OfflineAsrDecodeTask {
  const _OfflineAsrDecodeTask({
    required this.engine,
    required this.root,
    required this.samples,
    required this.sampleRate,
    required this.language,
    this.numThreads = 4,
  });

  final String engine;
  final String root;
  final Float32List samples;
  final int sampleRate;
  final String language;
  final int numThreads;

  String run() {
    sherpa.initBindings();
    final config = engine == "whisper"
        ? _whisperConfig(root, language: language, numThreads: numThreads)
        : _parakeetConfig(root, numThreads: numThreads);
    final recognizer =
        sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(model: config));
    final recognitionStream = recognizer.createStream();
    try {
      recognitionStream.acceptWaveform(
          samples: samples, sampleRate: sampleRate);
      recognizer.decode(recognitionStream);
      return recognizer.getResult(recognitionStream).text.trim();
    } finally {
      recognitionStream.free();
      recognizer.free();
    }
  }
}

class _OnlineNemotronDecodeTask {
  const _OnlineNemotronDecodeTask({
    required this.root,
    required this.samples,
    required this.sampleRate,
    this.numThreads = 4,
  });

  final String root;
  final Float32List samples;
  final int sampleRate;
  final int numThreads;

  String run() {
    sherpa.initBindings();
    final model = sherpa.OnlineModelConfig(
      transducer: sherpa.OnlineTransducerModelConfig(
        encoder: p.join(root, "encoder.onnx"),
        decoder: p.join(root, "decoder.onnx"),
        joiner: p.join(root, "joiner.onnx"),
      ),
      tokens: p.join(root, "tokens.txt"),
      numThreads: numThreads,
      debug: false,
    );
    final recognizer = sherpa.OnlineRecognizer(
        sherpa.OnlineRecognizerConfig(model: model, enableEndpoint: false));
    final recognitionStream = recognizer.createStream();
    try {
      recognitionStream.acceptWaveform(
          samples: samples, sampleRate: sampleRate);
      recognitionStream.inputFinished();
      while (recognizer.isReady(recognitionStream)) {
        recognizer.decode(recognitionStream);
      }
      return recognizer.getResult(recognitionStream).text.trim();
    } finally {
      recognitionStream.free();
      recognizer.free();
    }
  }
}

Future<String> recognizeWithParakeet() async {
  return recognizeWithOfflineAsr("parakeet");
}

Future<CapturedAssistantAudio?> captureAssistantAudio(
    {void Function()? onSpeechDetected}) async {
  final recorder = AudioRecorder();
  _activeRecorder = recorder;
  _stopRecording = Completer<void>();
  if (!await recorder.hasPermission()) {
    throw StateError("Se necesita permiso de micrófono.");
  }
  const sampleRate = 16000;
  final bytes = BytesBuilder(copy: false);
  final preRoll = ListQueue<Uint8List>();
  var preRollBytes = 0;
  const maxPreRollBytes = sampleRate * 2;
  var speechStarted = false;
  var speechCandidateChunks = 0;
  var lastSpeech = DateTime.now();
  final recordingStarted = DateTime.now();
  var noiseFloor = 0.003;
  final silenceDuration = Duration(
      milliseconds: (prefs?.getInt("assistantSttSilenceMs") ?? 1200)
          .clamp(800, 3000)
          .toInt());
  final finished = Completer<void>();
  final stream = await recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
      autoGain: false,
      echoCancel: true,
      noiseSuppress: true,
      streamBufferSize: 3200));
  final calibrationEnds = DateTime.now().add(const Duration(milliseconds: 600));
  late final StreamSubscription<Uint8List> subscription;
  subscription = stream.listen((chunk) {
    if (speechStarted) {
      bytes.add(chunk);
    } else {
      final buffered = Uint8List.fromList(chunk);
      preRoll.addLast(buffered);
      preRollBytes += buffered.length;
      while (preRollBytes > maxPreRollBytes && preRoll.length > 1) {
        preRollBytes -= preRoll.removeFirst().length;
      }
    }
    if (chunk.length < 2) return;
    final data = ByteData.sublistView(chunk);
    var energy = 0.0;
    for (var offset = 0; offset + 1 < chunk.length; offset += 2) {
      final sample = data.getInt16(offset, Endian.little) / 32768.0;
      energy += sample * sample;
    }
    final rms = math.sqrt(energy / (chunk.length ~/ 2));
    final now = DateTime.now();
    if (!speechStarted && now.isBefore(calibrationEnds)) {
      noiseFloor = noiseFloor * 0.8 + rms * 0.2;
      speechCandidateChunks = 0;
      return;
    }
    final startThreshold = math.max(0.012, math.min(0.08, noiseFloor * 2.8));
    final continueThreshold = math.max(0.008, math.min(0.05, noiseFloor * 1.6));
    if (!speechStarted && rms > startThreshold) {
      speechCandidateChunks += 1;
      if (speechCandidateChunks >= 2) {
        speechStarted = true;
        lastSpeech = now;
        for (final buffered in preRoll) {
          bytes.add(buffered);
        }
        preRoll.clear();
        preRollBytes = 0;
        onSpeechDetected?.call();
      }
    } else if (!speechStarted) {
      speechCandidateChunks = 0;
      noiseFloor = noiseFloor * 0.98 + rms * 0.02;
    } else if (rms > continueThreshold) {
      lastSpeech = now;
    } else if (now.difference(lastSpeech) > silenceDuration &&
        !finished.isCompleted) {
      finished.complete();
    }
  }, onDone: () {
    if (!finished.isCompleted) finished.complete();
  });
  final watchdog = Timer.periodic(const Duration(milliseconds: 200), (_) {
    final elapsed = DateTime.now().difference(recordingStarted);
    if (!speechStarted && elapsed >= const Duration(seconds: 15)) {
      if (!finished.isCompleted) finished.complete();
    } else if (speechStarted && elapsed >= const Duration(seconds: 60)) {
      if (!finished.isCompleted) finished.complete();
    }
  });
  await Future.any([
    finished.future,
    _stopRecording!.future,
  ]);
  watchdog.cancel();
  await recorder.stop();
  await subscription.cancel();
  _activeRecorder = null;
  final audio = _pcm16ToFloat(bytes.takeBytes());
  if (!speechStarted || audio.isEmpty) return null;
  return (samples: audio, sampleRate: sampleRate);
}

Future<String?> captureAssistantAudioBase64() async {
  final captured = await captureAssistantAudio();
  if (captured == null) return null;
  return encodeCapturedAssistantAudio(captured);
}

String encodeCapturedAssistantAudio(CapturedAssistantAudio captured) =>
    base64Encode(_waveBytes(captured.samples, captured.sampleRate));

Future<String> recognizeCapturedAssistantAudio(
    String engine, CapturedAssistantAudio captured) async {
  final root = prefs?.getString("assistantVoiceModelPath:$engine");
  if (root == null || !assistantVoiceModelInstalled(engine)) {
    throw StateError("Importa primero los archivos del modelo $engine.");
  }
  if (engine == "nemotron") {
    return Isolate.run(_OnlineNemotronDecodeTask(
      root: root,
      samples: captured.samples,
      sampleRate: captured.sampleRate,
    ).run);
  }
  if (engine != "whisper" && engine != "parakeet") {
    throw ArgumentError.value(engine, "engine", "Motor STT local no válido");
  }
  return Isolate.run(_OfflineAsrDecodeTask(
          engine: engine,
          root: root,
          samples: captured.samples,
          sampleRate: captured.sampleRate,
          language: engine == "whisper" ? assistantWhisperLanguage() : "")
      .run);
}

Future<String> recognizeWithOfflineAsr(String engine,
    {void Function()? onSpeechDetected}) async {
  final root = prefs?.getString("assistantVoiceModelPath:$engine");
  if (root == null || !assistantVoiceModelInstalled(engine)) {
    throw StateError("Importa primero los archivos del modelo $engine.");
  }
  final captured =
      await captureAssistantAudio(onSpeechDetected: onSpeechDetected);
  if (captured == null) return "";
  return recognizeCapturedAssistantAudio(engine, captured);
}

Future<void> speakWithSupertonic(String text, String language) async {
  final root = prefs?.getString("assistantVoiceModelPath:supertonic");
  if (root == null || !assistantVoiceModelInstalled("supertonic")) {
    throw StateError("Importa primero los archivos del modelo Supertonic.");
  }
  final generation = _localTtsGeneration;
  final result = await Isolate.run(() {
    sherpa.initBindings();
    final tts = sherpa.OfflineTts(
        sherpa.OfflineTtsConfig(model: _supertonicConfig(root, 4)));
    final audio = tts.generateWithConfig(
        text: "<$language>$text</$language>",
        config:
            const sherpa.OfflineTtsGenerationConfig(numSteps: 8, speed: 1.05));
    tts.free();
    return (samples: audio.samples, sampleRate: audio.sampleRate);
  });
  if (generation != _localTtsGeneration) return;
  final cache = await getTemporaryDirectory();
  final wav = File(p.join(cache.path,
      "assistant-supertonic-${DateTime.now().millisecondsSinceEpoch}.wav"));
  await wav.writeAsBytes(_waveBytes(result.samples, result.sampleRate));
  await ServerController.playAssistantAudio(wav.path);
  try {
    await wav.delete();
  } catch (_) {}
}

Float32List _pcm16ToFloat(Uint8List bytes) {
  final result = Float32List(bytes.length ~/ 2);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < result.length; i++) {
    result[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return result;
}

Uint8List _waveBytes(Float32List samples, int sampleRate) {
  final dataSize = samples.length * 2;
  final data = ByteData(44 + dataSize);
  void ascii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  ascii(0, "RIFF");
  data.setUint32(4, 36 + dataSize, Endian.little);
  ascii(8, "WAVEfmt ");
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, "data");
  data.setUint32(40, dataSize, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * 2, (samples[i].clamp(-1.0, 1.0) * 32767).round(),
        Endian.little);
  }
  return data.buffer.asUint8List();
}
