import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse/auth/auth_repository.dart';
import 'package:pulse/data/api/auth_api.dart';
import 'package:pulse/data/api/instruments_api.dart';
import 'package:pulse/data/sse/sse_frame.dart';
import 'package:pulse/feed/feed_connection.dart';
import 'package:pulse/feed/feed_status.dart';
import 'package:pulse/watchlist/bloc/watchlist_bloc.dart';
import 'package:pulse/watchlist/quote_store.dart';
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

  final baseUrl = Uri.parse('http://localhost:8080');

  WatchlistBloc buildBloc() {
    final instruments = InstrumentsApi(
      baseUrl: baseUrl,
      client: MockClient((_) async {
        final response =
            instrumentResponses[instrumentCalls.clamp(
              0,
              instrumentResponses.length - 1,
            )];
        instrumentCalls++;
        return response;
      }),
    );
    final feed = FeedConnection(
      transport: transport,
      tokens: auth,
      random: NoJitterRandom(),
    );
    return WatchlistBloc(instruments, auth, feed, quotes);
  }

  setUp(() async {
    transport = FakeSseTransport();
    quotes = QuoteStore(flushInterval: const Duration(milliseconds: 10));
    instrumentCalls = 0;
    instrumentResponses = [http.Response(_instrumentsJson, 200)];

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
