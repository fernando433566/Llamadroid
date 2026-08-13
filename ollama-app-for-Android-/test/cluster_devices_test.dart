import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ollama_app/cluster_devices.dart';

void main() {
  test('normalizes and deduplicates RPC endpoints', () {
    expect(
      parseClusterRpcEndpoints(
          '192.168.1.133:50052, 192.168.1.186:50052\n192.168.1.133:50052'),
      <String>['192.168.1.133:50052', '192.168.1.186:50052'],
    );
    expect(parseClusterRpcEndpoints('missing-port'), isEmpty);
    expect(parseClusterRpcEndpoints('[fd00::1]:50052'),
        <String>['[fd00::1]:50052']);
  });

  test('disabled compute workers are omitted from the server configuration',
      () {
    final profiles = <String, ClusterWorkerProfile>{
      '192.168.1.133:50052': const ClusterWorkerProfile(
        endpoint: '192.168.1.133:50052',
        enabledEntities: <String>{clusterEntityCompute},
      ),
      '192.168.1.186:50052': const ClusterWorkerProfile(
        endpoint: '192.168.1.186:50052',
        enabledEntities: <String>{clusterEntityMicrophone},
      ),
    };

    expect(
      configuredClusterRpcServers(
        '192.168.1.133:50052,192.168.1.186:50052',
        encodeClusterWorkerProfiles(profiles),
      ),
      '192.168.1.133:50052',
    );
  });

  test('maps an exact managed worker to its RPC device index', () {
    final profiles = <String, ClusterWorkerProfile>{
      '192.168.1.133:50052': const ClusterWorkerProfile(
        endpoint: '192.168.1.133:50052',
        enabledEntities: <String>{clusterEntityCompute},
        managedByOllama: true,
        singleDeviceGuaranteed: true,
      ),
      '192.168.1.186:50052': const ClusterWorkerProfile(
        endpoint: '192.168.1.186:50052',
        enabledEntities: <String>{clusterEntityCompute},
        managedByOllama: true,
        singleDeviceGuaranteed: true,
      ),
    };
    final encoded = encodeClusterWorkerProfiles(profiles);

    expect(
      configuredRemoteMultimodalBackend(
        enabledEndpoints: '192.168.1.133:50052,192.168.1.186:50052',
        encodedProfiles: encoded,
        target: '192.168.1.186:50052',
      ),
      'RPC1',
    );
  });

  test('refuses exact routing to unidentifiable stock workers', () {
    final profiles = <String, ClusterWorkerProfile>{
      '192.168.1.133:50052': const ClusterWorkerProfile(
        endpoint: '192.168.1.133:50052',
        enabledEntities: <String>{clusterEntityCompute},
      ),
    };

    expect(
      configuredRemoteMultimodalBackend(
        enabledEndpoints: '192.168.1.133:50052',
        encodedProfiles: encodeClusterWorkerProfiles(profiles),
        target: '192.168.1.133:50052',
      ),
      isNull,
    );
  });

  test('refuses routing after a worker with an ambiguous RPC device count', () {
    final profiles = <String, ClusterWorkerProfile>{
      '192.168.1.133:50052': const ClusterWorkerProfile(
        endpoint: '192.168.1.133:50052',
        enabledEntities: <String>{clusterEntityCompute},
      ),
      '192.168.1.186:50052': const ClusterWorkerProfile(
        endpoint: '192.168.1.186:50052',
        enabledEntities: <String>{clusterEntityCompute},
        managedByOllama: true,
        singleDeviceGuaranteed: true,
      ),
    };

    expect(
      configuredRemoteMultimodalBackend(
        enabledEndpoints: '192.168.1.133:50052,192.168.1.186:50052',
        encodedProfiles: encodeClusterWorkerProfiles(profiles),
        target: '192.168.1.186:50052',
      ),
      isNull,
    );
  });

  test('persists the paired multimedia key without advertising it as metadata',
      () {
    const profile = ClusterWorkerProfile(
      endpoint: '192.168.1.133:50052',
      enabledEntities: <String>{clusterEntityCompute, clusterEntityCameraRear},
      remoteMediaAvailable: true,
      mediaToken: 'paired-secret-42',
    );
    final decoded = decodeClusterWorkerProfiles(
        encodeClusterWorkerProfiles(<String, ClusterWorkerProfile>{
      profile.endpoint: profile,
    }));

    expect(decoded[profile.endpoint]?.remoteMediaAvailable, isTrue);
    expect(decoded[profile.endpoint]?.mediaToken, 'paired-secret-42');
  });

  test('remote camera capture authenticates and returns the worker JPEG',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handled = () async {
      final request = await server.first;
      expect(request.method, 'POST');
      expect(request.uri.path, '/v1/camera/rear');
      expect(request.headers.value('x-ollama-cluster-token'), 'camera-key');
      request.response.headers.contentType = ContentType('image', 'jpeg');
      request.response.add(<int>[0xff, 0xd8, 0xff, 0xd9]);
      await request.response.close();
    }();
    final profile = ClusterWorkerProfile(
      endpoint: '127.0.0.1:${server.port - 1}',
      enabledEntities: const <String>{
        clusterEntityCompute,
        clusterEntityCameraRear
      },
      advertisedEntities: const <String>{
        clusterEntityCompute,
        clusterEntityCameraRear
      },
      remoteMediaAvailable: true,
      mediaToken: 'camera-key',
    );

    final bytes = await const ClusterRemoteMediaClient()
        .captureCamera(profile, front: false);
    await handled;
    await server.close(force: true);
    expect(bytes, <int>[0xff, 0xd8, 0xff, 0xd9]);
  });

  test('remote microphone converts little-endian PCM16 to model samples',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final handled = () async {
      final request = await server.first;
      expect(request.uri.path, '/v1/audio');
      expect(request.headers.value('x-ollama-cluster-token'), 'audio-key');
      request.response.headers.set('X-Sample-Rate', '16000');
      request.response.add(<int>[0x00, 0x00, 0xff, 0x7f, 0x00, 0x80]);
      await request.response.close();
    }();
    final profile = ClusterWorkerProfile(
      endpoint: '127.0.0.1:${server.port - 1}',
      enabledEntities: const <String>{
        clusterEntityCompute,
        clusterEntityMicrophone
      },
      advertisedEntities: const <String>{
        clusterEntityCompute,
        clusterEntityMicrophone
      },
      remoteMediaAvailable: true,
      mediaToken: 'audio-key',
    );

    final captured =
        await const ClusterRemoteMediaClient().captureSpeech(profile);
    await handled;
    await server.close(force: true);
    expect(captured?.sampleRate, 16000);
    expect(captured?.samples[0], 0);
    expect(captured?.samples[1], closeTo(0.99997, 0.0001));
    expect(captured?.samples[2], -1);
  });
}
