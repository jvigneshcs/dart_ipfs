import 'dart:async';
import 'dart:typed_data';

import 'package:dart_ipfs/src/core/config/ipfs_config.dart';
import 'package:dart_ipfs/src/core/data_structures/block.dart';
import 'package:dart_ipfs/src/core/interfaces/i_block_store.dart';
import 'package:dart_ipfs/src/core/interfaces/i_lifecycle.dart';
import 'package:dart_ipfs/src/protocols/bitswap/ledger.dart';
import 'package:dart_ipfs/src/protocols/bitswap/message.dart' as message;
import 'package:dart_ipfs/src/protocols/bitswap/wantlist.dart';
import 'package:dart_ipfs/src/transport/router_events.dart';
import 'package:dart_ipfs/src/transport/router_interface.dart';
import 'package:dart_ipfs/src/utils/generic_lru_cache.dart';
import 'package:dart_ipfs/src/utils/logger.dart';
import 'package:meta/meta.dart';

/// Handles Bitswap protocol operations for an IPFS node following the Bitswap 1.2.0 specification
class BitswapHandler implements ILifecycle {
  /// Creates a new [BitswapHandler] with the given [config], [_blockStore], and [_router].
  BitswapHandler(IPFSConfig config, this._blockStore, this._router)
    : _maxConcurrentRequests = config.maxConcurrentBitswapRequests,
      _logger = Logger(
        'BitswapHandler',
        debug: config.debug,
        verbose: config.verboseLogging,
      ) {
    _logger.info('Initializing BitswapHandler');
    _setupHandlers();
  }
  final IBlockStore _blockStore;
  final RouterInterface _router;
  final Wantlist _wantlist = Wantlist();
  final LedgerManager _ledgerManager = LedgerManager();
  final Map<String, Completer<Block>> _pendingBlocks = {};
  final Map<String, Set<String>> _providersForBlock = {};
  final List<String> _requestQueue = [];
  int _activeRequests = 0;
  final int _maxConcurrentRequests;
  static const String _protocolId = '/ipfs/bitswap/1.2.0';
  bool _running = false;
  final Logger _logger;
  int _bandwidthSent = 0;
  int _bandwidthReceived = 0;
  final Set<String> _sessions = {};
  final Set<String> _connectedPeers = {};
  int _blocksReceived = 0;
  final int _blocksSent = 0;
  StreamSubscription<ConnectionEvent>? _connectionSubscription;

  /// Inbound bitswap packets handled (interop diagnostics).
  @visibleForTesting
  int inboundPacketsHandled = 0;

  /// Cache for block presence checks to avoid repeated blockstore lookups.
  /// Entries expire after 30 seconds to handle block additions/removals.
  final TimedLRUCache<String, bool> _blockPresenceCache = TimedLRUCache(
    capacity: 1000,
    ttl: const Duration(seconds: 30),
  );

  /// Starts the Bitswap handler
  @override
  Future<void> start() async {
    if (_running) {
      _logger.warning('BitswapHandler already running');
      return;
    }

    try {
      _running = true;
      _logger.debug('Starting BitswapHandler...');

      await _router.initialize();
      _logger.verbose('Router initialized');

      await _router.start();
      _logger.verbose('Router started');

      for (final protocolId in const [
        _protocolId,
        '/ipfs/bitswap/1.1.0',
        '/ipfs/bitswap/1.0.0',
      ]) {
        _router.registerProtocolHandler(protocolId, _handlePacket);
        _router.registerProtocol(protocolId);
        _logger.debug('Added message handler for protocol: $protocolId');
      }

      _connectionSubscription = _router.connectionEvents.listen((event) {
        if (event.type == ConnectionEventType.connected) {
          unawaited(_onPeerConnected(event.peerId));
        }
      });

      for (final peerId in _router.connectedPeers) {
        unawaited(_onPeerConnected(peerId));
      }

      _logger.info('BitswapHandler started successfully');
    } catch (e, stackTrace) {
      _logger.error('Failed to start BitswapHandler', e, stackTrace);
      _running = false;
      rethrow;
    }
  }

  /// Stops the Bitswap handler
  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    _logger.debug('Stopping BitswapHandler...');

    // Clean up pending requests
    for (final completer in _pendingBlocks.values) {
      completer.completeError('BitswapHandler stopped');
    }
    _pendingBlocks.clear();
    _sessions.clear();
    _connectedPeers.clear();
    await _connectionSubscription?.cancel();
    _connectionSubscription = null;

    try {
      await _router.stop();
      _logger.info('BitswapHandler stopped successfully');
    } catch (e, st) {
      _logger.error('Error stopping BitswapHandler router', e, st);
    }
  }

  /// Handles incoming Bitswap messages
  Future<void> _handleMessage(
    message.Message message, {
    Future<void> Function(Uint8List)? replyOnStream,
  }) async {
    if (!_running) return;

    final fromPeer = message.from;

    if (message.hasWantlist()) {
      final messageWantlist = message.getWantlist();
      final wantlist = Wantlist();

      for (final entry in messageWantlist.entries.values) {
        wantlist.add(
          entry.cid,
          priority: entry.priority,
          wantType: entry.wantType,
          sendDontHave: entry.sendDontHave,
        );
      }

      // We need 'fromPeer' to reply. If it's missing, we can't reply.
      if (fromPeer != null) {
        await _handleWantlist(
          wantlist,
          fromPeer,
          replyOnStream: replyOnStream,
        );
      }
    }

    if (message.hasBlocks()) {
      await _handleBlocks(message.getBlocks());

      if (fromPeer != null) {
        final ledger = _ledgerManager.getLedger(fromPeer);
        // Update received bytes in ledger
        ledger.addReceivedBytes(
          message
              .getBlocks()
              .map((b) => b.data.length)
              .fold<int>(0, (sum, size) => sum + size),
        );
        _updateBandwidthStats();
      }
    }

    // Handle Bitswap 1.2+ Block Presences (HAVE/DONT_HAVE)
    if (message.hasBlockPresences()) {
      _handleBlockPresences(message.getBlockPresences(), fromPeer);
    }
  }

  /// Handles incoming wantlist entries according to Bitswap spec
  Future<void> _handleWantlist(
    Wantlist wantlist,
    String fromPeer, {
    Future<void> Function(Uint8List)? replyOnStream,
  }) async {
    // SEC-ZDAY-001: Limit entries to prevent DoS (CPU exhaustion on sort/iterate)
    if (wantlist.entries.length > 5000) {
      _logger.warning(
        'Rejected excessive wantlist from $fromPeer (${wantlist.entries.length} entries)',
      );
      return;
    }

    // Sort entries by priority before processing
    final sortedEntries = wantlist.entries.entries.toList()
      ..sort(
        (a, b) => b.value.priority.compareTo(a.value.priority),
      ); // Higher priority first

    _logger.debug('[_handleWantlist] Handling ${sortedEntries.length} entries from $fromPeer');
    final outgoingMessage = message.Message();
    outgoingMessage.from = _router.peerID.toString();
    bool hasContent = false;

    for (final entry in sortedEntries) {
      final cidStr = entry.key;
      final wantEntry = entry.value;
      _logger.debug('[_handleWantlist] Entry: cid=$cidStr, priority=${wantEntry.priority}, wantType=${wantEntry.wantType}');

      // Add to our local wantlist with the received priority
      _wantlist.add(cidStr, priority: wantEntry.priority);

      // Bitswap 1.2: Check if peer wants just 'HAVE' or full block
      if (wantEntry.wantType == message.WantType.have) {
        // Use cache for presence checks (HAVE mode)
        final found = await _blockPresenceCache.getOrCompute(cidStr, () async {
          final response = await _blockStore.getBlock(cidStr);
          return response.found;
        });

        _logger.debug('[_handleWantlist] Block presence check for $cidStr: found=$found');
        if (found) {
          outgoingMessage.addBlockPresence(
            cidStr,
            message.BlockPresenceType.have,
          );
          hasContent = true;
        } else if (wantEntry.sendDontHave) {
          outgoingMessage.addBlockPresence(
            cidStr,
            message.BlockPresenceType.dontHave,
          );
          hasContent = true;
        }
      } else {
        // Standard 'Block' request - need full response for block data
        final response = await _blockStore.getBlock(cidStr);
        _blockPresenceCache.put(cidStr, response.found); // Update cache
        _logger.debug('[_handleWantlist] Block data check for $cidStr: found=${response.found}');

        if (response.found) {
          outgoingMessage.addBlock(Block.fromProto(response.block));
          hasContent = true;
        } else if (wantEntry.sendDontHave) {
          outgoingMessage.addBlockPresence(
            cidStr,
            message.BlockPresenceType.dontHave,
          );
          hasContent = true;
        }
      }
    }

    if (hasContent) {
      try {
        final messageBytes = outgoingMessage.toBytes();
        if (replyOnStream != null) {
          _logger.debug('[_handleWantlist] Sending response containing content on same stream to $fromPeer');
          await replyOnStream(messageBytes);
        } else {
          _logger.debug('[_handleWantlist] Sending response containing content on new stream to $fromPeer');
          await _router.sendMessage(
            fromPeer,
            messageBytes,
            protocolId: _protocolId,
          );
        }

        // Update ledger stats
        final ledger = _ledgerManager.getLedger(fromPeer);
        for (final block in outgoingMessage.getBlocks()) {
          ledger.addSentBytes(block.data.length);
        }
        _updateBandwidthStats();
      } catch (error, st) {
        _logger.error('Error sending response to peer $fromPeer', error, st);
      }
    }
  }

  /// Handles incoming block presences (HAVE/DONT_HAVE)
  void _handleBlockPresences(
    List<message.BlockPresence> presences,
    String? fromPeer,
  ) {
    if (fromPeer == null) return;

    for (final presence in presences) {
      final cid = presence.cid;
      if (presence.type == message.BlockPresenceType.have) {
        _logger.verbose('Peer $fromPeer HAVE $cid');
        // Track this peer as a provider for the block
        _providersForBlock.putIfAbsent(cid, () => {}).add(fromPeer);
      } else {
        _logger.verbose('Peer $fromPeer DONT_HAVE $cid');
        // Remove this peer from providers for the block
        _providersForBlock[cid]?.remove(fromPeer);
      }
    }
  }

  /// Exposes internal block handling for testing.
  @visibleForTesting
  Future<void> handleBlocks(List<Block> blocks) => _handleBlocks(blocks);

  /// Handles incoming blocks according to Bitswap spec
  Future<void> _handleBlocks(List<Block> blocks) async {
    for (final block in blocks) {
      // Validate block hash before storing (SEC-002 security fix)
      final isValid = await block.validate();
      if (!isValid) {
        _logger.warning(
          'Rejected invalid block: ${block.cid.encode()} - hash mismatch',
        );
        continue;
      }

      await _blockStore.putBlock(block);
      _blocksReceived++;

      final cidStr = block.cid.encode();
      // Complete pending request if exists
      final completer = _pendingBlocks.remove(cidStr);
      completer?.complete(block);

      // Remove from wantlist
      if (_wantlist.contains(cidStr)) {
        _wantlist.remove(cidStr);
      }
    }
  }

  /// Requests blocks from the network with proper Bitswap session handling
  Future<List<Block>> want(
    List<String> cids, {
    int priority = 1,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (!_running) {
      throw StateError('BitswapHandler is not running');
    }

    if (_router.connectedPeers.isEmpty) {
      throw StateError('No connected peers available for Bitswap request');
    }

    final completers = <String, Completer<Block>>{};
    for (final cid in cids) {
      if (!_pendingBlocks.containsKey(cid)) {
        final completer = Completer<Block>();
        _pendingBlocks[cid] = completer;
        completers[cid] = completer;
        _wantlist.add(cid, priority: priority);
        _requestQueue.add(cid);
      } else {
        completers[cid] = _pendingBlocks[cid]!;
      }
    }

    unawaited(_processQueue());

    try {
      final futures = completers.values
          .map(
            (completer) => completer.future.timeout(
              timeout,
              onTimeout: () =>
                  throw TimeoutException('Block request timed out'),
            ),
          )
          .toList();

      final blocks = await Future.wait(futures);
      return blocks;
    } catch (e) {
      // Clean up pending requests that failed
      for (final cid in completers.keys) {
        if (_pendingBlocks[cid]?.isCompleted == false) {
          _pendingBlocks.remove(cid);
          _wantlist.remove(cid);
        }
      }
      rethrow;
    }
  }

  Future<void> _processQueue() async {
    if (_activeRequests >= _maxConcurrentRequests || _requestQueue.isEmpty) {
      return;
    }

    while (_activeRequests < _maxConcurrentRequests &&
        _requestQueue.isNotEmpty) {
      final cid = _requestQueue.removeAt(0);
      _activeRequests++;

      unawaited(
        _sendWantRequest(cid)
            .then((_) {
              // We don't decrement _activeRequests here because Bitswap is async.
              // The request is 'active' until the block is received or times out.
              // For simplicity in this implementation, we'll just throttle the initial sending.
            })
            .catchError((Object e) {
              _logger.error('Failed to send want request for $cid: $Object e');
            })
            .whenComplete(() {
              _activeRequests--;
              unawaited(_processQueue());
            }),
      );
    }
  }

  Future<void> _sendWantRequest(String cid) async {
    final msg = message.Message();
    msg.addWantlistEntry(
      cid,
      priority: 1, // Default priority for queue processing
      wantType: message.WantType.block,
      sendDontHave: true,
    );
    await _broadcastWantRequest(msg);
  }

  /// Broadcasts want request to connected peers
  Future<void> _broadcastWantRequest(message.Message message) async {
    final connectedPeers = _router.connectedPeers;

    if (connectedPeers.isEmpty) {
      _logger.warning('No connected peers to broadcast want request to');
      throw StateError('No connected peers available for Bitswap request');
    }

    final messageBytes = message.toBytes();
    final futures = <Future<void>>[];

    // Determine target peers
    Set<String> targets = {};

    // For Bitswap 1.2 smart routing: check if we know providers for any requested CIDs
    for (final entry in message.getWantlist().entries.values) {
      final providers = _providersForBlock[entry.cid];
      if (providers != null && providers.isNotEmpty) {
        // Intersect known providers with currently connected peers
        for (final provider in providers) {
          if (connectedPeers.contains(provider)) {
            targets.add(provider);
          }
        }
      }
    }

    // If no specific providers found or connected, broadcast to all
    bool isBroadcast = false;
    if (targets.isEmpty) {
      targets = connectedPeers;
      isBroadcast = true;
    }

    _logger.debug(
      isBroadcast
          ? 'Broadcasting want request to ${targets.length} peers'
          : 'Sending targeted want request to ${targets.length} providers',
    );

    for (final peerId in targets) {
      futures.add(
        (() async {
          try {
            await _router.sendMessage(
              peerId,
              messageBytes,
              protocolId: _protocolId,
            );
            _logger.verbose('Want request sent to peer: $peerId');
          } catch (error, st) {
            _logger.error(
              'Error sending want request to peer $peerId',
              error,
              st,
            );
          }
        })(),
      );
    }

    await Future.wait(futures);
  }

  Future<void> _handlePacket(NetworkPacket packet) async {
    inboundPacketsHandled++;
    _logger.debug('[_handlePacket] Processing inbound packet #$inboundPacketsHandled from ${packet.srcPeerId}, size: ${packet.datagram.length} bytes');
    try {
      final msg = await message.Message.fromBytes(packet.datagram);
      _logger.debug('[_handlePacket] Parsed message: hasWantlist=${msg.hasWantlist()}, hasBlocks=${msg.hasBlocks()}, blockPresences=${msg.getBlockPresences().length}');
      // Annotate message with sender
      msg.from = packet.srcPeerId;

      await _handleMessage(msg, replyOnStream: null);
      _logger.debug('[_handlePacket] Finished processing inbound packet from ${packet.srcPeerId}');
    } catch (e, st) {
      _logger.error(
        'Failed to handle Bitswap packet from ${packet.srcPeerId}: $e',
      );
      _logger.error('$st');
    }
  }

  /// Handles an incoming want request for a CID.
  Future<void> handleWantRequest(String cidStr) async {
    try {
      final customMessage = message.Message();
      customMessage.addWantlistEntry(
        cidStr,
        priority: 1,
        wantType: message.WantType.block,
        sendDontHave: true,
      );

      await _broadcastWantRequest(customMessage);
    } catch (e, st) {
      _logger.error('Error handling want request for $cidStr', e, st);
      rethrow;
    }
  }

  void _setupHandlers() {
    _logger.debug('Setting up Bitswap protocol handlers');
    _router.registerProtocol(_protocolId);
    _logger.debug('Registered protocol: $_protocolId');

    _router.registerProtocolHandler(_protocolId, _handlePacket);
    _logger.debug('Added message handler for protocol: $_protocolId');

    _logger.info('Bitswap protocol handlers initialized');
  }

  /// Pushes the local wantlist snapshot to all connected peers.
  Future<void> syncSessionsToConnectedPeers() async {
    for (final peerId in _router.connectedPeers) {
      await _onPeerConnected(peerId);
    }
  }

  Future<void> _onPeerConnected(String peerId) async {
    if (!_running) return;
    try {
      await _sendWantlistSnapshot(peerId);
    } catch (e, st) {
      _logger.verbose('Bitswap wantlist sync to $peerId failed: $e');
      _logger.verbose('$st');
    }
  }

  /// Sends the local wantlist snapshot (required to start bitswap sessions).
  Future<void> _sendWantlistSnapshot(String peerId) async {
    final outgoing = message.Message()..wantlistFull = true;
    for (final entry in _wantlist.entries.values) {
      outgoing.addWantlistEntry(
        entry.cid,
        priority: entry.priority,
        cancel: entry.cancel,
        wantType: entry.wantType,
        sendDontHave: entry.sendDontHave,
      );
    }
    await _sendBitswapToPeer(peerId, outgoing.toBytes());
  }

  Future<void> _sendBitswapToPeer(String peerId, Uint8List messageBytes) async {
    await _router.sendMessage(
      peerId,
      messageBytes,
      protocolId: _protocolId,
    );
  }

  /// Notifies connected peers that this node has [cid] (Bitswap 1.2 HAVE).
  ///
  /// Required for peers like Kubo with `Routing.Type=none`, which discover
  /// providers via bitswap block-presence messages rather than the DHT.
  Future<void> announceHave(String cid) async {
    if (!_running) return;

    final response = await _blockStore.getBlock(cid);
    if (!response.found) return;

    _blockPresenceCache.put(cid, true);

    final outgoing = message.Message();
    outgoing.addBlockPresence(cid, message.BlockPresenceType.have);
    final messageBytes = outgoing.toBytes();

    for (final peerId in _router.connectedPeers) {
      try {
        await _sendBitswapToPeer(peerId, messageBytes);
      } catch (e, st) {
        _logger.verbose('HAVE announce to $peerId failed: $e');
        _logger.verbose('$st');
      }
    }
  }

  /// Pushes a block to a connected peer (bitswap payload message).
  Future<void> offerBlockToPeer(String peerId, Block block) async {
    if (!_running) {
      throw StateError('BitswapHandler is not running');
    }
    final outgoing = message.Message();
    outgoing.addBlock(block);
    await _router.sendMessage(
      peerId,
      outgoing.toBytes(),
      protocolId: _protocolId,
    );
  }

  /// Requests a single block by CID.
  Future<Block?> wantBlock(String cid) async {
    if (!_running) {
      throw StateError('BitswapHandler is not running');
    }

    try {
      final blocks = await want([cid]);
      return blocks.isNotEmpty ? blocks.first : null;
    } catch (e, st) {
      _logger.error('Error requesting block $cid', e, st);
      return null;
    }
  }

  /// Total bytes sent.
  int get bandwidthSent => _bandwidthSent;

  /// Total bytes received.
  int get bandwidthReceived => _bandwidthReceived;

  void _updateBandwidthStats() {
    final stats = _ledgerManager.getBandwidthStats();
    _bandwidthSent = stats['sent'] ?? 0;
    _bandwidthReceived = stats['received'] ?? 0;
  }

  /// Returns the current status of the Bitswap handler.
  Future<Map<String, dynamic>> getStatus() async {
    return {
      'active_sessions': _sessions.length,
      'wanted_blocks': _wantlist.entries.length,
      'peers': _connectedPeers.length,
      'blocks_received': _blocksReceived,
      'blocks_sent': _blocksSent,
    };
  }
}
