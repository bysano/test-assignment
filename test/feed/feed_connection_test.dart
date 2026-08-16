import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse/data/api/api_exception.dart';
import 'package:pulse/data/models/tick.dart';
import 'package:pulse/data/sse/sse_frame.dart';
import 'package:pulse/feed/feed_config.dart';
import 'package:pulse/feed/feed_connection.dart';
import 'package:pulse/feed/feed_status.dart';
import 'package:pulse/feed/feed_update.dart';

import 'feed_test_doubles.dart';

/// Everything the connection touches, wired to doubles.
final class Harness {
  Harness({FeedConfig? config, FakeNetworkGate? network})
    : network = network ?? FakeNetworkGate() {
    feed = FeedConnection(
      transport: transport,
      tokens: tokens,
      network: this.network,
      config: config ?? const FeedConfig(),
      random: NoJitterRandom(),
    );
    feed.statuses.listen(statuses.add);
    feed.ticks.listen(ticks.add);
    feed.gaps.listen(gaps.add);
  }

  final FakeSseTransport transport = FakeSseTransport();
  final FakeTokenProvider tokens = FakeTokenProvider();
  final FakeNetworkGate network;
  late final FeedConnection feed;

  final List<FeedStatus> statuses = [];
  final List<Tick> ticks = [];
  final List<FeedGapDetected> gaps = [];

  /// Brings the feed up and delivers one tick, leaving it [FeedLive].
  void goLive(FakeAsync async, {int id = 1, int ts = 1000}) {
    feed.start();
    async.flushMicrotasks();
    transport.current!.emitTick(id: id, ts: ts);
    async.flushMicrotasks();
  }

  /// Advances the clock by exactly the delay the feed said it would wait, so
  /// the next attempt fires and nothing else does.
  void waitOutBackoff(FakeAsync async) {
    final pending = statuses.last;
    if (pending is! FeedReconnecting) {
      throw StateError('expected a pending reconnect, got $pending');
    }
    async
      ..elapse(pending.delay)
      ..flushMicrotasks();
  }

  List<int> get backoffDelaysMs => statuses
      .whereType<FeedReconnecting>()
      .map((s) => s.delay.inMilliseconds)
      .toList();
}

// The defaults, restated so the expected delays below are readable:
// base 500ms doubling to a 15s cap, warn at 6s of silence, kill at 8s.
// With jitter removed a delay is exactly half the capped exponential.
const _base = Duration(milliseconds: 500);

void main() {
  group('happy path', () {
    test('connects and reports live on the first frame', () {
      fakeAsync((async) {
        final h = Harness()..feed.start();
        async.flushMicrotasks();

        expect(h.statuses, [const FeedConnecting(0)]);
        expect(h.transport.calls, hasLength(1));
        expect(h.transport.calls.single.token, 'token-0');
        expect(h.transport.calls.single.lastEventId, isNull);

        h.transport.current!.emitTick(id: 1, ts: 1000);
        async.flushMicrotasks();

        expect(h.statuses.last, const FeedLive());
        expect(h.ticks.single.symbol, 'EURUSD');
      });
    });

    test('a heartbeat alone is enough to report live', () {
      fakeAsync((async) {
        final h = Harness()..feed.start();
        async.flushMicrotasks();

        h.transport.current!.emitHeartbeat();
        async.flushMicrotasks();

        expect(h.statuses.last, const FeedLive());
      });
    });

    test('drops duplicates and stale ticks before they reach the UI', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async, id: 1, ts: 5000);

        h.transport.current!
          ..emitTick(id: 1, ts: 5000) // duplicate id
          ..emitTick(id: 2, ts: 2000) // stale timestamp, fresh id
          ..emitTick(id: 3, ts: 6000); // genuinely new
        async.flushMicrotasks();

        expect(h.ticks.map((t) => t.ts), [5000, 6000]);
        expect(h.feed.stats.duplicates, 1);
        expect(h.feed.stats.stale, 1);
      });
    });
  });

  group('disconnects and backoff', () {
    test('reconnects after the server closes the stream', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async);

        h.transport.current!.endStream();
        async.flushMicrotasks();

        expect(h.statuses.last, isA<FeedReconnecting>());
        expect(h.transport.calls, hasLength(1)); // not yet

        async.elapse(_base ~/ 2); // half the base delay, jitter removed
        expect(h.transport.calls, hasLength(2));
      });
    });

    test('reconnects after a socket error', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async);

        h.transport.current!.failStream(const SocketExceptionStub());
        async.flushMicrotasks();
        async.elapse(_base);

        expect(h.transport.calls, hasLength(2));
      });
    });

    test('resumes from the last event id it actually received', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async, id: 42, ts: 1000);

        h.transport.current!.endStream();
        async.flushMicrotasks();
        async.elapse(_base);

        expect(h.transport.calls.last.lastEventId, 42);
      });
    });

    test('doubles the delay on each consecutive failure', () {
      fakeAsync((async) {
        final h = Harness();
        h.transport.failures.addAll(
          List.generate(6, (_) => const SocketExceptionStub()),
        );
        h.feed.start();
        async.flushMicrotasks();

        // Advance by exactly the pending delay each time, so the schedule is
        // measured rather than inferred from a bulk elapse.
        for (var i = 0; i < 5; i++) {
          h.waitOutBackoff(async);
        }

        expect(h.backoffDelaysMs, [250, 500, 1000, 2000, 4000, 7500]);
      });
    });

    test('caps the delay so a user is never stranded', () {
      fakeAsync((async) {
        final h = Harness();
        h.transport.failures.addAll(
          List.generate(12, (_) => const SocketExceptionStub()),
        );
        h.feed.start();
        async.flushMicrotasks();
        for (var i = 0; i < 11; i++) {
          h.waitOutBackoff(async);
        }

        // 500ms doubling would reach 256s by the twelfth attempt; the cap holds
        // it at half of 15s once jitter is removed.
        expect(h.backoffDelaysMs.last, 7500);
        expect(h.backoffDelaysMs.every((ms) => ms <= 15000), isTrue);
      });
    });

    test('resets the backoff once a connection proves itself', () {
      fakeAsync((async) {
        final h = Harness();
        h.transport.failures.addAll([
          const SocketExceptionStub(),
          const SocketExceptionStub(),
        ]);
        h.feed.start();
        async.flushMicrotasks();
        h.waitOutBackoff(async); // second attempt, also fails
        h.waitOutBackoff(async); // third attempt succeeds

        h.transport.current!.emitTick(id: 1, ts: 1000);
        async.flushMicrotasks();
        expect(h.statuses.last, const FeedLive());

        h.transport.current!.endStream();
        async.flushMicrotasks();

        final last = h.statuses.last as FeedReconnecting;
        expect(last.attempt, 1);
        expect(last.delay, _base ~/ 2); // back to the start of the curve
      });
    });
  });

  group('silent stalls', () {
    test('reports stalled after the silence threshold', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async);

        async.elapse(const Duration(seconds: 6));

        expect(h.statuses.last, const FeedStalled());
      });
    });

    test('heartbeats hold off the watchdog indefinitely', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async);

        // A quiet market: no ticks for half a minute, heartbeats every 5s.
        for (var i = 0; i < 6; i++) {
          async.elapse(const Duration(seconds: 5));
          h.transport.current!.emitHeartbeat();
          async.flushMicrotasks();
        }

        expect(h.statuses.last, const FeedLive());
        expect(h.statuses.whereType<FeedStalled>(), isEmpty);
      });
    });

    test('kills the silent socket and reconnects with the resume cursor', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async, id: 99, ts: 1000);
        final stalled = h.transport.current!;

        async.elapse(const Duration(seconds: 8)); // warn at 6s, kill at 8s

        expect(stalled.cancelled, isTrue);
        expect(h.statuses.map((s) => s.runtimeType), contains(FeedStalled));

        async.elapse(const Duration(seconds: 1));
        expect(h.transport.calls, hasLength(2));
        expect(h.transport.calls.last.lastEventId, 99);
      });
    });

    test('recovers to live when data resumes before the kill', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async);

        async.elapse(const Duration(seconds: 6));
        expect(h.statuses.last, const FeedStalled());

        h.transport.current!.emitTick(id: 2, ts: 2000);
        async.flushMicrotasks();

        expect(h.statuses.last, const FeedLive());
        expect(h.transport.calls, hasLength(1)); // never reconnected
      });
    });
  });

  group('token expiry', () {
    test('refreshes and retries immediately, with no user involvement', () {
      fakeAsync((async) {
        final h = Harness();
        h.transport.failures.add(const UnauthorizedException());
        h.feed.start();
        async.flushMicrotasks();

        expect(h.tokens.refreshCount, 1);
        expect(h.transport.calls, hasLength(2));
        expect(h.transport.calls.last.token, 'token-1');
        // Straight through — no backoff state was ever shown.
        expect(h.statuses.whereType<FeedReconnecting>(), isEmpty);
      });
    });

    test('handles a 401 that arrives mid-session', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async, id: 7, ts: 1000);

        // The server drops us when the token behind the stream expires.
        h.transport.current!.endStream();
        h.transport.failures.add(const UnauthorizedException());
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));

        expect(h.tokens.refreshCount, 1);
        expect(h.transport.calls.last.token, 'token-1');
        expect(h.transport.calls.last.lastEventId, 7);
      });
    });

    test('falls back to backoff rather than ping-ponging on repeat 401s', () {
      fakeAsync((async) {
        final h = Harness();
        h.transport.failures.addAll([
          const UnauthorizedException(),
          const UnauthorizedException(),
        ]);
        h.feed.start();
        async.flushMicrotasks();

        expect(h.tokens.refreshCount, 1); // only one free retry
        expect(h.statuses.last, isA<FeedReconnecting>());
      });
    });

    test('stops and reports fatally when the credentials are rejected', () {
      fakeAsync((async) {
        final h = Harness();
        h.tokens.refreshError = const InvalidCredentialsException();
        h.transport.failures.add(const UnauthorizedException());
        h.feed.start();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 1));

        expect(h.statuses.last, isA<FeedFatal>());
        expect(h.transport.calls, hasLength(1)); // gave up rather than spin
      });
    });
  });

  group('device offline', () {
    test('does not attempt to connect while known offline', () {
      fakeAsync((async) {
        final h = Harness(network: FakeNetworkGate(online: false))
          ..feed.start();
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 2));

        expect(h.transport.calls, isEmpty);
        expect(h.statuses.last, const FeedOffline());
      });
    });

    test('abandons a pending retry when the device drops off the network', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async);
        h.transport.current!.endStream();
        async.flushMicrotasks();
        expect(h.statuses.last, isA<FeedReconnecting>());

        h.network.setOnline(false);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 2));

        expect(h.statuses.last, const FeedOffline());
        expect(h.transport.calls, hasLength(1)); // no attempts while offline
      });
    });

    test('tears down a live connection the moment the network drops', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async);
        final live = h.transport.current!;

        h.network.setOnline(false);
        async.flushMicrotasks();

        expect(live.cancelled, isTrue);
        expect(h.statuses.last, const FeedOffline());
      });
    });

    test('reconnects immediately when the network returns', () {
      fakeAsync((async) {
        final h = Harness(network: FakeNetworkGate(online: false))
          ..feed.start();
        async.flushMicrotasks();

        h.network.setOnline(true);
        async.flushMicrotasks();

        // No backoff wait: past failures say nothing about a new network.
        expect(h.transport.calls, hasLength(1));
        expect(h.statuses.last, isA<FeedConnecting>());
      });
    });
  });

  group('malformed data and gaps', () {
    test('survives garbage without dropping the stream', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async, id: 1, ts: 1000);

        h.transport.current!
          ..emit(
            const SseEvent(id: null, event: 'message', data: '###garbage###'),
          )
          ..emitTick(id: 2, ts: 2000);
        async.flushMicrotasks();

        expect(h.statuses.last, const FeedLive());
        expect(h.ticks, hasLength(2));
        expect(h.feed.stats.malformed, 1);
      });
    });

    test('reports a gap and keeps going', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async, id: 1, ts: 1000);

        h.transport.current!
          ..emit(
            const SseEvent(id: null, event: 'gap', data: '{"resumeFrom":900}'),
          )
          ..emitTick(id: 901, ts: 2000);
        async.flushMicrotasks();

        expect(h.gaps.single.resumeFrom, 900);
        expect(h.statuses.last, const FeedLive());
        expect(h.ticks, hasLength(2));
      });
    });
  });

  group('lifecycle', () {
    test('stop cancels the socket and halts reconnection', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async);
        final live = h.transport.current!;

        h.feed.stop();
        async.elapse(const Duration(minutes: 1));

        expect(live.cancelled, isTrue);
        expect(h.statuses.last, const FeedIdle());
        expect(h.transport.calls, hasLength(1));
      });
    });

    // stop() ends a session. A reconnect must keep the cursor and counters —
    // that is what makes replay work — but a fresh session must not inherit
    // them, or its diagnostics describe the previous user's traffic.
    test('stop forgets the resume cursor and the counters', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async, id: 42, ts: 1000);
        h.transport.current!.emitTick(id: 42, ts: 1000); // duplicate
        async.flushMicrotasks();
        expect(h.feed.stats.accepted, 1);
        expect(h.feed.stats.duplicates, 1);

        h.feed.stop();

        expect(h.feed.stats, const FeedStats());
        h.feed.start();
        async.flushMicrotasks();
        expect(h.transport.calls.last.lastEventId, isNull);
      });
    });

    test('a reconnect keeps them, unlike a stop', () {
      fakeAsync((async) {
        final h = Harness();
        h.goLive(async, id: 42, ts: 1000);

        h.transport.current!.endStream();
        async.flushMicrotasks();
        h.waitOutBackoff(async);

        expect(h.feed.stats.accepted, 1);
        expect(h.transport.calls.last.lastEventId, 42);
      });
    });

    test('start is idempotent', () {
      fakeAsync((async) {
        final h = Harness()
          ..feed.start()
          ..feed.start();
        async.flushMicrotasks();

        expect(h.transport.calls, hasLength(1));
      });
    });
  });
}

/// Stands in for a socket failure without depending on dart:io in tests.
final class SocketExceptionStub implements Exception {
  const SocketExceptionStub();
}
