@Tags(['interop'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ipfs/src/core/cid.dart';
import 'package:dart_ipfs/src/core/data_structures/block.dart';
import 'package:test/test.dart';

import '../network/pnet_test_fixture.dart';
import 'helpers/kubo_interop_env.dart';
import 'helpers/kubo_ipfs_connect.dart';
import 'helpers/kubo_process_manager.dart';

/// Scenario 3: Dart adds file, Kubo fetches CID via bitswap.
void main() {
  final env = KuboInteropEnv.tryLoad();

  group('bitswap dart to kubo', () {
    KuboProcessManager? kubo;
    Directory? dartRepo;

    tearDown(() async {
      await kubo?.stop();
      if (dartRepo != null && await dartRepo!.exists()) {
        await dartRepo!.delete(recursive: true);
      }
    });

    test(
      'Kubo cat retrieves block added on dart_ipfs',
      () async {
        kubo = await KuboProcessManager.createPrivate(
          ipfsBin: env!.ipfsBin,
          swarmKeyContents: testSwarmKeyFileContents(),
          enableDhtRouting: true,
        );
        await kubo!.startDaemon();

        dartRepo = await Directory.systemTemp.createTemp('dart_ipfs_pnet_');
        await File('${dartRepo!.path}/swarm.key')
            .writeAsString(testSwarmKeyFileContents());

        final node = await startPrivateIpfsNode(
          dataPath: dartRepo!.path,
          kuboBootstrapMultiaddr: kubo!.dialMultiAddr.toString(),
        );

        try {
          final dht = node.dhtHandler;
          if (dht != null) {
            await dht.start();
          }

          await connectKuboAndDart(kubo!, node);

          const payload = 'pnet bitswap dart to kubo';
          final cid = await node.addFile(Uint8List.fromList(payload.codeUnits));

          if (dht != null) {
            await dht.provide(CID.decode(cid));
            await Future<void>.delayed(const Duration(seconds: 8));
          }

          final stored = await node.blockStore.getBlock(cid);
          if (stored.found) {
            await node.bitswap?.offerBlockToPeer(
              kubo!.peerId,
              Block.fromProto(stored.block),
            );
          }

          final out = await kubo!.blockGet(cid).timeout(const Duration(seconds: 90));
          expect(String.fromCharCodes(out), payload);
        } finally {
          await node.stop();
        }
      },
      skip: env == null ? 'Kubo not found — set KUBO_BIN or install ipfs' : false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
