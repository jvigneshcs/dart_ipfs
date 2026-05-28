import 'dart:async';

import 'package:dart_ipfs/src/core/builders/ipfs_node_builder.dart';
import 'package:dart_ipfs/src/core/config/ipfs_config.dart';
import 'package:dart_ipfs/src/core/ipfs_node/ipfs_node.dart';

import '../../network/pnet_test_fixture.dart';
import 'kubo_process_manager.dart';

/// Starts an online private [IPFSNode] with the test swarm key.
Future<IPFSNode> startPrivateIpfsNode({
  required String dataPath,
  required String kuboBootstrapMultiaddr,
}) async {
  final config = IPFSConfig(
    offline: false,
    dataPath: dataPath,
    datastorePath: dataPath,
    keystorePath: '$dataPath/keystore',
    enableDHT: false,
    network: NetworkConfig(
      bootstrapPeers: [kuboBootstrapMultiaddr],
      listenAddresses: ['/ip4/127.0.0.1/tcp/0'],
      enableWebTransport: false,
      enableWebRtc: false,
    ),
  );

  final node = await IPFSNodeBuilder(config).build();
  await node.start();

  // BitswapHandler.start() also brings up Libp2pRouter (not yet on LifecycleManager).
  final bitswap = node.bitswap;
  if (bitswap != null) {
    await bitswap.start();
  } else {
    final router = node.router;
    if (router != null && !router.hasStarted) {
      await router.start();
    }
  }

  return node;
}

/// Builds `/ip4/.../tcp/PORT/p2p/PEER` from node listen addresses.
String? dartDialMultiaddr(IPFSNode node) {
  final peerId = node.peerID;
  if (peerId.isEmpty) return null;
  for (final raw in node.addresses) {
    if (!raw.contains('/ip4/') ||
        !raw.contains('/tcp/') ||
        raw.contains('/p2p/')) {
      continue;
    }
    var addr = raw;
    if (addr.contains('/ip4/0.0.0.0/')) {
      addr = addr.replaceAll('/ip4/0.0.0.0/', '/ip4/127.0.0.1/');
    }
    return '$addr/p2p/$peerId';
  }
  return null;
}

Future<void> connectKuboAndDart(
  KuboProcessManager kubo,
  IPFSNode dart, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final router = dart.router;
  if (router == null) {
    throw StateError('dart_ipfs router not available (offline node?)');
  }

  // Outbound dial to Kubo (same pattern as dart_libp2p scenario 1).
  await router.connect(kubo.dialMultiAddr.toString());

  final dartMa = dartDialMultiaddr(dart);
  if (dartMa != null) {
    try {
      await kubo.swarmConnect(dartMa);
    } catch (_) {
      // Optional reverse dial; outbound Dart→Kubo is enough for bitswap.
    }
  }

  await waitForKuboPeer(kubo, dart.peerID, timeout: timeout);

  await dart.bitswap?.syncSessionsToConnectedPeers();
}

/// After [addFile], re-announce HAVE to Kubo (e.g. if Kubo connected after add).
Future<void> announceDartBlockToKubo(
  IPFSNode dart,
  KuboProcessManager kubo,
  String cid,
) async {
  await dart.bitswap?.announceHave(cid);
}
