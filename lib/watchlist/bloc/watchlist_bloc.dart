import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../auth/auth_repository.dart';
import '../../data/api/api_exception.dart';
import '../../data/api/instruments_api.dart';
import '../../data/models/instrument.dart';
import '../../feed/feed_connection.dart';
import '../../feed/feed_status.dart';
import '../../feed/feed_update.dart';
import '../quote_store.dart';

part 'watchlist_event.dart';
part 'watchlist_state.dart';

/// Owns the cold path: which instruments exist, and what the connection is
/// doing. It never sees a price.
///
/// Ticks go straight from [FeedConnection] to [QuoteStore]; this bloc wires
/// the two together once, at startup, and then stays out of the way. That is
/// the deliberate split that keeps a burst from touching bloc state at all.
@injectable
class WatchlistBloc extends Bloc<WatchlistEvent, WatchlistState> {
  WatchlistBloc(this._instruments, this._auth, this._feed, this._quotes)
    : super(const WatchlistState()) {
    on<WatchlistStarted>(_onStarted);
    on<WatchlistRetryRequested>(_onRetryRequested);
    on<_InstrumentsLoaded>(_onInstrumentsLoaded);
    on<_LoadFailed>(_onLoadFailed);
    on<_ConnectionChanged>(_onConnectionChanged);
    on<_StatsRefreshed>(_onStatsRefreshed);
  }

  final InstrumentsApi _instruments;
  final AuthRepository _auth;
  final FeedConnection _feed;
  final QuoteStore _quotes;

  StreamSubscription<FeedStatus>? _statuses;
  StreamSubscription<FeedGapDetected>? _gaps;
  Timer? _statsPoll;

  Future<void> _onStarted(
    WatchlistStarted event,
    Emitter<WatchlistState> emit,
  ) async {
    _statuses ??= _feed.statuses.listen((s) => add(_ConnectionChanged(s)));
    // A gap changes the counters immediately; do not make the user wait for
    // the next poll to learn that data was lost.
    _gaps ??= _feed.gaps.listen((_) => add(const _StatsRefreshed()));
    _statsPoll ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => add(const _StatsRefreshed()),
    );
    await _load();
  }

  Future<void> _onRetryRequested(
    WatchlistRetryRequested event,
    Emitter<WatchlistState> emit,
  ) async {
    emit(state.copyWith(status: WatchlistStatus.loading));
    await _load();
  }

  Future<void> _load() async {
    try {
      final token = await _auth.currentToken();
      add(_InstrumentsLoaded(await _instruments.fetch(token)));
    } on UnauthorizedException {
      // The token died between minting and use; one refresh and one retry.
      try {
        add(
          _InstrumentsLoaded(
            await _instruments.fetch(await _auth.refreshToken()),
          ),
        );
      } catch (_) {
        add(
          const _LoadFailed(
            'Could not load instruments. Please sign in again.',
          ),
        );
      }
    } on InvalidCredentialsException {
      add(const _LoadFailed('Session expired. Please sign in again.'));
    } catch (_) {
      add(const _LoadFailed('Could not reach the feed server. Is it running?'));
    }
  }

  void _onInstrumentsLoaded(
    _InstrumentsLoaded event,
    Emitter<WatchlistState> emit,
  ) {
    // Create every notifier before the list is built, so rows never mutate the
    // store while building.
    _quotes
      ..prime(event.instruments.map((i) => i.symbol))
      ..bindTo(_feed.ticks);

    emit(
      state.copyWith(
        status: WatchlistStatus.ready,
        instruments: event.instruments,
      ),
    );
    _feed.start();
  }

  void _onLoadFailed(_LoadFailed event, Emitter<WatchlistState> emit) {
    emit(state.copyWith(status: WatchlistStatus.failure, error: event.message));
  }

  void _onConnectionChanged(
    _ConnectionChanged event,
    Emitter<WatchlistState> emit,
  ) {
    emit(state.copyWith(connection: event.status, stats: _feed.stats));
  }

  void _onStatsRefreshed(_StatsRefreshed event, Emitter<WatchlistState> emit) {
    final stats = _feed.stats;
    if (stats == state.stats) return; // no churn while nothing misbehaves
    emit(state.copyWith(stats: stats));
  }

  @override
  Future<void> close() async {
    _statsPoll?.cancel();
    await _statuses?.cancel();
    await _gaps?.cancel();
    _feed.stop();
    await super.close();
  }
}
