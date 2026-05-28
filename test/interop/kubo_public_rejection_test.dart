@Tags(['interop'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../network/pnet_test_fixture.dart';
import 'helpers/kubo_interop_env.dart';
import 'helpers/kubo_ipfs_connect.dart';
import 'helpers/kubo_process_manager.dart';

/// Scenario 6: dart_ipfs with PSK does not join public Kubo swarm.
void main() {
  final env = KuboInteropEnv.tryLoad();

  group('dart_ipfs public Kubo rejection', () {
    KuboProcessManager? kubo;
    Directory? dartRepo;

    tearDown(() async {
      await kubo?.stop();
      if (dartRepo != null && await dartRepo!.exists()) {
        await dartRepo!.delete(recursive: true);
      }
    });

    test(
      'private dart_ipfs does not appear in public Kubo swarm',
      () async {
        kubo = await KuboProcessManager.createPublic(ipfsBin: env!.ipfsBin);
        await kubo!.startDaemon();

        dartRepo = await Directory.systemTemp.createTemp('dart_ipfs_pnet_');
        await File('${dartRepo!.path}/swarm.key')
            .writeAsString(testSwarmKeyFileContents());

        final node = await startPrivateIpfsNode(
          dataPath: dartRepo!.path,
          kuboBootstrapMultiaddr: kubo!.dialMultiAddr.toString(),
        );

        try {
          // Attempt connection — should not establish a stable peer entry
          try {
            await connectKuboAndDart(kubo!, node, timeout: const Duration(seconds: 20));
          } catch (_) {
            // Expected
          }
          final peers = await kubo!.swarmPeers();
          expect(
            peers.any((p) => p.contains(node.peerID)),
            isFalse,
            reason: 'Public Kubo should not list private dart peer: $peers',
          );
        } finally {
          await node.stop();
        }
      },
      skip: env == null ? 'Kubo not found — set KUBO_BIN or install ipfs' : false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
