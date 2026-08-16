import 'package:flutter_test/flutter_test.dart';
import 'package:pulse/data/sse/sse_frame.dart';
import 'package:pulse/feed/feed_update.dart';
import 'package:pulse/feed/tick_pipeline.dart';

SseEvent tickEvent({
  required int id,
  String symbol = 'EURUSD',
  double bid = 1.08123,
  double ask = 1.08141,
  required int ts,
}) => SseEvent(
  id: id,
  event: 'tick',
  data: '{"s":"$symbol","b":$bid,"a":$ask,"ts":$ts}',
);

void main() {
  late TickPipeline pipeline;

  setUp(() => pipeline = TickPipeline());

  group('accepting ticks', () {
    test('accepts a well-formed tick and tracks the resume cursor', () {
      final result = pipeline.process(tickEvent(id: 10, ts: 1000));

      expect(result, isA<TickAccepted>());
      expect((result as TickAccepted).tick.symbol, 'EURUSD');
      expect(pipeline.lastEventId, 10);
    });

    test('accepts a tick sharing a millisecond with the previous one', () {
      pipeline.process(tickEvent(id: 1, ts: 1000));

      // Same ts, newer id — the later event is the more recent price.
      expect(pipeline.process(tickEvent(id: 2, ts: 1000)), isA<TickAccepted>());
    });
  });

  group('duplicates', () {
    test('rejects an event replayed with an id already seen', () {
      final original = tickEvent(id: 10, ts: 1000);
      pipeline.process(original);

      final replay = pipeline.process(original);

      expect(replay, isA<TickRejected>());
      expect((replay as TickRejected).reason, RejectReason.duplicate);
    });

    // A second flash for a price that never moved is the visible artifact the
    // assignment calls out, so dedup must precede everything else.
    test('rejects a duplicate before parsing or the staleness check', () {
      pipeline.process(tickEvent(id: 10, ts: 5000));

      final replay = pipeline.process(tickEvent(id: 10, ts: 1));

      expect((replay as TickRejected).reason, RejectReason.duplicate);
      expect(pipeline.stats.stale, 0);
    });

    test('rejects any id at or below the cursor', () {
      pipeline.process(tickEvent(id: 10, ts: 1000));

      expect(pipeline.process(tickEvent(id: 9, ts: 1001)), isA<TickRejected>());
      expect(
        pipeline.process(tickEvent(id: 10, ts: 1001)),
        isA<TickRejected>(),
      );
      expect(
        pipeline.process(tickEvent(id: 11, ts: 1001)),
        isA<TickAccepted>(),
      );
    });

    test('leaves the resume cursor untouched', () {
      pipeline.process(tickEvent(id: 10, ts: 1000));
      pipeline.process(tickEvent(id: 5, ts: 1000));

      expect(pipeline.lastEventId, 10);
    });
  });

  group('out-of-order timestamps', () {
    // The feed emits these with a *fresh* id, so dedup cannot catch them.
    test('rejects a tick older than the last one shown for that symbol', () {
      pipeline.process(tickEvent(id: 1, ts: 5000));

      final stale = pipeline.process(tickEvent(id: 2, ts: 2000));

      expect((stale as TickRejected).reason, RejectReason.stale);
    });

    test('keeps the newer price after a stale tick arrives', () {
      pipeline.process(tickEvent(id: 1, ts: 5000));
      pipeline.process(tickEvent(id: 2, ts: 2000));

      // 4999 is still older than the 5000 we displayed, so it stays rejected.
      expect(pipeline.process(tickEvent(id: 3, ts: 4999)), isA<TickRejected>());
      expect(pipeline.process(tickEvent(id: 4, ts: 5001)), isA<TickAccepted>());
    });

    test('tracks timestamps per symbol, not globally', () {
      pipeline.process(tickEvent(id: 1, symbol: 'EURUSD', ts: 5000));

      // Older than EURUSD's timestamp, but this symbol has never ticked.
      final other = pipeline.process(
        tickEvent(id: 2, symbol: 'GBPUSD', ts: 2000),
      );

      expect(other, isA<TickAccepted>());
    });

    // If the cursor did not advance past a stale tick, reconnecting would ask
    // the server to replay it.
    test('advances the resume cursor past a stale tick', () {
      pipeline.process(tickEvent(id: 1, ts: 5000));
      pipeline.process(tickEvent(id: 2, ts: 2000));

      expect(pipeline.lastEventId, 2);
    });
  });

  group('malformed events', () {
    test('rejects the garbage payload the feed injects', () {
      final result = pipeline.process(
        const SseEvent(
          id: null,
          event: 'message',
          data: '###garbage-not-json###',
        ),
      );

      expect((result as TickRejected).reason, RejectReason.malformed);
    });

    test('rejects a tick whose payload will not decode', () {
      final result = pipeline.process(
        const SseEvent(id: 3, event: 'tick', data: '{"s":"EURUSD","b":'),
      );

      expect((result as TickRejected).reason, RejectReason.malformed);
    });

    test('rejects an unknown event type', () {
      final result = pipeline.process(
        const SseEvent(id: 4, event: 'something-new', data: '{}'),
      );

      expect((result as TickRejected).reason, RejectReason.malformed);
    });

    test('rejects a tick with no id, since it cannot be deduped', () {
      final result = pipeline.process(
        const SseEvent(
          id: null,
          event: 'tick',
          data: '{"s":"EURUSD","b":1.0,"a":1.1,"ts":1}',
        ),
      );

      expect((result as TickRejected).reason, RejectReason.malformed);
    });

    test('keeps processing after malformed input', () {
      pipeline.process(
        const SseEvent(id: null, event: 'message', data: 'junk'),
      );

      expect(pipeline.process(tickEvent(id: 1, ts: 1000)), isA<TickAccepted>());
    });
  });

  group('gaps', () {
    test('reports the resume point', () {
      final result = pipeline.process(
        const SseEvent(id: null, event: 'gap', data: '{"resumeFrom":500}'),
      );

      expect(result, isA<FeedGapDetected>());
      expect((result as FeedGapDetected).resumeFrom, 500);
    });

    test('reports a gap even when the payload is unreadable', () {
      final result = pipeline.process(
        const SseEvent(id: null, event: 'gap', data: 'not json'),
      );

      expect(result, isA<FeedGapDetected>());
      expect((result as FeedGapDetected).resumeFrom, isNull);
    });

    // A restarted server counts from 1 again. Without re-baselining, every
    // event after the bounce looks like a duplicate and the app freezes while
    // still claiming to be live.
    test('re-baselines the cursor when the id sequence restarts', () {
      pipeline.process(tickEvent(id: 5000, ts: 1000));

      pipeline.process(
        const SseEvent(id: null, event: 'gap', data: '{"resumeFrom":1}'),
      );

      expect(pipeline.process(tickEvent(id: 1, ts: 1001)), isA<TickAccepted>());
      expect(pipeline.process(tickEvent(id: 2, ts: 1002)), isA<TickAccepted>());
    });

    // The server does not always announce a restart: with a fresh non-empty
    // buffer it takes the replay branch, finds nothing above our cursor, and
    // sends nothing. Observed against the real server — the app went on
    // reporting "live" while every event was discarded and prices froze.
    test('resequences after a run of duplicates with no gap event', () {
      pipeline.process(tickEvent(id: 7374, ts: 5000));

      // A restarted server counting up from 1 again.
      final results = [
        for (var id = 1; id <= 25; id++)
          pipeline.process(tickEvent(id: id, ts: 6000 + id)),
      ];

      expect(results.take(19), everyElement(isA<TickRejected>()));
      expect(results[19], isA<FeedGapDetected>());
      expect(results.skip(20), everyElement(isA<TickAccepted>()));
      expect(pipeline.lastEventId, 25);
      expect(pipeline.stats.gaps, 1);
    });

    // Otherwise one silent freeze is swapped for another.
    test('resequencing forgets stale per-symbol timestamps', () {
      pipeline.process(tickEvent(id: 7374, ts: 9999999));

      for (var id = 1; id <= 20; id++) {
        pipeline.process(tickEvent(id: id, ts: 100 + id));
      }

      // Timestamps far behind the pre-restart ones must still be accepted.
      expect(pipeline.process(tickEvent(id: 21, ts: 121)), isA<TickAccepted>());
    });

    test('an isolated duplicate never trips the resequence backstop', () {
      for (var id = 1; id <= 60; id++) {
        pipeline.process(tickEvent(id: id, ts: 1000 + id));
        pipeline.process(tickEvent(id: id, ts: 1000 + id)); // replayed
      }

      expect(pipeline.stats.gaps, 0);
      expect(pipeline.stats.duplicates, 60);
      expect(pipeline.stats.accepted, 60);
    });

    test('does not re-baseline when the resume point is ahead of us', () {
      pipeline.process(tickEvent(id: 100, ts: 1000));

      pipeline.process(
        const SseEvent(id: null, event: 'gap', data: '{"resumeFrom":900}'),
      );

      expect(pipeline.lastEventId, 100);
      expect(
        pipeline.process(tickEvent(id: 50, ts: 1001)),
        isA<TickRejected>(),
      );
    });
  });

  test('tallies every outcome', () {
    pipeline.process(tickEvent(id: 1, ts: 1000));
    pipeline.process(tickEvent(id: 2, ts: 1001));
    pipeline.process(tickEvent(id: 2, ts: 1002)); // duplicate
    pipeline.process(tickEvent(id: 3, ts: 500)); // stale
    pipeline.process(const SseEvent(id: null, event: 'message', data: 'junk'));
    pipeline.process(
      const SseEvent(id: null, event: 'gap', data: '{"resumeFrom":9}'),
    );

    expect(
      pipeline.stats,
      const FeedStats(
        accepted: 2,
        duplicates: 1,
        stale: 1,
        malformed: 1,
        gaps: 1,
      ),
    );
  });
}
