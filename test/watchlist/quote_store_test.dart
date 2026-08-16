import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse/features/watchlist/application/quote_store.dart';
import 'package:pulse/features/watchlist/domain/models/quote.dart';
import 'package:pulse/features/watchlist/domain/models/tick.dart';

Tick tick({
  int id = 1,
  String symbol = 'EURUSD',
  required double bid,
  double? ask,
  int ts = 1000,
}) => Tick(id: id, symbol: symbol, bid: bid, ask: ask ?? bid + 0.0002, ts: ts);

void main() {
  late QuoteStore store;

  setUp(() => store = QuoteStore());

  /// Counts how many times a symbol's listenable fires — the number that
  /// decides whether the list survives a burst.
  int Function() countNotifications(String symbol) {
    var count = 0;
    store.listenTo(symbol).addListener(() => count++);
    return () => count;
  }

  group('conflation', () {
    test('publishes nothing until the window closes', () {
      fakeAsync((async) {
        final notifications = countNotifications('EURUSD');

        store.add(tick(bid: 1.08));
        async.flushMicrotasks();

        expect(notifications(), 0);
        expect(store.listenTo('EURUSD').value, isNull);

        async.elapse(const Duration(milliseconds: 100));

        expect(notifications(), 1);
        expect(store.listenTo('EURUSD').value!.bid, 1.08);
      });
    });

    // The graded scenario: ~220 ticks in ~100ms across the five hot symbols.
    test('collapses a 220-tick burst into one notification per symbol', () {
      fakeAsync((async) {
        const symbols = ['EURUSD', 'GBPUSD', 'XAUUSD', 'US500', 'BTCUSD'];
        final counters = {
          for (final symbol in symbols) symbol: countNotifications(symbol),
        };

        for (var i = 0; i < 220; i++) {
          store.add(
            tick(
              id: i,
              symbol: symbols[i % symbols.length],
              bid: 1 + i * 0.001,
              ts: 1000 + i,
            ),
          );
        }
        async.elapse(const Duration(milliseconds: 100));

        for (final symbol in symbols) {
          expect(counters[symbol]!(), 1, reason: '$symbol should fire once');
        }
      });
    });

    test('keeps only the newest price in a window', () {
      fakeAsync((async) {
        store
          ..add(tick(id: 1, bid: 1.01, ts: 1))
          ..add(tick(id: 2, bid: 1.02, ts: 2))
          ..add(tick(id: 3, bid: 1.03, ts: 3));
        async.elapse(const Duration(milliseconds: 100));

        expect(store.listenTo('EURUSD').value!.bid, 1.03);
      });
    });

    test('publishes once per window across several windows', () {
      fakeAsync((async) {
        final notifications = countNotifications('EURUSD');

        for (var window = 0; window < 3; window++) {
          store
            ..add(tick(bid: 1.0 + window, ts: window * 10))
            ..add(tick(bid: 1.5 + window, ts: window * 10 + 1));
          async.elapse(const Duration(milliseconds: 100));
        }

        expect(notifications(), 3);
      });
    });

    // A quiet feed should cost nothing: no periodic timer ticking away.
    test('schedules no timers while idle', () {
      fakeAsync((async) {
        store.prime(['EURUSD']);
        async.elapse(const Duration(minutes: 1));

        expect(async.pendingTimers, isEmpty);
      });
    });

    test('does not notify when the price is unchanged', () {
      fakeAsync((async) {
        store.add(tick(id: 1, bid: 1.08, ts: 1));
        async.elapse(const Duration(milliseconds: 100));
        final notifications = countNotifications('EURUSD');

        store.add(tick(id: 2, bid: 1.08, ts: 1));
        async.elapse(const Duration(milliseconds: 100));

        expect(notifications(), 0);
      });
    });
  });

  group('flash direction', () {
    test('is flat for the very first price', () {
      fakeAsync((async) {
        store.add(tick(bid: 1.08));
        async.elapse(const Duration(milliseconds: 100));

        expect(store.listenTo('EURUSD').value!.direction, PriceDirection.flat);
      });
    });

    test('reports up and down against the displayed price', () {
      fakeAsync((async) {
        store.add(tick(id: 1, bid: 1.08, ts: 1));
        async.elapse(const Duration(milliseconds: 100));

        store.add(tick(id: 2, bid: 1.09, ts: 2));
        async.elapse(const Duration(milliseconds: 100));
        expect(store.listenTo('EURUSD').value!.direction, PriceDirection.up);

        store.add(tick(id: 3, bid: 1.07, ts: 3));
        async.elapse(const Duration(milliseconds: 100));
        expect(store.listenTo('EURUSD').value!.direction, PriceDirection.down);
      });
    });

    // Prices conflated away were never on screen, so the flash must describe
    // the move the user can actually see.
    test('measures the net move across a window, not the last hop', () {
      fakeAsync((async) {
        store.add(tick(id: 1, bid: 1.08, ts: 1));
        async.elapse(const Duration(milliseconds: 100));

        store
          ..add(tick(id: 2, bid: 1.20, ts: 2)) // spike, never displayed
          ..add(tick(id: 3, bid: 1.05, ts: 3)); // settles below the shown price
        async.elapse(const Duration(milliseconds: 100));

        expect(store.listenTo('EURUSD').value!.direction, PriceDirection.down);
      });
    });
  });

  group('routing', () {
    test('keeps symbols independent', () {
      fakeAsync((async) {
        final eur = countNotifications('EURUSD');
        final gbp = countNotifications('GBPUSD');

        store.add(tick(symbol: 'EURUSD', bid: 1.08));
        async.elapse(const Duration(milliseconds: 100));

        expect(eur(), 1);
        expect(gbp(), 0);
      });
    });

    test('primes symbols with a null quote', () {
      store.prime(['EURUSD', 'GBPUSD']);

      expect(store.listenTo('EURUSD').value, isNull);
      expect(store.listenTo('GBPUSD').value, isNull);
    });

    test('returns the same listenable for a symbol every time', () {
      store.prime(['EURUSD']);

      expect(
        identical(store.listenTo('EURUSD'), store.listenTo('EURUSD')),
        isTrue,
      );
    });

    test('clear drops every price', () {
      fakeAsync((async) {
        store.add(tick(bid: 1.08));
        async.elapse(const Duration(milliseconds: 100));

        store.clear();

        expect(store.listenTo('EURUSD').value, isNull);
      });
    });
  });
}
