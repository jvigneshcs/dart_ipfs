@Tags(['interop'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../network/pnet_test_fixture.dart';
import 'helpers/kubo_interop_env.dart';
import 'helpers/kubo_ipfs_connect.dart';
import 'helpers/kubo_process_manager.dart';

String _wrongSwarmKeyFile() => '''
/key/swarm/psk/1.0.0/
/base16/
0000000000000000000000000000000000000000000000000000000000000001
''';

/// Scenario 5: mismatched swarm.key — peers do not connect.
void main() {
  final env = KuboInteropEnv.tryLoad();

  group('dart_ipfs Kubo PSK mismatch', () {
    KuboProcessManager? kubo;
    Directory? dartRepo;

    tearDown(() async {
      await kubo?.stop();
      if (dartRepo != null && await dartRepo!.exists()) {
        await dartRepo!.delete(recursive: true);
      }
    });

    test(
      'wrong dart swarm.key does not join Kubo private swarm',
      () async {
        kubo = await KuboProcessManager.createPrivate(
          ipfsBin: env!.ipfsBin,
          swarmKeyContents: testSwarmKeyFileContents(),
        );
        await kubo!.startDaemon();

        dartRepo = await Directory.systemTemp.createTemp('dart_ipfs_pnet_');
        await File('${dartRepo!.path}/swarm.key').writeAsString(_wrongSwarmKeyFile());

        final node = await startPrivateIpfsNode(
          dataPath: dartRepo!.path,
          kuboBootstrapMultiaddr: kubo!.dialMultiAddr.toString(),
        );

        try {
          try {
            await connectKuboAndDart(kubo!, node, timeout: const Duration(seconds: 20));
          } catch (_) {
            // Expected
          }
          final peers = await kubo!.swarmPeers();
          expect(peers.any((p) => p.contains(node.peerID)), isFalse);
        } finally {
          await node.stop();
        }
      },
      skip: env == null ? 'Kubo not found — set KUBO_BIN or install ipfs' : false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
