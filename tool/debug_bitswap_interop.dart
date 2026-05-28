// ignore_for_file: avoid_print
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ipfs/src/core/data_structures/block.dart';
import 'package:logging/logging.dart' as log;

import '../test/interop/helpers/kubo_interop_env.dart';
import '../test/interop/helpers/kubo_ipfs_connect.dart';
import '../test/interop/helpers/kubo_process_manager.dart';
import '../test/network/pnet_test_fixture.dart';

Future<void> main() async {
  log.Logger.root.level = log.Level.FINE;
  log.Logger.root.onRecord.listen((record) {
    print('${record.time.toIso8601String()} [${record.level.name}] [${record.loggerName}] ${record.message}');
    if (record.error != null) {
      print('  Error: ${record.error}');
    }
    if (record.stackTrace != null) {
      print('  StackTrace: ${record.stackTrace}');
    }
  });

  final env = KuboInteropEnv.tryLoad();
  if (env == null) {
    print('Set KUBO_BIN');
    exit(1);
  }

  final kubo = await KuboProcessManager.createPrivate(
    ipfsBin: env.ipfsBin,
    swarmKeyContents: testSwarmKeyFileContents(),
  );
  await kubo.startDaemon();

  final dartRepo = await Directory.systemTemp.createTemp('dart_ipfs_dbg_');
  await File('${dartRepo.path}/swarm.key')
      .writeAsString(testSwarmKeyFileContents());

  final node = await startPrivateIpfsNode(
    dataPath: dartRepo.path,
    kuboBootstrapMultiaddr: kubo.dialMultiAddr.toString(),
  );

  try {
    await connectKuboAndDart(kubo, node);

    final idResult = await Process.run(
      env.ipfsBin,
      ['id', node.peerID],
      environment: {'IPFS_PATH': kubo.repoDir.path},
    );
    print('--- Kubo id of Dart Node ---');
    print(idResult.stdout);
    print(idResult.stderr);

    const payload = 'pnet bitswap dart to kubo';
    final cid = await node.addFile(Uint8List.fromList(payload.codeUnits));
    final stored = await node.blockStore.getBlock(cid);
    final block = Block.fromProto(stored.block);

    print('offer block (10s timeout)...');
    await node.bitswap!
        .offerBlockToPeer(kubo.peerId, block)
        .timeout(const Duration(seconds: 10));
    print('offer done');

    final out = await kubo.blockGet(cid).timeout(const Duration(seconds: 15));
    print('block get ok: ${String.fromCharCodes(out)}');
  } catch (e, st) {
    print('ERROR: $e\n$st');
    final log = File('${kubo.repoDir.path}/daemon.log');
    if (await log.exists()) {
      final text = await log.readAsString();
      print('--- kubo daemon.log (last 400 lines) ---');
      final lines = text.split('\n');
      print(lines.skip(lines.length > 400 ? lines.length - 400 : 0).join('\n'));
    }
  } finally {
    await node.stop();
    await kubo.stop();
    await dartRepo.delete(recursive: true);
  }
}
