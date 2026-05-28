import 'dart:io';

import 'package:dart_ipfs/src/core/config/ipfs_config.dart';
import 'package:dart_ipfs/src/network/private_network.dart';
import 'package:dart_libp2p_pnet/dart_libp2p_pnet.dart';
import 'package:test/test.dart';

import 'pnet_test_fixture.dart';

void main() {
  group('swarm.key loader', () {
    test('defaultSwarmKeyPath uses dataPath', () {
      expect(defaultSwarmKeyPath('/tmp/ipfs'), '/tmp/ipfs/swarm.key');
    });

    test('invalid swarm.key throws decode error', () async {
      final dir = await Directory.systemTemp.createTemp('pnet_bad_key_');
      await File('${dir.path}/swarm.key').writeAsString('not a valid key\n');
      final config = IPFSConfig(dataPath: dir.path);

      await expectLater(
        resolvePrivateNetwork(config),
        throwsA(isA<PnetException>()),
      );
      await dir.delete(recursive: true);
    });
  });
}
