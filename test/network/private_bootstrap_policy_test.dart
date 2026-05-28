import 'package:dart_ipfs/src/core/config/network_config.dart';
import 'package:dart_ipfs/src/network/private_network.dart';
import 'package:test/test.dart';

void main() {
  group('applyPrivateBootstrapPolicy', () {
    test('removes public bootstraps when PSK active', () {
      final warnings = <String>[];
      final filtered = applyPrivateBootstrapPolicy(
        bootstrapPeers: NetworkConfig.defaultBootstrapPeers,
        privateNetworkEnabled: true,
        allowPublicBootstrapWithPrivateNetwork: false,
        onWarning: warnings.add,
      );

      expect(filtered, isEmpty);
      expect(warnings.length, NetworkConfig.defaultBootstrapPeers.length);
      for (final w in warnings) {
        expect(w, contains('Removing public bootstrap'));
      }
    });

    test('keeps public bootstraps when explicitly allowed', () {
      final filtered = applyPrivateBootstrapPolicy(
        bootstrapPeers: NetworkConfig.defaultBootstrapPeers,
        privateNetworkEnabled: true,
        allowPublicBootstrapWithPrivateNetwork: true,
      );

      expect(filtered, NetworkConfig.defaultBootstrapPeers);
    });

    test('no change without private network', () {
      final custom = ['/ip4/127.0.0.1/tcp/4001/p2p/QmTest'];
      final filtered = applyPrivateBootstrapPolicy(
        bootstrapPeers: custom,
        privateNetworkEnabled: false,
        allowPublicBootstrapWithPrivateNetwork: false,
      );
      expect(filtered, custom);
    });

    test('isPublicBootstrapMultiaddr detects libp2p.io bootstraps', () {
      expect(
        isPublicBootstrapMultiaddr(NetworkConfig.defaultBootstrapPeers.first),
        isTrue,
      );
      expect(
        isPublicBootstrapMultiaddr('/ip4/127.0.0.1/tcp/4001/p2p/QmLocal'),
        isFalse,
      );
    });
  });
}
