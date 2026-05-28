import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_libp2p/core/multiaddr.dart';

/// Manages a Kubo (`ipfs`) repo and daemon for PNET interop tests.
class KuboProcessManager {
  KuboProcessManager({
    required this.ipfsBin,
    required this.repoDir,
    this.swarmKeyPath,
    required this.tcpPort,
    this.enableDhtRouting = false,
  });

  final String ipfsBin;
  final Directory repoDir;
  final String? swarmKeyPath;
  final int tcpPort;

  /// When true, Kubo uses DHT routing (needed for bitswap scenario 3 provider discovery).
  final bool enableDhtRouting;

  Process? _daemon;
  Map<String, dynamic>? _idJson;
  String? _listenHost;
  int? _listenPort;
  final Completer<void> _listenReady = Completer<void>();

  Map<String, String> get _env => {
        'IPFS_PATH': repoDir.path,
        if (swarmKeyPath != null) 'LIBP2P_TCP_MUX': 'false',
        'GOLOG_LOG_LEVEL': 'debug',
      };

  static final _listenLine = RegExp(
    r'Swarm listening on ([^:\s]+):(\d+)',
  );

  static Future<KuboProcessManager> createPrivate({
    required String ipfsBin,
    required String swarmKeyContents,
    bool enableDhtRouting = false,
  }) async {
    final dir = await Directory.systemTemp.createTemp('kubo_pnet_repo_');
    final keyFile = File('${dir.path}/swarm.key');
    await keyFile.writeAsString(swarmKeyContents);
    final port = 25000 + Random().nextInt(15000);
    final mgr = KuboProcessManager(
      ipfsBin: ipfsBin,
      repoDir: dir,
      swarmKeyPath: keyFile.path,
      tcpPort: port,
      enableDhtRouting: enableDhtRouting,
    );
    await mgr.initRepo();
    return mgr;
  }

  static Future<KuboProcessManager> createPublic({
    required String ipfsBin,
  }) async {
    final dir = await Directory.systemTemp.createTemp('kubo_public_repo_');
    final port = 25000 + Random().nextInt(15000);
    final mgr = KuboProcessManager(
      ipfsBin: ipfsBin,
      repoDir: dir,
      tcpPort: port,
    );
    await mgr.initRepo();
    return mgr;
  }

  Future<void> initRepo() async {
    final result = await Process.run(
      ipfsBin,
      ['init', '--profile=test'],
      environment: _env,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      final err = '${result.stderr}${result.stdout}';
      if (!err.contains('already exists') &&
          !err.contains('already initialized')) {
        throw StateError('ipfs init failed: $err');
      }
    }

    final swarm = '["/ip4/127.0.0.1/tcp/$tcpPort"]';
    await _runConfig('Addresses.API', '["/ip4/127.0.0.1/tcp/0"]');
    await _runConfig('Addresses.Gateway', '[]');
    await _runConfig('Addresses.Swarm', swarm);
    await _runConfig('Swarm.DisableNatPortMap', 'true');
    await _runConfig(
      'Routing.Type',
      enableDhtRouting ? '"dht"' : '"none"',
    );
    await _runConfig('Swarm.ResourceMgr.Enabled', 'false');
    if (swarmKeyPath != null) {
      await _runConfig('AutoConf.Enabled', 'false');
      await _runConfig('AutoTLS.Enabled', 'false');
      await _runConfig('DNS.Resolvers', '{}');
      await _runConfig('Routing.DelegatedRouters', '[]');
      await _runConfig('Ipns.DelegatedPublishers', '[]');
    }
    await _runConfig('Swarm.AddrFilters', '[]');
    await _run(['bootstrap', 'rm', '--all']);
  }

  Future<void> startDaemon() async {
    if (_daemon != null) return;

    final logFile = File('${repoDir.path}/daemon.log');
    if (await logFile.exists()) await logFile.delete();

    final envExports = {
      ..._env,
      'IPFS_TELEMETRY': 'off',
    }.entries.map((e) => '${e.key}=${_shellQuote(e.value)}').join(' ');
    _daemon = await Process.start(
      'sh',
      [
        '-c',
        '$envExports $ipfsBin daemon >> ${_shellQuote(logFile.path)} 2>&1',
      ],
    );

    await _waitForListenLog(logFile);
    await _waitForTcpPortOpen();
    _idJson = await _pollIdJson(timeout: const Duration(seconds: 20));
    await _ensureDaemonRunning();
  }

  Future<void> _waitForListenLog(File logFile) async {
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (DateTime.now().isBefore(deadline)) {
      if (await logFile.exists()) {
        final text = await logFile.readAsString();
        final m = _listenLine.firstMatch(text);
        if (m != null) {
          _listenHost = m.group(1);
          _listenPort = int.parse(m.group(2)!);
          if (!_listenReady.isCompleted) _listenReady.complete();
          return;
        }
      }
      if (await _daemonExited()) {
        final log = await logFile.exists() ? await logFile.readAsString() : '';
        throw StateError('Kubo daemon exited early. Log:\n$log');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    throw TimeoutException('Kubo did not log Swarm listening line', const Duration(seconds: 45));
  }

  Future<void> _waitForTcpPortOpen() async {
    final port = _listenPort ?? tcpPort;
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await Socket.connect(
          '127.0.0.1',
          port,
          timeout: const Duration(milliseconds: 300),
        );
        await socket.close();
        return;
      } catch (_) {
        if (await _daemonExited()) {
          throw StateError('Kubo daemon exited before TCP $port was open');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    throw TimeoutException('TCP port $port not open', const Duration(seconds: 20));
  }

  Future<bool> _daemonExited() async {
    if (_daemon == null) return true;
    try {
      await _daemon!.exitCode.timeout(const Duration(milliseconds: 50));
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> _ensureDaemonRunning() async {
    if (await _daemonExited()) {
      final log = File('${repoDir.path}/daemon.log');
      final body = await log.exists() ? await log.readAsString() : '';
      throw StateError('Kubo daemon not running after start. Log:\n$body');
    }
  }

  Future<void> stop() async {
    try {
      await _run(['shutdown']);
    } catch (_) {
      // daemon may already be gone
    }
    _daemon?.kill(ProcessSignal.sigterm);
    _daemon = null;
    if (await repoDir.exists()) {
      await repoDir.delete(recursive: true);
    }
  }

  String get peerId {
    final id = _idJson?['ID'] as String?;
    if (id == null) throw StateError('Kubo peer ID not available');
    return id;
  }

  /// TCP dial multiaddr for this Kubo node (127.0.0.1 + logged port + peer id).
  MultiAddr get dialMultiAddr {
    final port = _listenPort ?? tcpPort;
    final host = (_listenHost == null || _listenHost == '0.0.0.0')
        ? '127.0.0.1'
        : _listenHost!;
    return MultiAddr('/ip4/$host/tcp/$port/p2p/$peerId');
  }

  Future<void> swarmConnect(String multiaddr) async {
    final result = await _run(['swarm', 'connect', multiaddr]);
    if (result.exitCode != 0) {
      final out = '${result.stdout}${result.stderr}';
      if (!out.contains('already connected')) {
        throw StateError('swarm connect failed: $out');
      }
    }
  }

  Future<List<String>> swarmPeers() async {
    final result = await _run(['swarm', 'peers']);
    if (result.exitCode != 0) return [];
    return (result.stdout as String)
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
  }

  Future<String> addBytes(List<int> data, {String filename = 'test.bin'}) async {
    final tmp = File('${repoDir.path}/$filename');
    await tmp.writeAsBytes(data);
    final result = await _run(['add', '-Q', '--pin=false', tmp.path]);
    if (result.exitCode != 0) {
      throw StateError('ipfs add failed: ${result.stderr}');
    }
    return (result.stdout as String).trim().split('\n').last.trim();
  }

  /// Stores a raw block (matches dart_ipfs `Block.fromData` / bitswap interop).
  Future<String> blockPut(List<int> data) async {
    final tmp = File('${repoDir.path}/block_put_${DateTime.now().microsecondsSinceEpoch}.bin');
    await tmp.writeAsBytes(data);
    final result = await Process.run(
      ipfsBin,
      ['block', 'put', tmp.path],
      environment: _env,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw StateError('ipfs block put failed: ${result.stderr}');
    }
    return (result.stdout as String).trim().split('\n').last.trim();
  }

  Future<void> blockRm(String cid) async {
    final result = await _run(['block', 'rm', cid]);
    if (result.exitCode != 0) {
      final out = '${result.stdout}${result.stderr}';
      if (!out.contains('not found')) {
        throw StateError('ipfs block rm failed: $out');
      }
    }
  }

  Future<List<int>> blockGet(String cid) async {
    final result = await Process.run(
      ipfsBin,
      ['block', 'get', cid],
      environment: _env,
      runInShell: true,
      stdoutEncoding: null,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw StateError('ipfs block get failed: ${result.stderr}');
    }
    return (result.stdout as List<int>?) ?? <int>[];
  }

  Future<List<int>> cat(String cid) async {
    final result = await Process.run(
      ipfsBin,
      ['cat', cid],
      environment: _env,
      runInShell: true,
      stdoutEncoding: null,
      stderrEncoding: utf8,
    );
    if (result.exitCode != 0) {
      throw StateError('ipfs cat failed: ${result.stderr}');
    }
    return (result.stdout as List<int>?) ?? <int>[];
  }

  Future<Map<String, dynamic>> idJson() async {
    final result = await _run(['id']);
    if (result.exitCode != 0) {
      throw StateError('ipfs id failed: ${result.stderr}');
    }
    final text = (result.stdout as String).trim();
    return jsonDecode(text) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _pollIdJson({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        return await idJson();
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    throw TimeoutException('ipfs id not available', timeout);
  }

  Future<ProcessResult> _run(List<String> args) {
    return Process.run(
      ipfsBin,
      args,
      environment: _env,
      runInShell: true,
    );
  }

  static String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  Future<void> _runConfig(String key, String jsonValue) async {
    final result = await Process.run(
      ipfsBin,
      ['config', '--json', key, jsonValue],
      environment: _env,
      runInShell: true,
    );
    if (result.exitCode != 0) {
      throw StateError('ipfs config $key failed: ${result.stderr}');
    }
  }
}

/// Poll until [swarmPeers] contains a peer id substring or timeout.
Future<void> waitForKuboPeer(
  KuboProcessManager kubo,
  String peerIdSubstring, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final peers = await kubo.swarmPeers();
    if (peers.any((p) => p.contains(peerIdSubstring))) return;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  throw TimeoutException(
    'Kubo did not see peer containing $peerIdSubstring',
    timeout,
  );
}
