import 'dart:io';

/// Environment for gated Kubo (`ipfs`) interop tests.
class KuboInteropEnv {
  KuboInteropEnv._(this.ipfsBin);

  final String ipfsBin;

  static KuboInteropEnv? tryLoad() {
    final fromEnv = Platform.environment['KUBO_BIN'];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      final file = File(fromEnv);
      if (file.existsSync()) return KuboInteropEnv._(fromEnv);
    }
    final common = [
      '/opt/homebrew/bin/ipfs',
      '/usr/local/bin/ipfs',
      'ipfs',
    ];
    for (final path in common) {
      try {
        final result = Process.runSync('which', [path.split('/').last]);
        if (result.exitCode == 0) {
          final resolved = (result.stdout as String).trim().split('\n').first;
          if (resolved.isNotEmpty && File(resolved).existsSync()) {
            return KuboInteropEnv._(resolved);
          }
        }
      } catch (_) {
        // ignore
      }
    }
    return null;
  }

  static void skipIfUnavailable(String reason) {
    if (tryLoad() == null) {
      // ignore: only_throw_errors
      throw _SkipTest(reason);
    }
  }
}

/// Thrown internally; tests should use [skip] parameter or markTestSkipped.
class _SkipTest implements Exception {
  _SkipTest(this.message);
  final String message;
  @override
  String toString() => message;
}
