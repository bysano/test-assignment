/// What the feed needs to know about the network, and nothing more.
///
/// Deliberately narrower than the platform plugin's API. The feed application
/// layer owns this contract; an adapter maps the plugin onto it. That keeps
/// the state machine free of Flutter and lets reconnect tests drive
/// connectivity by hand.
abstract interface class NetworkGate {
  /// Optimistic by design: false only when the platform is *sure* there is no
  /// route. An unknown or unsupported platform reports true, so a missing
  /// implementation can never wedge the reconnect loop.
  bool get isOnline;

  /// Transitions only — does not replay the current value on listen.
  Stream<bool> get changes;
}

/// Used on platforms without a reachability implementation, and as the default
/// in tests that are not about connectivity.
final class AlwaysOnlineGate implements NetworkGate {
  const AlwaysOnlineGate();

  @override
  bool get isOnline => true;

  @override
  Stream<bool> get changes => const Stream<bool>.empty();
}
