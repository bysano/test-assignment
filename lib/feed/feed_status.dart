import 'package:equatable/equatable.dart';

/// What the feed is doing right now.
///
/// The UI must never let the user mistake frozen prices for live ones, so
/// every state that is *not* [FeedLive] is treated as "these numbers may be
/// wrong" and rendered accordingly.
sealed class FeedStatus extends Equatable {
  const FeedStatus();

  /// True only when data is genuinely flowing.
  bool get isLive => this is FeedLive;

  @override
  List<Object?> get props => [runtimeType];
}

/// Not started, or stopped.
final class FeedIdle extends FeedStatus {
  const FeedIdle();
}

/// Opening a stream. [attempt] is 0 for the first try of a session.
final class FeedConnecting extends FeedStatus {
  const FeedConnecting(this.attempt);

  final int attempt;

  @override
  List<Object?> get props => [runtimeType, attempt];
}

/// Connected and receiving — ticks or at least heartbeats.
final class FeedLive extends FeedStatus {
  const FeedLive();
}

/// The socket is open but has gone silent: no ticks, no heartbeats.
///
/// The dangerous state, and the reason the watchdog exists — without it this
/// looks exactly like a quiet market.
final class FeedStalled extends FeedStatus {
  const FeedStalled();
}

/// Waiting out a backoff delay before the next attempt.
final class FeedReconnecting extends FeedStatus {
  const FeedReconnecting({required this.attempt, required this.delay});

  /// 1-based number of the attempt we are about to make.
  final int attempt;

  /// How long until that attempt fires, for a countdown in the UI.
  final Duration delay;

  @override
  List<Object?> get props => [runtimeType, attempt, delay];
}

/// The platform reports no network. We deliberately stop retrying rather than
/// burning battery on connections that cannot succeed.
final class FeedOffline extends FeedStatus {
  const FeedOffline();
}

/// Unrecoverable without the user — the credentials themselves were rejected.
final class FeedFatal extends FeedStatus {
  const FeedFatal(this.message);

  final String message;

  @override
  List<Object?> get props => [runtimeType, message];
}
