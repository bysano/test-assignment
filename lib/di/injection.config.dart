// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// InjectableConfigGenerator
// **************************************************************************

// ignore_for_file: type=lint
// coverage:ignore-file

// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'dart:math' as _i407;

import 'package:get_it/get_it.dart' as _i174;
import 'package:http/http.dart' as _i519;
import 'package:injectable/injectable.dart' as _i526;
import 'package:pulse_native/pulse_native.dart' as _i1048;

import '../auth/auth_repository.dart' as _i778;
import '../auth/bloc/auth_bloc.dart' as _i385;
import '../core/app_config.dart' as _i518;
import '../data/api/auth_api.dart' as _i17;
import '../data/api/authenticated_client.dart' as _i918;
import '../data/api/instruments_api.dart' as _i865;
import '../data/api/token_source.dart' as _i1023;
import '../data/sse/authorized_sse_transport.dart' as _i466;
import '../data/sse/sse_transport.dart' as _i80;
import '../feed/feed_config.dart' as _i715;
import '../feed/feed_connection.dart' as _i996;
import '../feed/network_gate.dart' as _i449;
import '../watchlist/bloc/watchlist_bloc.dart' as _i949;
import '../watchlist/quote_store.dart' as _i1054;
import 'app_module.dart' as _i460;

extension GetItInjectableX on _i174.GetIt {
  // initializes the registration of main-scope dependencies inside of GetIt
  _i174.GetIt init({
    String? environment,
    _i526.EnvironmentFilter? environmentFilter,
  }) {
    final gh = _i526.GetItHelper(this, environment, environmentFilter);
    final appModule = _$AppModule();
    gh.lazySingleton<_i518.AppConfig>(() => appModule.config);
    gh.lazySingleton<_i519.Client>(() => appModule.httpClient);
    gh.lazySingleton<_i407.Random>(() => appModule.random);
    gh.lazySingleton<_i715.FeedConfig>(() => appModule.feedConfig);
    gh.lazySingleton<_i1048.SecureTokenStore>(() => appModule.secureTokenStore);
    gh.lazySingleton<_i1048.Reachability>(() => appModule.reachability);
    gh.lazySingleton<_i1054.QuoteStore>(() => appModule.quoteStore);
    gh.lazySingleton<_i80.SseTransport>(
      () => appModule.sseTransport(gh<_i518.AppConfig>()),
    );
    gh.lazySingleton<_i449.NetworkGate>(
      () => appModule.networkGate(gh<_i1048.Reachability>()),
    );
    gh.lazySingleton<_i17.AuthApi>(
      () => appModule.authApi(gh<_i518.AppConfig>(), gh<_i519.Client>()),
    );
    gh.lazySingleton<_i778.AuthRepository>(
      () => appModule.authRepository(
        gh<_i17.AuthApi>(),
        gh<_i1048.SecureTokenStore>(),
      ),
    );
    gh.lazySingleton<_i1023.TokenSource>(
      () => appModule.tokenSource(gh<_i778.AuthRepository>()),
    );
    gh.factory<_i385.AuthBloc>(
      () => _i385.AuthBloc(gh<_i778.AuthRepository>()),
    );
    gh.lazySingleton<_i466.AuthorizedStream>(
      () => appModule.authorizedStream(
        gh<_i80.SseTransport>(),
        gh<_i1023.TokenSource>(),
      ),
    );
    gh.lazySingleton<_i996.FeedConnection>(
      () => appModule.feedConnection(
        gh<_i466.AuthorizedStream>(),
        gh<_i449.NetworkGate>(),
        gh<_i715.FeedConfig>(),
        gh<_i407.Random>(),
      ),
    );
    gh.lazySingleton<_i918.AuthenticatedClient>(
      () => appModule.authenticatedClient(
        gh<_i519.Client>(),
        gh<_i1023.TokenSource>(),
      ),
    );
    gh.lazySingleton<_i865.InstrumentsApi>(
      () => appModule.instrumentsApi(
        gh<_i518.AppConfig>(),
        gh<_i918.AuthenticatedClient>(),
      ),
    );
    gh.factory<_i949.WatchlistBloc>(
      () => _i949.WatchlistBloc(
        gh<_i865.InstrumentsApi>(),
        gh<_i996.FeedConnection>(),
        gh<_i1054.QuoteStore>(),
      ),
    );
    return this;
  }
}

class _$AppModule extends _i460.AppModule {}
