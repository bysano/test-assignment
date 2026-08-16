import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:injectable/injectable.dart';
import 'package:pulse_native/pulse_native.dart';

import '../auth/auth_repository.dart';
import '../core/app_config.dart';
import '../data/api/auth_api.dart';
import '../data/api/instruments_api.dart';
import '../data/platform/platform_network_gate.dart';
import '../data/sse/http_sse_transport.dart';
import '../data/sse/sse_transport.dart';
import '../feed/feed_config.dart';
import '../feed/feed_connection.dart';
import '../feed/network_gate.dart';
import '../watchlist/quote_store.dart';

/// Everything the app is built from, in one readable place.
///
/// Explicit factory methods rather than constructor annotations: several of
/// these types take injectable clocks and randoms with sensible defaults, and
/// spelling the wiring out keeps that visible instead of hiding it behind
/// annotations that would have to register a `DateTime Function()`.
@module
abstract class AppModule {
  @lazySingleton
  AppConfig get config => AppConfig.fromEnvironment();

  @lazySingleton
  http.Client get httpClient => http.Client();

  @lazySingleton
  Random get random => Random();

  @lazySingleton
  FeedConfig get feedConfig => const FeedConfig();

  /// Keychain-backed on iOS, in-memory elsewhere. See [PulseNative].
  @lazySingleton
  SecureTokenStore get secureTokenStore => PulseNative.secureTokenStore();

  /// NWPathMonitor on iOS, "unknown" elsewhere.
  @lazySingleton
  Reachability get reachability => PulseNative.reachability();

  @lazySingleton
  NetworkGate networkGate(Reachability reachability) =>
      PlatformNetworkGate(reachability);

  @lazySingleton
  AuthApi authApi(AppConfig config, http.Client client) =>
      AuthApi(baseUrl: config.baseUrl, client: client);

  @lazySingleton
  InstrumentsApi instrumentsApi(AppConfig config, http.Client client) =>
      InstrumentsApi(baseUrl: config.baseUrl, client: client);

  @lazySingleton
  AuthRepository authRepository(AuthApi api, SecureTokenStore store) =>
      AuthRepository(api: api, store: store);

  @lazySingleton
  SseTransport sseTransport(AppConfig config) =>
      HttpSseTransport(baseUrl: config.baseUrl);

  @lazySingleton
  FeedConnection feedConnection(
    SseTransport transport,
    AuthRepository tokens,
    NetworkGate network,
    FeedConfig config,
    Random random,
  ) => FeedConnection(
    transport: transport,
    tokens: tokens,
    network: network,
    config: config,
    random: random,
  );

  @lazySingleton
  QuoteStore get quoteStore => QuoteStore();
}
