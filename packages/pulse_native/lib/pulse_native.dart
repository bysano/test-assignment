/// Platform channels for Pulse: secure token storage and network reachability.
///
/// Only iOS has a native implementation today. The public API deliberately
/// says nothing about Keychain or `NWPathMonitor` — adding Android means
/// adding Kotlin classes plus one branch in [PulseNative], and no caller
/// changes at all.
library;

import 'package:flutter/foundation.dart';

import 'src/reachability.dart';
import 'src/secure_token_store.dart';

export 'src/reachability.dart';
export 'src/secure_token_store.dart';

/// Chooses the implementation for the platform the app is running on.
///
/// The single place in the package that knows which platforms exist. On
/// anything unimplemented the fallbacks keep the app working in a clearly
/// degraded way rather than crashing — an in-memory token and an "unknown"
/// network, both of which callers already handle.
final class PulseNative {
  const PulseNative._();

  static bool get _isSupported => defaultTargetPlatform == TargetPlatform.iOS;

  static SecureTokenStore secureTokenStore() => _isSupported
      ? const MethodChannelSecureTokenStore()
      : InMemorySecureTokenStore();

  static Reachability reachability() => _isSupported
      ? const EventChannelReachability()
      : const UnsupportedReachability();
}
