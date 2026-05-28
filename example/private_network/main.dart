import 'dart:io';

import 'package:dart_ipfs/dart_ipfs.dart';
import 'package:dart_ipfs/src/core/builders/ipfs_node_builder.dart';

/// Example: start an IPFS node with Kubo-style `swarm.key` in the repo directory.
///
/// Usage:
/// ```bash
/// mkdir -p ./ipfs_private
/// # place swarm.key at ./ipfs_private/swarm.key (from ipfs-swarm-key-gen)
/// dart run example/private_network/main.dart ./ipfs_private
/// ```
Future<void> main(List<String> args) async {
  final dataPath = args.isNotEmpty ? args.first : './ipfs_private';
  final swarmKey = File('$dataPath/swarm.key');
  if (!await swarmKey.exists()) {
    stderr.writeln('Missing swarm.key at ${swarmKey.path}');
    stderr.writeln('Generate one with ipfs-swarm-key-gen (Kubo tooling).');
    exitCode = 1;
    return;
  }

  final config = IPFSConfig(
    offline: false,
    dataPath: dataPath,
    network: NetworkConfig(
      bootstrapPeers: [],
      listenAddresses: ['/ip4/127.0.0.1/tcp/4001'],
      forcePrivateNetwork: true,
      enableWebTransport: false,
      enableWebRtc: false,
    ),
  );

  final resolved = await resolvePrivateNetwork(config);
  stdout.writeln(
    'Private network enabled. Fingerprint: ${resolved?.fingerprint}',
  );

  final node = await IPFSNodeBuilder(config).build();
  await node.start();
  stdout.writeln('Node started. Peer ID: ${node.peerId}');
  stdout.writeln('Press Ctrl+C to stop.');

  // Keep process alive for manual inspection.
  await Future<void>.delayed(const Duration(days: 1));
}
