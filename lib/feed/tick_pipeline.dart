import 'dart:convert';

import '../data/models/tick.dart';
import '../data/sse/sse_frame.dart';
import 'feed_update.dart';

/// Turns raw SSE events into ticks that are safe to display.
///
/// The feed has two independent ordering hazards, so this has two independent
/// guards:
///
/// * **Re-sent events.** The server occasionally replays a buffered event
///   verbatim, same id and all. Dedup runs first, before anything that could
///   produce a visible artifact — otherwise a duplicate would flash a row a
///   second time for a price that never moved.
///
/// * **Replayed timestamps.** The server also emits *new* events carrying a
///   market timestamp 3s in the past. Those have fresh ids, so dedup cannot see
///   them; only a per-symbol timestamp comparison can.
///
/// Dedup keys on the id alone rather than a set of seen ids because the server
/// assigns `++seq` at emit time — ids are strictly increasing on the wire even
/// when the timestamps inside them are not. That makes `id <= maxSeen` an exact
/// duplicate test in O(1) with no bookkeeping to bound.
///
/// Pure Dart, no Flutter, no I/O, no clock.
class TickPipeline {
  /// How many duplicates in a row, with nothing accepted between them, before
  /// we conclude the id sequence restarted rather than that the feed is
  /// repeating itself.
  ///
  /// The server re-sends exactly one buffered event per misbehaviour, so a
  /// genuine duplicate run is length one, occasionally two. Twenty in a row
  /// with nothing accepted is not a coincidence.
  static const int _resetAfterConsecutiveDuplicates = 20;

  int? _maxSeenId;
  final Map<String, int> _lastTsBySymbol = {};
  int _consecutiveDuplicates = 0;

  int _accepted = 0;
  int _duplicates = 0;
  int _stale = 0;
  int _malformed = 0;
  int _gaps = 0;

  /// Cursor for `Last-Event-ID` on the next reconnect. Null until the first
  /// identified event arrives.
  int? get lastEventId => _maxSeenId;

  FeedStats get stats => FeedStats(
    accepted: _accepted,
    duplicates: _duplicates,
    stale: _stale,
    malformed: _malformed,
    gaps: _gaps,
  );

  FeedUpdate process(SseEvent event) => switch (event.event) {
    'tick' => _processTick(event),
    'gap' => _processGap(event),
    // In this protocol anything else is unusable by definition — including the
    // untyped garbage payloads the feed injects deliberately.
    _ => _reject(RejectReason.malformed),
  };

  FeedUpdate _processTick(SseEvent event) {
    final id = event.id;
    if (id == null) return _reject(RejectReason.malformed);

    final maxSeen = _maxSeenId;
    if (maxSeen != null && id <= maxSeen) {
      _consecutiveDuplicates++;
      // A long unbroken run of "duplicates" is not the feed repeating itself,
      // it is the id sequence having restarted underneath us — a server
      // bounce. The server does not always announce that with a gap event:
      // if its fresh buffer is non-empty it takes the replay branch, finds
      // nothing above our cursor, and says nothing at all. Left alone we
      // would reject every future event while still reporting "live", which
      // is precisely the frozen-prices-look-live failure this app must not
      // have.
      if (_consecutiveDuplicates >= _resetAfterConsecutiveDuplicates) {
        return _resequence(id);
      }
      return _reject(RejectReason.duplicate);
    }
    _consecutiveDuplicates = 0;
    // Advance on *receipt*, not on acceptance: an event we drop as stale was
    // still delivered, and resuming from before it would re-deliver it.
    _maxSeenId = id;

    final tick = Tick.tryParse(id, event.data);
    if (tick == null) return _reject(RejectReason.malformed);

    final lastTs = _lastTsBySymbol[tick.symbol];
    // Equal timestamps are accepted: two ticks can legitimately share a
    // millisecond, and the later id is the more recent price.
    if (lastTs != null && tick.ts < lastTs) {
      return _reject(RejectReason.stale);
    }
    _lastTsBySymbol[tick.symbol] = tick.ts;

    _accepted++;
    return TickAccepted(tick);
  }

  FeedUpdate _processGap(SseEvent event) {
    _gaps++;
    final resumeFrom = _resumeFromOf(event.data);

    // A gap whose resume point sits *behind* our cursor means the id sequence
    // restarted. Catching it here is the cheap path; [_resequence] is the
    // backstop for when the server restarts without announcing anything.
    if (resumeFrom != null && _maxSeenId != null && resumeFrom < _maxSeenId!) {
      _rebaseline(resumeFrom > 0 ? resumeFrom - 1 : null);
    }
    return FeedGapDetected(resumeFrom);
  }

  /// Adopts a restarted id sequence, accepting [id] and everything after it.
  ///
  /// Reported as a gap because that is what it is: the stream we were reading
  /// ended and a different one began, and whatever was in flight is gone.
  FeedUpdate _resequence(int id) {
    _gaps++;
    _rebaseline(id - 1);
    return FeedGapDetected(id);
  }

  void _rebaseline(int? maxSeenId) {
    _maxSeenId = maxSeenId;
    _consecutiveDuplicates = 0;
    // A restarted server may also be behind on wall-clock time. Holding on to
    // the old per-symbol timestamps would then reject every new tick as stale
    // — swapping one silent freeze for another.
    _lastTsBySymbol.clear();
  }

  int? _resumeFromOf(String data) {
    try {
      final Object? json = jsonDecode(data);
      if (json is Map) {
        final value = json['resumeFrom'];
        if (value is num) return value.toInt();
      }
    } on FormatException {
      // A gap we cannot read is still a gap.
    }
    return null;
  }

  FeedUpdate _reject(RejectReason reason) {
    switch (reason) {
      case RejectReason.duplicate:
        _duplicates++;
      case RejectReason.stale:
        _stale++;
      case RejectReason.malformed:
        _malformed++;
    }
    return TickRejected(reason);
  }
}
