import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:injectable/injectable.dart';

import '../../../../core/errors/api_exception.dart';
import '../../application/feed/feed_connection.dart';
import '../../application/feed/feed_status.dart';
import '../../application/feed/feed_update.dart';
import '../../application/quote_store.dart';
import '../../data/instruments_api.dart';
import '../../domain/models/instrument.dart';

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
  WatchlistBloc(this._instruments, this._feed, this._quotes)
    : super(const WatchlistState()) {
    on<WatchlistStarted>(_onStarted);
    on<WatchlistRetryRequested>(_onRetryRequested);
    on<_InstrumentsLoaded>(_onInstrumentsLoaded);
    on<_LoadFailed>(_onLoadFailed);
    on<_ConnectionChanged>(_onConnectionChanged);
    on<_StatsRefreshed>(_onStatsRefreshed);
  }

  final InstrumentsApi _instruments;
  final FeedConnection _feed;
  final QuoteStore _quotes;

  StreamSubscription<FeedStatus>? _statuses;
  StreamSubscription<FeedGapDetected>? _gaps;
  Timer? _statsPoll;

  /// Set the instant [close] begins, before anything can await.
  ///
  /// `isClosed` alone is a weaker guard than it looks. `Bloc.close()` shuts
  /// the event controller *first* and only flips `isClosed` in `super.close()`
  /// three awaits later, so a continuation resuming in between finds
  /// `isClosed == false` and still throws on `add`.
  ///
  /// Being straight about the evidence: that window is narrow — this bloc's
  /// own `close()` awaits several times before reaching `super.close()`, and
  /// the tests never manage to land in it. The flag is reasoned from bloc's
  /// source rather than driven by a failing test. It is kept because the
  /// failure mode is an unhandled exception, and because it keeps the guard
  /// correct if [close] is ever reordered.
  bool _closing = false;

  /// Whether it is still safe to [add] an event from an async continuation.
  bool get _accepting => !_closing && !isClosed;

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

  /// Resolves the whole load to a single outcome, then dispatches it once.
  ///
  /// Everything above the dispatch is network work behind an `await`, and
  /// signing out disposes this bloc — so by the time we get here the bloc may
  /// be gone. Two rules keep that safe:
  ///
  /// * the `try` covers only the awaits, never the `add`, so a dispatch
  ///   failure can never be mistaken for a network fault and answered with a
  ///   second dispatch (which is exactly how this crashed: `add` threw, the
  ///   broad `catch` swallowed the StateError, and the `add` in the handler
  ///   threw again with nothing left to catch it);
  /// * there is exactly one `add`, and it is guarded.
  Future<void> _load() async {
    final outcome = await _loadOutcome();
    if (!_accepting) return; // signed out while the request was in flight
    add(outcome);
  }

  /// Does the network work and reports what happened. Cannot dispatch, which
  /// is the point: no `catch` in here can answer a failed dispatch with
  /// another one.
  Future<WatchlistEvent> _loadOutcome() async {
    try {
      // No token handling here: the API is given an AuthenticatedClient, which
      // attaches the bearer and has already spent its one refresh by the time
      // anything reaches these catches.
      return _InstrumentsLoaded(await _instruments.fetch());
    } on UnauthorizedException {
      return const _LoadFailed('Session expired. Please sign in again.');
    } on InvalidCredentialsException {
      return const _LoadFailed('Session expired. Please sign in again.');
    } catch (_) {
      return const _LoadFailed(
        'Could not reach the feed server. Is it running?',
      );
    }
  }

  void _onInstrumentsLoaded(
    _InstrumentsLoaded event,
    Emitter<WatchlistState> emit,
  ) {
    // The store is a singleton and outlives this bloc, so a second sign-in
    // would otherwise inherit the first session's prices — and go on showing
    // them while the badge already read "Live", which is exactly the
    // frozen-prices-look-live failure this app must not have.
    //
    // Clearing at session *start* rather than only at sign-out is the stronger
    // guarantee: it holds even if the previous bloc was never closed cleanly.
    // Then prime, so every notifier exists before the list is built and rows
    // never mutate the store while building.
    _quotes
      ..clear()
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
    _closing = true; // before anything can await — see the field's doc
    _statsPoll?.cancel();
    await _statuses?.cancel();
    await _gaps?.cancel();
    _feed.stop();
    // Unbind before clearing, or a tick already in flight could repopulate the
    // store we just emptied. Belt and braces alongside the clear at session
    // start: this one also keeps a signed-out user's prices out of memory.
    await _quotes.detach();
    _quotes.clear();
    await super.close();
  }
}
