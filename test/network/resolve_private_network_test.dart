import 'dart:io';

import 'package:dart_ipfs/src/core/config/ipfs_config.dart';
import 'package:dart_ipfs/src/network/private_network.dart';
import 'package:test/test.dart';

import 'pnet_test_fixture.dart';

void main() {
  group('resolvePrivateNetwork', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('pnet_resolve_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('inline PSK returns resolved config with fingerprint', () async {
      final psk = testSwarmPskBytes();
      final config = IPFSConfig(
        network: NetworkConfig(privateNetworkPsk: psk),
        dataPath: tempDir.path,
      );

      final resolved = await resolvePrivateNetwork(config);
      expect(resolved, isNotNull);
      expect(resolved!.psk, psk);
      expect(resolved.fingerprint, isNotEmpty);
    });

    test('loads swarm.key from dataPath when present', () async {
      await File('${tempDir.path}/swarm.key')
          .writeAsString(testSwarmKeyFileContents());
      final config = IPFSConfig(dataPath: tempDir.path);

      final resolved = await resolvePrivateNetwork(config);
      expect(resolved, isNotNull);
      expect(resolved!.psk, testSwarmPskBytes());
      expect(resolved.swarmKeyPath, '${tempDir.path}/swarm.key');
    });

    test('custom swarmKeyPath overrides default', () async {
      final custom = '${tempDir.path}/custom.key';
      await File(custom).writeAsString(testSwarmKeyFileContents());
      final config = IPFSConfig(
        dataPath: tempDir.path,
        network: NetworkConfig(swarmKeyPath: custom),
      );

      final resolved = await resolvePrivateNetwork(config);
      expect(resolved?.swarmKeyPath, custom);
    });

    test('missing swarm.key without force returns null', () async {
      final config = IPFSConfig(dataPath: tempDir.path);
      expect(await resolvePrivateNetwork(config), isNull);
    });

    test('forcePrivateNetwork without key throws', () async {
      final config = IPFSConfig(
        dataPath: tempDir.path,
        network: NetworkConfig(forcePrivateNetwork: true),
      );

      await expectLater(
        resolvePrivateNetwork(config),
        throwsA(isA<PnetNotConfiguredError>()),
      );
    });
  });
}
