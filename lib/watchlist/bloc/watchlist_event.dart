part of 'watchlist_bloc.dart';

sealed class WatchlistEvent extends Equatable {
  const WatchlistEvent();

  @override
  List<Object?> get props => [];
}

/// Load the instrument list and bring the feed up.
final class WatchlistStarted extends WatchlistEvent {
  const WatchlistStarted();
}

/// The user asked to try again after the instrument load failed.
final class WatchlistRetryRequested extends WatchlistEvent {
  const WatchlistRetryRequested();
}

final class _InstrumentsLoaded extends WatchlistEvent {
  const _InstrumentsLoaded(this.instruments);

  final List<Instrument> instruments;

  @override
  List<Object?> get props => [instruments];
}

final class _LoadFailed extends WatchlistEvent {
  const _LoadFailed(this.message);

  final String message;

  @override
  List<Object?> get props => [message];
}

final class _ConnectionChanged extends WatchlistEvent {
  const _ConnectionChanged(this.status);

  final FeedStatus status;

  @override
  List<Object?> get props => [status];
}

/// Periodic, plus immediately after a gap — drives the diagnostics line.
final class _StatsRefreshed extends WatchlistEvent {
  const _StatsRefreshed();
}
