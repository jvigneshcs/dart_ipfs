import 'package:dart_ipfs/src/core/config/network_config.dart';
import 'package:dart_ipfs/src/network/private_network.dart';
import 'package:test/test.dart';

void main() {
  group('private node bootstrap policy', () {
    test('only private bootstrap peers remain after policy', () {
      const privateBootstrap =
          '/ip4/192.168.1.10/tcp/4001/p2p/QmPrivateBootstrapPeer';
      final peers = [
        ...NetworkConfig.defaultBootstrapPeers,
        privateBootstrap,
      ];

      final filtered = applyPrivateBootstrapPolicy(
        bootstrapPeers: peers,
        privateNetworkEnabled: true,
        allowPublicBootstrapWithPrivateNetwork: false,
      );

      expect(filtered, [privateBootstrap]);
    });
  });
}
