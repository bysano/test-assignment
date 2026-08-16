import 'package:flutter/services.dart';

/// What the platform believes about network reachability.
///
/// [unknown] is a first-class answer, not an error: a platform without an
/// implementation must not be mistaken for a platform that is offline, or
/// callers would stop retrying forever.
enum NetworkStatus { online, offline, unknown }

/// Native reachability events.
///
/// iOS backs this with `NWPathMonitor`. Android would answer the same channel
/// with a `ConnectivityManager.NetworkCallback` and emit the same three
/// strings; nothing above this file would change.
abstract interface class Reachability {
  /// Reachability over time.
  ///
  /// Implementations emit the current status as soon as a listener attaches —
  /// `NWPathMonitor` delivers the current path on start, which is what makes
  /// that contract honest rather than aspirational.
  Stream<NetworkStatus> changes();
}

class EventChannelReachability implements Reachability {
  const EventChannelReachability();

  static const EventChannel channel = EventChannel('pulse/reachability');

  @override
  Stream<NetworkStatus> changes() => channel
      .receiveBroadcastStream()
      .map(_parse)
      // A broken channel must degrade to "we cannot tell", never to "offline".
      .handleError((Object _) {})
      .cast<NetworkStatus>();

  static NetworkStatus _parse(Object? event) => switch (event) {
    'online' => NetworkStatus.online,
    'offline' => NetworkStatus.offline,
    _ => NetworkStatus.unknown,
  };
}

/// Fallback for platforms with no native implementation. Reports [unknown]
/// once, so callers stay optimistic and keep retrying.
class UnsupportedReachability implements Reachability {
  const UnsupportedReachability();

  @override
  Stream<NetworkStatus> changes() => Stream.value(NetworkStatus.unknown);
}
