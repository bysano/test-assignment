part of 'watchlist_bloc.dart';

enum WatchlistStatus { loading, ready, failure }

/// Everything about the watchlist *except* the prices.
///
/// Prices deliberately live in [QuoteStore] instead. Keeping them out of bloc
/// state is what stops a tick from rebuilding the list — see NOTES.md. What
/// remains here changes a handful of times a minute, so it costs nothing.
final class WatchlistState extends Equatable {
  const WatchlistState({
    this.status = WatchlistStatus.loading,
    this.instruments = const [],
    this.connection = const FeedIdle(),
    this.stats = const FeedStats(),
    this.error,
  });

  final WatchlistStatus status;
  final List<Instrument> instruments;
  final FeedStatus connection;
  final FeedStats stats;
  final String? error;

  /// True whenever the prices on screen might not be current. Everything that
  /// is not [FeedLive] qualifies — the user must never read a frozen number as
  /// a live one.
  bool get pricesMayBeStale => !connection.isLive;

  WatchlistState copyWith({
    WatchlistStatus? status,
    List<Instrument>? instruments,
    FeedStatus? connection,
    FeedStats? stats,
    String? error,
  }) => WatchlistState(
    status: status ?? this.status,
    instruments: instruments ?? this.instruments,
    connection: connection ?? this.connection,
    stats: stats ?? this.stats,
    error: error ?? this.error,
  );

  @override
  List<Object?> get props => [status, instruments, connection, stats, error];
}
