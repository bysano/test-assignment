import 'package:equatable/equatable.dart';

import '../../domain/models/tick.dart';

/// Why a received event never reached the screen.
enum RejectReason {
  /// The feed re-sent an event we have already processed.
  duplicate,

  /// The tick carries a market timestamp older than one we already showed for
  /// that symbol.
  stale,

  /// The payload could not be decoded, or the event type is not one we speak.
  malformed,
}

/// The result of pushing one SSE event through [TickPipeline].
sealed class FeedUpdate {
  const FeedUpdate();
}

final class TickAccepted extends FeedUpdate {
  const TickAccepted(this.tick);

  final Tick tick;
}

final class TickRejected extends FeedUpdate {
  const TickRejected(this.reason);

  final RejectReason reason;
}

/// The server could not replay from our `Last-Event-ID` — events were lost.
final class FeedGapDetected extends FeedUpdate {
  const FeedGapDetected(this.resumeFrom);

  /// The id the server is resuming from, when it told us.
  final int? resumeFrom;
}

/// Running tally of how the feed has misbehaved, surfaced in the UI so the
/// resilience work is observable rather than merely claimed.
final class FeedStats extends Equatable {
  const FeedStats({
    this.accepted = 0,
    this.duplicates = 0,
    this.stale = 0,
    this.malformed = 0,
    this.gaps = 0,
  });

  final int accepted;
  final int duplicates;
  final int stale;
  final int malformed;
  final int gaps;

  @override
  List<Object?> get props => [accepted, duplicates, stale, malformed, gaps];
}
