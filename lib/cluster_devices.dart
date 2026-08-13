import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

const clusterEntityCompute = 'compute';
const clusterEntityCameraFront = 'cameraFront';
const clusterEntityCameraRear = 'cameraRear';
const clusterEntityMicrophone = 'microphone';
const clusterEntityScreen = 'screen';

const clusterModalityAudio = 'audio';
const clusterModalityVision = 'vision';

const _allClusterEntities = <String>{
  clusterEntityCompute,
  clusterEntityCameraFront,
  clusterEntityCameraRear,
  clusterEntityMicrophone,
  clusterEntityScreen,
};

class ClusterEndpoint {
  const ClusterEndpoint(this.host, this.port);

  final String host;
  final int port;

  String get canonical => '${host.contains(':') ? '[$host]' : host}:$port';

  Uri get metadataUri => Uri(
        scheme: 'http',
        host: host,
        port: port + 1,
        path: '/v1/device',
      );

  Uri mediaUri(String path) => Uri(
        scheme: 'http',
        host: host,
        port: port + 1,
        path: path,
      );

  static ClusterEndpoint? tryParse(String value) {
    final raw = value.trim();
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw.contains('://') ? raw : 'tcp://$raw');
    if (uri == null || uri.host.isEmpty || !uri.hasPort) return null;
    if (uri.port < 1 || uri.port > 65534) return null;
    return ClusterEndpoint(uri.host, uri.port);
  }
}

List<String> parseClusterRpcEndpoints(String value) {
  final result = <String>[];
  final seen = <String>{};
  for (final token in value.split(RegExp(r'[,;\s]+'))) {
    final endpoint = ClusterEndpoint.tryParse(token);
    if (endpoint != null && seen.add(endpoint.canonical)) {
      result.add(endpoint.canonical);
    }
  }
  return result;
}

class ClusterWorkerProfile {
  const ClusterWorkerProfile({
    required this.endpoint,
    required this.enabledEntities,
    this.name,
    this.kind = 'server',
    this.managedByOllama = false,
    this.rpcDeviceCount = 1,
    this.singleDeviceGuaranteed = false,
    this.advertisedEntities = const <String>{clusterEntityCompute},
    this.computeDevice,
    this.remoteMediaAvailable = false,
    this.mediaToken = '',
  });

  final String endpoint;
  final Set<String> enabledEntities;
  final String? name;
  final String kind;
  final bool managedByOllama;
  final int rpcDeviceCount;
  final bool singleDeviceGuaranteed;
  final Set<String> advertisedEntities;
  final String? computeDevice;
  final bool remoteMediaAvailable;
  final String mediaToken;

  bool entityEnabled(String entity) => enabledEntities.contains(entity);

  ClusterWorkerProfile copyWith({
    Set<String>? enabledEntities,
    String? name,
    String? kind,
    bool? managedByOllama,
    int? rpcDeviceCount,
    bool? singleDeviceGuaranteed,
    Set<String>? advertisedEntities,
    String? computeDevice,
    bool? remoteMediaAvailable,
    String? mediaToken,
  }) {
    return ClusterWorkerProfile(
      endpoint: endpoint,
      enabledEntities: enabledEntities ?? this.enabledEntities,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      managedByOllama: managedByOllama ?? this.managedByOllama,
      rpcDeviceCount: rpcDeviceCount ?? this.rpcDeviceCount,
      singleDeviceGuaranteed:
          singleDeviceGuaranteed ?? this.singleDeviceGuaranteed,
      advertisedEntities: advertisedEntities ?? this.advertisedEntities,
      computeDevice: computeDevice ?? this.computeDevice,
      remoteMediaAvailable: remoteMediaAvailable ?? this.remoteMediaAvailable,
      mediaToken: mediaToken ?? this.mediaToken,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'enabledEntities': enabledEntities.toList()..sort(),
        if (name?.isNotEmpty == true) 'name': name,
        'kind': kind,
        'managedByOllama': managedByOllama,
        'rpcDeviceCount': rpcDeviceCount,
        'singleDeviceGuaranteed': singleDeviceGuaranteed,
        'advertisedEntities': advertisedEntities.toList()..sort(),
        if (computeDevice?.isNotEmpty == true) 'computeDevice': computeDevice,
        'remoteMediaAvailable': remoteMediaAvailable,
        if (mediaToken.isNotEmpty) 'mediaToken': mediaToken,
      };

  factory ClusterWorkerProfile.fromJson(
      String endpoint, Map<String, dynamic> json) {
    Set<String> stringSet(dynamic value, Set<String> fallback) {
      if (value is! List) return fallback;
      return value
          .map((item) => item.toString())
          .where(_allClusterEntities.contains)
          .toSet();
    }

    return ClusterWorkerProfile(
      endpoint: endpoint,
      enabledEntities: stringSet(
          json['enabledEntities'], const <String>{clusterEntityCompute}),
      name: json['name']?.toString(),
      kind: json['kind']?.toString() ?? 'server',
      managedByOllama: json['managedByOllama'] == true,
      rpcDeviceCount:
          ((json['rpcDeviceCount'] as num?)?.toInt() ?? 1).clamp(1, 16),
      singleDeviceGuaranteed: json['singleDeviceGuaranteed'] == true,
      advertisedEntities: stringSet(
          json['advertisedEntities'], const <String>{clusterEntityCompute}),
      computeDevice: json['computeDevice']?.toString(),
      remoteMediaAvailable: json['remoteMediaAvailable'] == true,
      mediaToken: json['mediaToken']?.toString() ?? '',
    );
  }
}

Map<String, ClusterWorkerProfile> decodeClusterWorkerProfiles(String? value) {
  if (value == null || value.trim().isEmpty) {
    return <String, ClusterWorkerProfile>{};
  }
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return <String, ClusterWorkerProfile>{};
    return <String, ClusterWorkerProfile>{
      for (final entry in decoded.entries)
        if (entry.value is Map)
          entry.key.toString(): ClusterWorkerProfile.fromJson(
            entry.key.toString(),
            Map<String, dynamic>.from(entry.value as Map),
          ),
    };
  } catch (_) {
    return <String, ClusterWorkerProfile>{};
  }
}

String encodeClusterWorkerProfiles(
        Map<String, ClusterWorkerProfile> profiles) =>
    jsonEncode(<String, dynamic>{
      for (final entry in profiles.entries) entry.key: entry.value.toJson(),
    });

ClusterWorkerProfile clusterProfileFor(
    String endpoint, Map<String, ClusterWorkerProfile> profiles) {
  return profiles[endpoint] ??
      ClusterWorkerProfile(
        endpoint: endpoint,
        enabledEntities: const <String>{clusterEntityCompute},
      );
}

String configuredClusterRpcServers(
    String rawEndpoints, String? encodedProfiles) {
  final profiles = decodeClusterWorkerProfiles(encodedProfiles);
  return parseClusterRpcEndpoints(rawEndpoints)
      .where((endpoint) => clusterProfileFor(endpoint, profiles)
          .entityEnabled(clusterEntityCompute))
      .join(',');
}

/// Returns the llama.cpp device name for the selected remote projector.
///
/// RPC devices are registered in endpoint order. Exact targeting is only used
/// for Ollama Android workers which advertise that they expose one device.
String? configuredRemoteMultimodalBackend({
  required String enabledEndpoints,
  required String? encodedProfiles,
  required String target,
}) {
  if (target.isEmpty || target == 'host') return null;
  final profiles = decodeClusterWorkerProfiles(encodedProfiles);
  var rpcIndex = 0;
  var rpcIndexIsKnown = true;
  for (final endpoint in parseClusterRpcEndpoints(enabledEndpoints)) {
    final profile = clusterProfileFor(endpoint, profiles);
    if (endpoint == target) {
      if (!rpcIndexIsKnown ||
          !profile.managedByOllama ||
          !profile.singleDeviceGuaranteed) {
        return null;
      }
      return 'RPC$rpcIndex';
    }
    if (profile.singleDeviceGuaranteed) {
      rpcIndex += profile.rpcDeviceCount;
    } else {
      // A stock or automatic worker may expose more than one backend. That
      // makes every following RPC index ambiguous, so fail closed instead of
      // sending the multimodal projector to the wrong processor.
      rpcIndexIsKnown = false;
    }
  }
  return null;
}

class ClusterWorkerDevice {
  const ClusterWorkerDevice({
    required this.profile,
    required this.online,
    this.controlPlaneAvailable = false,
    this.error,
  });

  final ClusterWorkerProfile profile;
  final bool online;
  final bool controlPlaneAvailable;
  final String? error;
}

class ClusterWorkerDiscovery {
  const ClusterWorkerDiscovery({
    this.metadataTimeout = const Duration(milliseconds: 1400),
    this.rpcTimeout = const Duration(milliseconds: 900),
  });

  final Duration metadataTimeout;
  final Duration rpcTimeout;

  Future<ClusterWorkerDevice> probe(ClusterWorkerProfile stored) async {
    final endpoint = ClusterEndpoint.tryParse(stored.endpoint);
    if (endpoint == null) {
      return ClusterWorkerDevice(
        profile: stored,
        online: false,
        error: 'Dirección RPC no válida',
      );
    }

    try {
      final response =
          await http.get(endpoint.metadataUri).timeout(metadataTimeout);
      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body is Map) {
          final metadata = Map<String, dynamic>.from(body);
          final advertised = <String>{clusterEntityCompute};
          final entities = metadata['entities'];
          if (entities is Map) {
            final values = Map<String, dynamic>.from(entities);
            for (final entity in _allClusterEntities) {
              if (values[entity] == true) advertised.add(entity);
            }
          }
          final enabled = stored.enabledEntities
              .where((entity) =>
                  entity == clusterEntityCompute || advertised.contains(entity))
              .toSet();
          final selectedDevice = metadata['selectedComputeDevice']?.toString();
          return ClusterWorkerDevice(
            profile: stored.copyWith(
              enabledEntities: enabled,
              name: metadata['name']?.toString(),
              kind: metadata['type']?.toString() ?? 'server',
              managedByOllama: metadata['app'] == 'ollama-android',
              rpcDeviceCount:
                  ((metadata['rpcDeviceCount'] as num?)?.toInt() ?? 1)
                      .clamp(1, 16),
              singleDeviceGuaranteed:
                  metadata['singleDeviceGuaranteed'] == true,
              advertisedEntities: advertised,
              computeDevice: selectedDevice,
              remoteMediaAvailable: metadata['mediaCapture'] == true,
            ),
            online: metadata['rpcRunning'] != false,
            controlPlaneAvailable: true,
          );
        }
      }
    } catch (_) {
      // A stock llama.cpp worker has no HTTP control plane; probe TCP below.
    }

    Socket? socket;
    try {
      socket = await Socket.connect(endpoint.host, endpoint.port,
          timeout: rpcTimeout);
      return ClusterWorkerDevice(
        profile: stored,
        online: true,
        error: 'Worker llama.cpp sin metadatos de dispositivo',
      );
    } catch (_) {
      return ClusterWorkerDevice(
        profile: stored,
        online: false,
        error: 'No responde en ${stored.endpoint}',
      );
    } finally {
      socket?.destroy();
    }
  }
}

class ClusterRemoteMediaClient {
  const ClusterRemoteMediaClient({
    this.cameraTimeout = const Duration(seconds: 20),
    this.audioTimeout = const Duration(seconds: 80),
  });

  final Duration cameraTimeout;
  final Duration audioTimeout;

  Future<Uint8List> captureCamera(
    ClusterWorkerProfile worker, {
    required bool front,
  }) async {
    final endpoint = _validated(worker);
    final response = await http
        .post(
          endpoint.mediaUri(front ? '/v1/camera/front' : '/v1/camera/rear'),
          headers: _headers(worker),
        )
        .timeout(cameraTimeout);
    _checkResponse(response, worker);
    if (response.bodyBytes.isEmpty) {
      throw StateError('La cámara remota no devolvió ninguna imagen.');
    }
    return response.bodyBytes;
  }

  Future<({Float32List samples, int sampleRate})?> captureSpeech(
      ClusterWorkerProfile worker) async {
    final endpoint = _validated(worker);
    final response = await http
        .post(
          endpoint.mediaUri('/v1/audio'),
          headers: _headers(worker),
        )
        .timeout(audioTimeout);
    if (response.statusCode == 204) return null;
    _checkResponse(response, worker);
    final bytes = response.bodyBytes;
    if (bytes.isEmpty) return null;
    final sampleRate =
        int.tryParse(response.headers['x-sample-rate'] ?? '') ?? 16000;
    final data = ByteData.sublistView(bytes);
    final samples = Float32List(bytes.length ~/ 2);
    for (var index = 0; index < samples.length; index++) {
      samples[index] = data.getInt16(index * 2, Endian.little) / 32768.0;
    }
    return (samples: samples, sampleRate: sampleRate);
  }

  ClusterEndpoint _validated(ClusterWorkerProfile worker) {
    final endpoint = ClusterEndpoint.tryParse(worker.endpoint);
    if (endpoint == null) {
      throw StateError('La dirección del worker multimedia no es válida.');
    }
    if (!worker.remoteMediaAvailable) {
      throw StateError(
          'Activa Compartir cámara y micrófono en el worker ${worker.name ?? worker.endpoint}.');
    }
    if (worker.mediaToken.length < 8) {
      throw StateError(
          'Introduce la clave multimedia del worker ${worker.name ?? worker.endpoint}.');
    }
    return endpoint;
  }

  Map<String, String> _headers(ClusterWorkerProfile worker) => <String, String>{
        'X-Ollama-Cluster-Token': worker.mediaToken,
        'Content-Length': '0',
      };

  void _checkResponse(http.Response response, ClusterWorkerProfile worker) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    var detail = response.body.trim();
    try {
      final decoded = jsonDecode(detail);
      if (decoded is Map && decoded['error'] != null) {
        detail = decoded['error'].toString();
      }
    } catch (_) {}
    throw HttpException(
      'Worker ${worker.name ?? worker.endpoint}: HTTP ${response.statusCode}'
      '${detail.isEmpty ? '' : ' · $detail'}',
    );
  }
}
