import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:pulse_native/pulse_native.dart';

import '../../application/feed/network_gate.dart';

/// Adapts the platform's tri-state reachability onto the boolean the feed
/// actually reasons about.
///
/// The feed declares [NetworkGate], the platform speaks [NetworkStatus], and
/// this adapter keeps their mapping in one legible line — `unknown` counts as
/// online.
///
/// Optimistic until proven otherwise. Treating "we cannot tell" as offline
/// would stop reconnection on any platform whose channel is missing or broken,
/// which is a far worse failure than a few doomed connection attempts.
class PlatformNetworkGate implements NetworkGate {
  PlatformNetworkGate(Reachability reachability) {
    _source = reachability.changes().listen(
      _onStatus,
      onError: (Object _) {
        // A channel that fails tells us nothing about the network.
        _onStatus(NetworkStatus.unknown);
      },
    );
  }

  late final StreamSubscription<NetworkStatus> _source;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  bool _online = true;

  @override
  bool get isOnline => _online;

  @override
  Stream<bool> get changes => _changes.stream;

  void _onStatus(NetworkStatus status) {
    // Every value, not just transitions: reachability changes are rare, and a
    // channel that has silently stopped reporting is otherwise invisible —
    // the app would sit believing whatever it last heard.
    debugPrint('[pulse.network] reachability: ${status.name}');

    final online = status != NetworkStatus.offline;
    if (online == _online) return; // only transitions are interesting
    _online = online;
    if (!_changes.isClosed) _changes.add(online);
  }

  Future<void> dispose() async {
    await _source.cancel();
    await _changes.close();
  }
}
