@Tags(['interop'])
library;

import 'dart:io';

import 'package:test/test.dart';

/// Scenario 2: dart_ipfs ↔ Kubo same PSK — peer visible in swarm.
void main() {
  test('dart_ipfs private node visible to Kubo', () {
    if (Platform.environment['KUBO_BIN'] == null) {
      markTestSkipped('Set KUBO_BIN');
    }
    markTestSkipped('Wire IPFSNode + Kubo swarm when CI Kubo is available');
  });
}
