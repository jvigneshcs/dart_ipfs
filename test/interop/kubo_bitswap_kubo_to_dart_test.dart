@Tags(['interop'])
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../network/pnet_test_fixture.dart';
import 'helpers/kubo_interop_env.dart';
import 'helpers/kubo_ipfs_connect.dart';
import 'helpers/kubo_process_manager.dart';

/// Scenario 4: Kubo adds file, Dart fetches CID via bitswap.
void main() {
  final env = KuboInteropEnv.tryLoad();

  group('bitswap kubo to dart', () {
    KuboProcessManager? kubo;
    Directory? dartRepo;

    tearDown(() async {
      await kubo?.stop();
      if (dartRepo != null && await dartRepo!.exists()) {
        await dartRepo!.delete(recursive: true);
      }
    });

    test(
      'dart_ipfs cat retrieves block added on Kubo',
      () async {
        kubo = await KuboProcessManager.createPrivate(
          ipfsBin: env!.ipfsBin,
          swarmKeyContents: testSwarmKeyFileContents(),
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
          await connectKuboAndDart(kubo!, node);

          const payload = 'pnet bitswap kubo to dart';
          final cid = await kubo!.blockPut(payload.codeUnits);

          final out = await node.cat(cid).timeout(const Duration(seconds: 60));
          expect(out, isNotNull);
          expect(String.fromCharCodes(out!), payload);
        } finally {
          await node.stop();
        }
      },
      skip: env == null ? 'Kubo not found — set KUBO_BIN or install ipfs' : false,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  });
}
