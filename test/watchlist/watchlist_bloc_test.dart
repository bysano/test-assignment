import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse/features/auth/data/auth_api.dart';
import 'package:pulse/features/auth/data/auth_repository.dart';
import 'package:pulse/features/auth/data/authenticated_client.dart';
import 'package:pulse/features/watchlist/application/feed/feed_connection.dart';
import 'package:pulse/features/watchlist/application/feed/feed_status.dart';
import 'package:pulse/features/watchlist/application/quote_store.dart';
import 'package:pulse/features/watchlist/data/instruments_api.dart';
import 'package:pulse/features/watchlist/data/sse/sse_frame.dart';
import 'package:pulse/features/watchlist/presentation/bloc/watchlist_bloc.dart';
import 'package:pulse_native/pulse_native.dart';

import '../feed/feed_test_doubles.dart';

const _instrumentsJson = '''
[{"symbol":"EURUSD","name":"Euro / US Dollar","decimals":5},
 {"symbol":"GBPUSD","name":"British Pound / US Dollar","decimals":5}]''';

void main() {
  late FakeSseTransport transport;
  late QuoteStore quotes;
  late AuthRepository auth;
  late int instrumentCalls;
  late List<http.Response> instrumentResponses;

  /// When set, `/instruments` hangs until it completes — lets a test close the
  /// bloc while the request is still in flight.
  Completer<void>? instrumentsGate;

  final baseUrl = Uri.parse('http://localhost:8080');

  WatchlistBloc buildBloc() {
    // Wired exactly as the DI module does it: the instrument API only ever
    // sees an AuthenticatedClient, so the bearer and the 401 retry are the
    // interceptor's business and never the bloc's.
    final instruments = InstrumentsApi(
      baseUrl: baseUrl,
      client: AuthenticatedClient(
        tokens: auth,
        inner: MockClient((_) async {
          await instrumentsGate?.future;
          final response =
              instrumentResponses[instrumentCalls.clamp(
                0,
                instrumentResponses.length - 1,
              )];
          instrumentCalls++;
          return response;
        }),
      ),
    );
    final feed = FeedConnection(stream: transport, random: NoJitterRandom());
    return WatchlistBloc(instruments, feed, quotes);
  }

  setUp(() async {
    transport = FakeSseTransport();
    quotes = QuoteStore(flushInterval: const Duration(milliseconds: 10));
    instrumentCalls = 0;
    instrumentResponses = [http.Response(_instrumentsJson, 200)];
    instrumentsGate = null;

    auth = AuthRepository(
      api: AuthApi(
        baseUrl: baseUrl,
        client: MockClient(
          (_) async => http.Response('{"token":"tok","expiresIn":60}', 200),
        ),
      ),
      store: InMemorySecureTokenStore(),
    );
    await auth.signIn(username: 'trader', password: 'password123');
  });

  tearDown(() => quotes.dispose());

  group('startup', () {
    blocTest<WatchlistBloc, WatchlistState>(
      'loads instruments and becomes ready',
      build: buildBloc,
      act: (bloc) => bloc.add(const WatchlistStarted()),
      wait: const Duration(milliseconds: 50),
      verify: (bloc) {
        expect(bloc.state.status, WatchlistStatus.ready);
        expect(bloc.state.instruments.map((i) => i.symbol), [
          'EURUSD',
          'GBPUSD',
        ]);
      },
    );

    test('primes the quote store before the list can be built', () async {
      final bloc = buildBloc()..add(const WatchlistStarted());
      await bloc.stream.firstWhere(
        (state) => state.status == WatchlistStatus.ready,
      );

      // Non-null listenables mean rows will never mutate the store mid-build.
      expect(quotes.listenTo('EURUSD').value, isNull);
      expect(quotes.listenTo('GBPUSD').value, isNull);
      await bloc.close();
    });

    test('starts the feed once the instruments are known', () async {
      final bloc = buildBloc()..add(const WatchlistStarted());
      await bloc.stream.firstWhere(
        (state) => state.connection is FeedConnecting,
      );

      expect(transport.calls, hasLength(1));
      await bloc.close();
    });
  });

  group('failures', () {
    test('reports a server that is not running', () async {
      instrumentResponses = [http.Response('nope', 500)];
      final bloc = buildBloc()..add(const WatchlistStarted());

      final state = await bloc.stream.firstWhere(
        (state) => state.status == WatchlistStatus.failure,
      );

      expect(state.error, contains('feed server'));
      await bloc.close();
    });

    test('recovers on retry', () async {
      instrumentResponses = [
        http.Response('nope', 500),
        http.Response(_instrumentsJson, 200),
      ];
      final bloc = buildBloc()..add(const WatchlistStarted());
      await bloc.stream.firstWhere(
        (state) => state.status == WatchlistStatus.failure,
      );

      bloc.add(const WatchlistRetryRequested());

      final state = await bloc.stream.firstWhere(
        (state) => state.status == WatchlistStatus.ready,
      );
      expect(state.instruments, hasLength(2));
      await bloc.close();
    });

    // The token can die between being minted and being used.
    test('refreshes the token and retries after a 401', () async {
      instrumentResponses = [
        http.Response('', 401),
        http.Response(_instrumentsJson, 200),
      ];
      final bloc = buildBloc()..add(const WatchlistStarted());

      final state = await bloc.stream.firstWhere(
        (state) => state.status == WatchlistStatus.ready,
      );

      expect(state.instruments, hasLength(2));
      expect(instrumentCalls, 2);
      await bloc.close();
    });
  });

  group('connection status', () {
    test('mirrors the feed, and marks prices stale unless live', () async {
      final bloc = buildBloc()..add(const WatchlistStarted());
      await bloc.stream.firstWhere((s) => s.connection is FeedConnecting);
      expect(bloc.state.pricesMayBeStale, isTrue);

      transport.current!.emit(const SseComment('ping'));
      await bloc.stream.firstWhere((s) => s.connection is FeedLive);
      expect(bloc.state.pricesMayBeStale, isFalse);

      transport.current!.endStream();
      await bloc.stream.firstWhere((s) => s.connection is FeedReconnecting);
      expect(bloc.state.pricesMayBeStale, isTrue);

      await bloc.close();
    });
  });

  group('the hot path stays out of bloc state', () {
    // The architectural claim this whole design rests on. If ticks ever start
    // emitting states, the burst requirement is quietly lost.
    test('200 ticks produce zero bloc emissions', () async {
      final bloc = buildBloc()..add(const WatchlistStarted());
      await bloc.stream.firstWhere((s) => s.connection is FeedConnecting);

      transport.current!.emitTick(id: 1, ts: 1000);
      await bloc.stream.firstWhere((s) => s.connection is FeedLive);

      final emissions = <WatchlistState>[];
      final subscription = bloc.stream.listen(emissions.add);

      for (var id = 2; id <= 201; id++) {
        transport.current!.emitTick(
          id: id,
          symbol: id.isEven ? 'EURUSD' : 'GBPUSD',
          bid: 1 + id * 0.001,
          ts: 1000 + id,
        );
      }
      await pumpEventQueue();

      expect(emissions, isEmpty);
      // …while the prices themselves did arrive.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(quotes.listenTo('EURUSD').value, isNotNull);
      expect(quotes.listenTo('GBPUSD').value, isNotNull);

      await subscription.cancel();
      await bloc.close();
    });

    test('a gap refreshes the counters without waiting for the poll', () async {
      final bloc = buildBloc()..add(const WatchlistStarted());
      await bloc.stream.firstWhere((s) => s.connection is FeedConnecting);
      transport.current!.emitTick(id: 1, ts: 1000);
      await bloc.stream.firstWhere((s) => s.connection is FeedLive);

      transport.current!.emit(
        const SseEvent(id: null, event: 'gap', data: '{"resumeFrom":900}'),
      );

      final state = await bloc.stream.firstWhere((s) => s.stats.gaps == 1);
      expect(state.stats.accepted, 1);
      await bloc.close();
    });
  });

  // Signing out disposes the bloc, and that can land in the middle of the
  // instrument load. Every add() below happens after an await, so each one is
  // a chance to touch a closed bloc.
  group('closing mid-flight', () {
    test('closing during the instrument load throws nothing', () async {
      instrumentsGate = Completer<void>();
      final bloc = buildBloc()..add(const WatchlistStarted());
      await pumpEventQueue(); // let it reach the in-flight fetch

      await bloc.close();
      instrumentsGate!.complete(); // the response lands after close
      await pumpEventQueue();

      expect(bloc.isClosed, isTrue);
    });

    test('closing during the load leaves the state untouched', () async {
      instrumentsGate = Completer<void>();
      final bloc = buildBloc()..add(const WatchlistStarted());
      await pumpEventQueue();

      await bloc.close();
      instrumentsGate!.complete();
      await pumpEventQueue();

      // Never reached ready, and never reported a bogus failure either.
      expect(bloc.state.status, WatchlistStatus.loading);
      expect(bloc.state.error, isNull);
    });

    // The original crash doubled up: add() threw, the broad catch swallowed
    // that StateError as if it were a network fault, and then called add()
    // again — and nothing was left to catch the second throw.
    test('closing while the load is failing throws nothing', () async {
      instrumentResponses = [http.Response('boom', 500)];
      instrumentsGate = Completer<void>();
      final bloc = buildBloc()..add(const WatchlistStarted());
      await pumpEventQueue();

      await bloc.close();
      instrumentsGate!.complete();
      await pumpEventQueue();

      expect(bloc.state.status, WatchlistStatus.loading);
    });

    // close() is not instantaneous — it awaits several times before isClosed
    // flips. Here the load's continuation lands while close() is still in
    // progress, rather than safely after it.
    test('a load landing mid-close throws nothing', () async {
      instrumentsGate = Completer<void>();
      final bloc = buildBloc()..add(const WatchlistStarted());
      await pumpEventQueue();

      final closing = bloc.close(); // deliberately not awaited yet
      instrumentsGate!.complete();
      await closing;
      await pumpEventQueue();

      expect(bloc.isClosed, isTrue);
      expect(bloc.state.status, WatchlistStatus.loading);
    });

    test('closing during a retry throws nothing', () async {
      instrumentResponses = [http.Response('boom', 500)];
      final bloc = buildBloc()..add(const WatchlistStarted());
      await bloc.stream.firstWhere((s) => s.status == WatchlistStatus.failure);

      instrumentsGate = Completer<void>();
      bloc.add(const WatchlistRetryRequested());
      await pumpEventQueue();

      await bloc.close();
      instrumentsGate!.complete();
      await pumpEventQueue();

      expect(bloc.isClosed, isTrue);
    });
  });

  // The store is a singleton and outlives any one watchlist session, so
  // nothing from a previous sign-in may survive into the next one.
  group('session isolation', () {
    /// Brings a session up and gets one price on screen for EURUSD.
    Future<WatchlistBloc> liveSessionWithPrices() async {
      final bloc = buildBloc()..add(const WatchlistStarted());
      await bloc.stream.firstWhere((s) => s.connection is FeedConnecting);
      transport.current!.emitTick(id: 1, ts: 1000);
      await bloc.stream.firstWhere((s) => s.connection is FeedLive);
      await Future<void>.delayed(const Duration(milliseconds: 20)); // flush
      expect(quotes.listenTo('EURUSD').value, isNotNull);
      return bloc;
    }

    test('signing out drops the prices', () async {
      final bloc = await liveSessionWithPrices();

      await bloc.close();

      expect(quotes.listenTo('EURUSD').value, isNull);
    });

    // The reported bug: after signing back in, the first heartbeat marked the
    // connection live while rows still showed the previous session's prices.
    test(
      'a new session is not live with the previous session\'s prices',
      () async {
        await (await liveSessionWithPrices()).close();

        final next = buildBloc()..add(const WatchlistStarted());
        await next.stream.firstWhere((s) => s.connection is FeedConnecting);
        transport.current!.emit(const SseComment('ping'));
        await next.stream.firstWhere((s) => s.connection is FeedLive);

        // Live, but nothing of its own to show yet — which is correct. A stale
        // price here would be presented to the user as a current one.
        expect(next.state.connection, isA<FeedLive>());
        expect(quotes.listenTo('EURUSD').value, isNull);
        expect(quotes.listenTo('GBPUSD').value, isNull);

        await next.close();
      },
    );

    // Clearing at session start, not just on close, is what makes this hold.
    test(
      'a new session starts clean even if the last was never closed',
      () async {
        final leaked = await liveSessionWithPrices();

        final next = buildBloc()..add(const WatchlistStarted());
        await next.stream.firstWhere((s) => s.status == WatchlistStatus.ready);

        expect(quotes.listenTo('EURUSD').value, isNull);

        await leaked.close();
        await next.close();
      },
    );

    test('a closed session stops feeding the store', () async {
      final bloc = await liveSessionWithPrices();
      final connection = transport.current!;

      await bloc.close();
      connection.emitTick(id: 99, ts: 9999);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(quotes.listenTo('EURUSD').value, isNull);
    });
  });

  test('closing the bloc tears the feed down', () async {
    final bloc = buildBloc()..add(const WatchlistStarted());
    await bloc.stream.firstWhere((s) => s.connection is FeedConnecting);
    final connection = transport.current!;

    await bloc.close();

    expect(connection.cancelled, isTrue);
  });
}
