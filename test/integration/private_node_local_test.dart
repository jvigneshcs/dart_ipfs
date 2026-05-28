import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ipfs/src/core/builders/ipfs_node_builder.dart';
import 'package:dart_ipfs/src/core/config/ipfs_config.dart';
import 'package:dart_ipfs/src/network/private_network.dart';
import 'package:dart_ipfs/src/transport/libp2p_router.dart';
import 'package:test/test.dart';

import '../network/pnet_test_fixture.dart';

void main() {
  group('private node local', () {
    late Directory repoDir;

    setUp(() async {
      repoDir = await Directory.systemTemp.createTemp('pnet_ipfs_repo_');
      await File('${repoDir.path}/swarm.key')
          .writeAsString(testSwarmKeyFileContents());
    });

    tearDown(() async {
      if (await repoDir.exists()) {
        await repoDir.delete(recursive: true);
      }
    });

    test('swarm.key resolves and Libp2pRouter starts', () async {
      final config = IPFSConfig(
        offline: false,
        dataPath: repoDir.path,
        network: NetworkConfig(
          bootstrapPeers: [],
          listenAddresses: ['/ip4/127.0.0.1/tcp/0'],
          enableWebTransport: false,
          enableWebRtc: false,
        ),
      );

      final resolved = await resolvePrivateNetwork(config);
      expect(resolved, isNotNull);

      final router = Libp2pRouter(config);
      await router.initialize();
      await router.start();
      expect(router.hasStarted, isTrue);
      await router.stop();
    });

    test('offline add/cat unchanged with swarm.key present', () async {
      final config = IPFSConfig(
        offline: true,
        dataPath: repoDir.path,
      );

      final node = await IPFSNodeBuilder(config).build();
      await node.start();

      final data = Uint8List.fromList([10, 20, 30, 40]);
      final cid = await node.addFile(data);
      final out = await node.cat(cid);
      expect(out, data);

      await node.stop();
    });
  });
}
