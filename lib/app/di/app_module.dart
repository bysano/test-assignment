import 'dart:math';

import 'package:http/http.dart' as http;
import 'package:injectable/injectable.dart';
import 'package:pulse_native/pulse_native.dart';

import '../../features/auth/data/auth_api.dart';
import '../../features/auth/data/auth_repository.dart';
import '../../features/auth/data/authenticated_client.dart';
import '../../features/auth/domain/token_source.dart';
import '../../features/watchlist/application/feed/feed_config.dart';
import '../../features/watchlist/application/feed/feed_connection.dart';
import '../../features/watchlist/application/feed/network_gate.dart';
import '../../features/watchlist/application/quote_store.dart';
import '../../features/watchlist/data/instruments_api.dart';
import '../../features/watchlist/data/network/platform_network_gate.dart';
import '../../features/watchlist/data/sse/authorized_sse_transport.dart';
import '../../features/watchlist/data/sse/http_sse_transport.dart';
import '../../features/watchlist/data/sse/sse_transport.dart';
import '../config/app_config.dart';

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

  /// Deliberately the **raw** client. `/login` is how a token is obtained, so
  /// routing it through the thing that refreshes tokens would recurse.
  @lazySingleton
  AuthApi authApi(AppConfig config, http.Client client) =>
      AuthApi(baseUrl: config.baseUrl, client: client);

  @lazySingleton
  AuthRepository authRepository(AuthApi api, SecureTokenStore store) =>
      AuthRepository(api: api, store: store);

  /// The one place that knows where tokens come from. Everything below takes
  /// this rather than [AuthRepository], so no transport depends on the auth
  /// layer and none of them owns a private copy of the refresh policy.
  @lazySingleton
  TokenSource tokenSource(AuthRepository repository) => repository;

  /// Every authenticated REST call goes through here — bearer attached, one
  /// refresh-and-retry on a 401.
  @lazySingleton
  AuthenticatedClient authenticatedClient(
    http.Client inner,
    TokenSource tokens,
  ) => AuthenticatedClient(inner: inner, tokens: tokens);

  @lazySingleton
  InstrumentsApi instrumentsApi(AppConfig config, AuthenticatedClient client) =>
      InstrumentsApi(baseUrl: config.baseUrl, client: client);

  @lazySingleton
  SseTransport sseTransport(AppConfig config) =>
      HttpSseTransport(baseUrl: config.baseUrl);

  /// The stream's counterpart to [AuthenticatedClient]: same policy, applied
  /// by decoration because `package:http`'s seam does not reach `dart:io`.
  @lazySingleton
  AuthorizedStream authorizedStream(
    SseTransport transport,
    TokenSource tokens,
  ) => AuthorizedSseTransport(transport: transport, tokens: tokens);

  @lazySingleton
  FeedConnection feedConnection(
    AuthorizedStream stream,
    NetworkGate network,
    FeedConfig config,
    Random random,
  ) => FeedConnection(
    stream: stream,
    network: network,
    config: config,
    random: random,
  );

  @lazySingleton
  QuoteStore get quoteStore => QuoteStore();
}
