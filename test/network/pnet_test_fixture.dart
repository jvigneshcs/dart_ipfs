import 'dart:typed_data';

import 'package:dart_libp2p_pnet/dart_libp2p_pnet.dart';

/// Public spec example PSK (do not use in production).
Uint8List testSwarmPskBytes() {
  return decodeV1PskFromString('''
/key/swarm/psk/1.0.0/
/base16/
b21de7dd7e0c5aaa394bd4fd8ead40cf6a0e906e660348ad8c0a06041e78e1b0
''').bytes;
}

String testSwarmKeyFileContents() => '''
/key/swarm/psk/1.0.0/
/base16/
b21de7dd7e0c5aaa394bd4fd8ead40cf6a0e906e660348ad8c0a06041e78e1b0
''';
