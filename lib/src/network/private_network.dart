import 'dart:io';
import 'dart:typed_data';

import 'package:dart_ipfs/src/core/config/ipfs_config.dart';
import 'package:dart_libp2p_pnet/dart_libp2p_pnet.dart';

/// Thrown when private network is required but no PSK is available.
class PnetNotConfiguredError implements Exception {
  PnetNotConfiguredError([String? detail])
      : message = detail == null
            ? 'Private network enforced but no PSK configured'
            : 'Private network enforced but no PSK configured ($detail)';

  final String message;

  @override
  String toString() => 'PnetNotConfiguredError: $message';
}

/// Result of resolving private-network settings for an IPFS node.
class ResolvedPrivateNetwork {
  const ResolvedPrivateNetwork({
    required this.psk,
    required this.forcePrivateNetwork,
    required this.swarmKeyPath,
    required this.fingerprint,
  });

  final Uint8List psk;
  final bool forcePrivateNetwork;
  final String swarmKeyPath;
  final String fingerprint;
}

/// Whether `LIBP2P_FORCE_PNET` is set in the environment.
bool forcePrivateNetworkFromEnv() {
  final value = Platform.environment['LIBP2P_FORCE_PNET'];
  if (value == null) return false;
  return value == '1' || value.toLowerCase() == 'true';
}

/// Default path for Kubo-style `swarm.key` under the repo directory.
String defaultSwarmKeyPath(String dataPath) {
  return '$dataPath/swarm.key';
}

/// Resolve PSK from inline config, `swarm.key` file, or env force flag.
Future<ResolvedPrivateNetwork?> resolvePrivateNetwork(
  IPFSConfig config,
) async {
  final network = config.network;
  final forced =
      network.forcePrivateNetwork || forcePrivateNetworkFromEnv();
  final swarmKeyPath =
      network.swarmKeyPath ?? defaultSwarmKeyPath(config.dataPath);

  if (network.privateNetworkPsk != null) {
    final psk = network.privateNetworkPsk!;
    if (psk.length != PrivateSharedKey.length) {
      throw InvalidPskLengthException(psk.length);
    }
    return ResolvedPrivateNetwork(
      psk: Uint8List.fromList(psk),
      forcePrivateNetwork: forced,
      swarmKeyPath: swarmKeyPath,
      fingerprint: pskFingerprint(
        PrivateSharedKey(psk, encoding: PrivateSharedKey.encodingBase16),
      ),
    );
  }

  final file = File(swarmKeyPath);
  if (!await file.exists()) {
    if (forced) {
      throw PnetNotConfiguredError('Missing swarm.key at $swarmKeyPath');
    }
    return null;
  }

  final key = await loadSwarmKeyFile(swarmKeyPath);
  return ResolvedPrivateNetwork(
    psk: key.bytes,
    forcePrivateNetwork: forced,
    swarmKeyPath: swarmKeyPath,
    fingerprint: pskFingerprint(key),
  );
}

/// Returns true if [multiaddr] looks like a public IPFS/libp2p bootstrap peer.
bool isPublicBootstrapMultiaddr(String multiaddr) {
  final lower = multiaddr.toLowerCase();
  return lower.contains('bootstrap.libp2p.io') ||
      lower.contains('/dnsaddr/bootstrap.libp2p.io');
}

/// Strip public bootstraps when a private network is active (unless opted out).
List<String> applyPrivateBootstrapPolicy({
  required List<String> bootstrapPeers,
  required bool privateNetworkEnabled,
  required bool allowPublicBootstrapWithPrivateNetwork,
  void Function(String message)? onWarning,
}) {
  if (!privateNetworkEnabled || allowPublicBootstrapWithPrivateNetwork) {
    return List<String>.from(bootstrapPeers);
  }

  final filtered = <String>[];
  for (final peer in bootstrapPeers) {
    if (isPublicBootstrapMultiaddr(peer)) {
      onWarning?.call(
        'Removing public bootstrap peer in private network mode: $peer',
      );
      continue;
    }
    filtered.add(peer);
  }
  return filtered;
}
