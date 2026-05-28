import 'dart:io';
import 'dart:typed_data';

import 'package:dart_libp2p_pnet/dart_libp2p_pnet.dart' as pnet;
import 'package:ipfs_libp2p/core/multiaddr.dart';
import 'package:ipfs_libp2p/core/network/conn.dart';
import 'package:ipfs_libp2p/core/network/context.dart';
import 'package:ipfs_libp2p/core/network/rcmgr.dart';
import 'package:ipfs_libp2p/core/network/stream.dart';
import 'package:ipfs_libp2p/core/network/transport_conn.dart';
import 'package:ipfs_libp2p/core/peer/peer_id.dart';
import 'package:ipfs_libp2p/core/crypto/keys.dart';
import 'package:ipfs_libp2p/p2p/transport/listener.dart';
import 'package:ipfs_libp2p/p2p/transport/tcp_connection.dart';
import 'package:ipfs_libp2p/p2p/transport/tcp_transport.dart';
import 'package:ipfs_libp2p/p2p/transport/transport.dart';
import 'package:ipfs_libp2p/p2p/transport/transport_config.dart';

/// TCP transport that applies PNET below Noise when a PSK is configured.
///
/// Bridges [dart_libp2p_pnet] with published [ipfs_libp2p] until it ships
/// native [Libp2p.privateNetwork] (monorepo [dart_libp2p] Phase 3).
class PnetTcpTransport implements Transport {
  PnetTcpTransport(this._inner, Uint8List psk32)
      : _protector = pnet.PskConnectionProtector.bytes(psk32);

  final TCPTransport _inner;
  final pnet.PskConnectionProtector _protector;

  factory PnetTcpTransport.wrap(TCPTransport inner, Uint8List psk32) {
    return PnetTcpTransport(inner, psk32);
  }

  @override
  TransportConfig get config => _inner.config;

  @override
  List<String> get protocols => _inner.protocols;

  @override
  bool canDial(MultiAddr addr) => _inner.canDial(addr);

  @override
  bool canListen(MultiAddr addr) => _inner.canListen(addr);

  @override
  Future<Conn> dial(MultiAddr addr, {Duration? timeout}) async {
    final raw = await _inner.dial(addr, timeout: timeout) as TransportConn;
    return _protect(raw);
  }

  @override
  Future<Listener> listen(MultiAddr addr) async {
    final listener = await _inner.listen(addr);
    return _PnetListener(listener, _protector);
  }

  @override
  Future<void> dispose() => _inner.dispose();

  Future<TransportConn> _protect(TransportConn raw) async {
    if (raw is PnetTransportConn) return raw;
    if (raw is! TCPConnection) {
      throw StateError(
        'PNET TCP wrapper requires TCPConnection, got ${raw.runtimeType}',
      );
    }
    final adapter = _TransportConnPnetAdapter(raw);
    final protected = await _protector.protect(adapter);
    return PnetTransportConn(raw, protected as pnet.ProtectedConnection);
  }
}

class _PnetListener implements Listener {
  _PnetListener(this._inner, this._protector);

  final Listener _inner;
  final pnet.PskConnectionProtector _protector;

  @override
  MultiAddr get addr => _inner.addr;

  @override
  bool supportsAddr(MultiAddr addr) => _inner.supportsAddr(addr);

  @override
  Stream<TransportConn> get connectionStream => _inner.connectionStream
      .asyncMap((conn) => _wrap(conn));

  Future<TransportConn> _wrap(TransportConn conn) async {
    if (conn is PnetTransportConn) return conn;
    if (conn is! TCPConnection) return conn;
    final adapter = _TransportConnPnetAdapter(conn);
    final protected = await _protector.protect(adapter);
    return PnetTransportConn(conn, protected as pnet.ProtectedConnection);
  }

  @override
  Future<TransportConn?> accept() async {
    final conn = await _inner.accept();
    if (conn == null) return null;
    return _wrap(conn);
  }

  @override
  Future<void> close() => _inner.close();

  @override
  bool get isClosed => _inner.isClosed;
}

class _TransportConnPnetAdapter implements pnet.PnetByteConn {
  _TransportConnPnetAdapter(this._conn);

  final TCPConnection _conn;

  @override
  bool get isClosed => _conn.isClosed;

  @override
  Future<void> close() => _conn.close();

  @override
  Future<Uint8List> read([int? length]) => _conn.read(length);

  @override
  Future<void> write(Uint8List data) => _conn.write(data);

  @override
  void pushBack(Uint8List data) {
    // ipfs_libp2p 0.5.6 TCPConnection has no pushBack; PNET plaintext queue
    // still works for reads initiated after negotiation on newer libp2p.
  }
}

/// [TransportConn] with PNET applied.
class PnetTransportConn implements TransportConn {
  PnetTransportConn(this._inner, this._protected);

  final TCPConnection _inner;
  final pnet.ProtectedConnection _protected;

  void pushBack(Uint8List data) => _protected.pushBack(data);

  @override
  Future<Uint8List> read([int? length]) => _protected.read(length);

  @override
  Future<void> write(Uint8List data) => _protected.write(data);

  @override
  Socket get socket => _inner.socket;

  @override
  void setReadTimeout(Duration timeout) => _inner.setReadTimeout(timeout);

  @override
  void setWriteTimeout(Duration timeout) => _inner.setWriteTimeout(timeout);

  @override
  void notifyActivity() => _inner.notifyActivity();

  @override
  Future<void> close() => _protected.close();

  @override
  String get id => _inner.id;

  @override
  PeerId get localPeer => _inner.localPeer;

  @override
  PeerId get remotePeer => _inner.remotePeer;

  @override
  Future<PublicKey?> get remotePublicKey => _inner.remotePublicKey;

  @override
  MultiAddr get localMultiaddr => _inner.localMultiaddr;

  @override
  MultiAddr get remoteMultiaddr => _inner.remoteMultiaddr;

  @override
  bool get isClosed => _inner.isClosed;

  @override
  ConnState get state => _inner.state;

  @override
  ConnStats get stat => _inner.stat;

  @override
  ConnScope get scope => _inner.scope;

  @override
  Future<P2PStream> newStream(Context context) => _inner.newStream(context);

  @override
  Future<List<P2PStream>> get streams => _inner.streams;
}
