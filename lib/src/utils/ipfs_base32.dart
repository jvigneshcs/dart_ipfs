import 'dart:typed_data';

/// RFC4648 base32 (lowercase, no padding) used by IPFS/Kubo for CIDv1 strings.
///
/// The `multibase` package's [Multibase.base32] uses BaseX encoding, which does
/// not match Kubo/`ipfs block put` (`bafkre…` vs `bbku…` for the same bytes).
const String ipfsBase32Alphabet = 'abcdefghijklmnopqrstuvwxyz234567';

/// Multibase code for IPFS CIDv1 base32.
const String ipfsBase32MultibaseCode = 'b';

/// Decodes a multibase base32 string (with or without leading `b`).
Uint8List ipfsBase32Decode(String input) {
  var data = input;
  if (data.isEmpty) {
    throw const FormatException('empty base32 input');
  }
  if (data.startsWith(ipfsBase32MultibaseCode)) {
    data = data.substring(1);
  }
  data = data.toLowerCase();

  var bits = 0;
  var value = 0;
  final out = BytesBuilder(copy: false);

  for (final codeUnit in data.codeUnits) {
    final char = String.fromCharCode(codeUnit);
    final idx = ipfsBase32Alphabet.indexOf(char);
    if (idx < 0) {
      throw FormatException('invalid base32 character: $char');
    }
    value = (value << 5) | idx;
    bits += 5;
    while (bits >= 8) {
      bits -= 8;
      out.addByte((value >> bits) & 0xff);
    }
  }

  return out.toBytes();
}

/// Encodes [data] as multibase base32 (`b` + payload).
String ipfsBase32Encode(Uint8List data) {
  final out = StringBuffer(ipfsBase32MultibaseCode);
  var bits = 0;
  var value = 0;

  for (final byte in data) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(ipfsBase32Alphabet[(value >> bits) & 31]);
    }
  }
  if (bits > 0) {
    out.write(ipfsBase32Alphabet[(value << (5 - bits)) & 31]);
  }

  return out.toString();
}
