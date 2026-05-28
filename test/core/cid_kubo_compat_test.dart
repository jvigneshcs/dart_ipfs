import 'dart:typed_data';

import 'package:dart_ipfs/src/core/cid.dart';
import 'package:dart_ipfs/src/core/data_structures/block.dart';
import 'package:dart_ipfs/src/utils/ipfs_base32.dart';
import 'package:test/test.dart';

/// Vectors from Kubo `ipfs block put` (raw, sha2-256).
void main() {
  group('Kubo-compatible CIDv1 base32', () {
    test('hello raw block matches Kubo bafkre…', () async {
      const kuboCid =
          'bafkreibm6jg3ux5qumhcn2b3flc3tyu6dmlb4xa7u5bf44yegnrjhc4yeq';
      final data = Uint8List.fromList('hello'.codeUnits);

      final cid = await CID.fromContent(data);
      expect(cid.encode(), kuboCid);
      expect(CID.decode(kuboCid), equals(cid));

      final block = await Block.fromData(data);
      expect(block.cid.encode(), kuboCid);
    });

    test('bitswap interop payload', () async {
      const payload = 'pnet bitswap dart to kubo';
      final cid = await CID.fromContent(Uint8List.fromList(payload.codeUnits));
      final roundtrip = CID.decode(cid.encode());
      expect(roundtrip, equals(cid));
      expect(cid.encode(), startsWith('bafk'));
    });

    test('ipfsBase32 roundtrip arbitrary bytes', () {
      final bytes = Uint8List.fromList([1, 85, 18, 32, 1, 2, 3, 4]);
      final encoded = ipfsBase32Encode(bytes);
      expect(encoded.startsWith('b'), isTrue);
      expect(ipfsBase32Decode(encoded), bytes);
    });
  });
}
