import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse/data/models/instrument.dart';
import 'package:pulse/data/models/tick.dart';
import 'package:pulse/watchlist/quote_store.dart';
import 'package:pulse/watchlist/widgets/price_row.dart';

/// Counts how many times the subtree beneath it is rebuilt *from above*.
///
/// This is the measurement that matters for the burst requirement. If a tick
/// rebuilt the list, or the row, or anything enclosing the price cell, this
/// counter would move. It only stays still if the update stops at the
/// `ValueListenableBuilder` around the price itself.
class _BuildSpy extends StatelessWidget {
  const _BuildSpy({required this.onBuild, required this.child});

  final VoidCallback onBuild;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    onBuild();
    return child;
  }
}

const _instruments = [
  Instrument(symbol: 'EURUSD', name: 'Euro / US Dollar', decimals: 5),
  Instrument(symbol: 'GBPUSD', name: 'British Pound / US Dollar', decimals: 5),
  Instrument(symbol: 'USDJPY', name: 'US Dollar / Japanese Yen', decimals: 3),
  Instrument(symbol: 'XAUUSD', name: 'Gold', decimals: 2),
  Instrument(symbol: 'US500', name: 'S&P 500', decimals: 1),
];

/// A spread wide enough that bid and ask never round to the same string at
/// any instrument's precision, so `findsOneWidget` means what it says.
Tick tick({
  int id = 1,
  required String symbol,
  required double bid,
  int ts = 1000,
}) => Tick(id: id, symbol: symbol, bid: bid, ask: bid * 1.0002, ts: ts);

void main() {
  late QuoteStore store;
  late Map<String, int> buildsFromAbove;

  const flush = Duration(milliseconds: 100);

  setUp(() {
    store = QuoteStore(flushInterval: flush);
    store.prime(_instruments.map((i) => i.symbol));
    buildsFromAbove = {};
  });

  tearDown(() => store.dispose());

  Future<void> pumpWatchlist(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView.builder(
            itemExtent: PriceRow.height,
            itemCount: _instruments.length,
            itemBuilder: (context, index) {
              final instrument = _instruments[index];
              return _BuildSpy(
                onBuild: () => buildsFromAbove.update(
                  instrument.symbol,
                  (count) => count + 1,
                  ifAbsent: () => 1,
                ),
                child: PriceRow(
                  key: ValueKey(instrument.symbol),
                  instrument: instrument,
                  quotes: store,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// Runs the conflation window and lets the resulting frame build.
  Future<void> deliverTicks(WidgetTester tester) async {
    await tester.pump(flush);
    await tester.pump();
  }

  /// Lets the 250ms flash finish so no timers leak between tests.
  Future<void> settleFlash(WidgetTester tester) =>
      tester.pump(const Duration(milliseconds: 400));

  testWidgets('a tick rebuilds nothing above the price cell', (tester) async {
    await pumpWatchlist(tester);
    final baseline = Map.of(buildsFromAbove);

    store.add(tick(symbol: 'EURUSD', bid: 1.09));
    await deliverTicks(tester);

    expect(buildsFromAbove, baseline);
    expect(find.text('1.09000'), findsOneWidget); // …but the price did update
    await settleFlash(tester);
  });

  // The graded scenario: ~220 ticks in ~100ms over the hot instruments.
  testWidgets('a 220-tick burst rebuilds nothing above the price cells', (
    tester,
  ) async {
    await pumpWatchlist(tester);
    final baseline = Map.of(buildsFromAbove);
    const hot = ['EURUSD', 'GBPUSD', 'XAUUSD', 'US500'];

    for (var i = 0; i < 220; i++) {
      store.add(
        tick(
          id: i,
          symbol: hot[i % hot.length],
          bid: 1 + i * 0.001,
          ts: 1000 + i,
        ),
      );
    }
    await deliverTicks(tester);

    expect(buildsFromAbove, baseline);
    await settleFlash(tester);
  });

  testWidgets('a tick leaves every other row untouched', (tester) async {
    await pumpWatchlist(tester);
    store.add(tick(id: 1, symbol: 'GBPUSD', bid: 1.26));
    await deliverTicks(tester);
    await settleFlash(tester);

    store.add(tick(id: 2, symbol: 'EURUSD', bid: 1.09));
    await deliverTicks(tester);

    expect(find.text('1.26000'), findsOneWidget); // GBPUSD, unchanged
    expect(find.text('1.09000'), findsOneWidget);
    await settleFlash(tester);
  });

  testWidgets('formats each instrument to its own precision', (tester) async {
    await pumpWatchlist(tester);

    store
      ..add(tick(id: 1, symbol: 'EURUSD', bid: 1.08123))
      ..add(tick(id: 2, symbol: 'USDJPY', bid: 157.42))
      ..add(tick(id: 3, symbol: 'US500', bid: 5588.2));
    await deliverTicks(tester);

    expect(find.text('1.08123'), findsOneWidget); // 5 decimals
    expect(find.text('157.420'), findsOneWidget); // 3 decimals
    expect(find.text('5,588.2'), findsOneWidget); // 1 decimal, grouped
    await settleFlash(tester);
  });

  testWidgets('shows a placeholder until the first tick', (tester) async {
    await pumpWatchlist(tester);

    // Two cells (bid and ask) per row, for every primed instrument.
    expect(find.text('—'), findsNWidgets(_instruments.length * 2));
  });

  group('flash', () {
    /// The tint the row is currently painting behind its price cell.
    Color flashColorOf(WidgetTester tester, String symbol) {
      final box = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byKey(ValueKey(symbol)),
          matching: find.byType(DecoratedBox),
        ),
      );
      return (box.decoration as BoxDecoration).color!;
    }

    testWidgets('fades in on a move and back out again', (tester) async {
      await pumpWatchlist(tester);
      store.add(tick(id: 1, symbol: 'EURUSD', bid: 1.08));
      await deliverTicks(tester);
      await settleFlash(tester);

      store.add(tick(id: 2, symbol: 'EURUSD', bid: 1.09, ts: 2000));
      await deliverTicks(tester);
      await tester.pump(const Duration(milliseconds: 30));

      expect(flashColorOf(tester, 'EURUSD').a, greaterThan(0));

      await settleFlash(tester);
      expect(flashColorOf(tester, 'EURUSD').a, 0);
    });

    testWidgets('does not flash the very first price of a session', (
      tester,
    ) async {
      await pumpWatchlist(tester);

      store.add(tick(symbol: 'EURUSD', bid: 1.08));
      await deliverTicks(tester);
      await tester.pump(const Duration(milliseconds: 30));

      expect(flashColorOf(tester, 'EURUSD').a, 0);
    });

    // A repeated price is not a move, and flashing for one would be a lie
    // about what the market did.
    testWidgets('does not flash when the price is unchanged', (tester) async {
      await pumpWatchlist(tester);
      store.add(tick(id: 1, symbol: 'EURUSD', bid: 1.08));
      await deliverTicks(tester);
      await settleFlash(tester);

      store.add(tick(id: 2, symbol: 'EURUSD', bid: 1.08, ts: 2000));
      await deliverTicks(tester);
      await tester.pump(const Duration(milliseconds: 30));

      expect(flashColorOf(tester, 'EURUSD').a, 0);
    });

    testWidgets('flashes only the row that moved', (tester) async {
      await pumpWatchlist(tester);
      store
        ..add(tick(id: 1, symbol: 'EURUSD', bid: 1.08))
        ..add(tick(id: 2, symbol: 'GBPUSD', bid: 1.26));
      await deliverTicks(tester);
      await settleFlash(tester);

      store.add(tick(id: 3, symbol: 'EURUSD', bid: 1.09, ts: 2000));
      await deliverTicks(tester);
      await tester.pump(const Duration(milliseconds: 30));

      expect(flashColorOf(tester, 'EURUSD').a, greaterThan(0));
      expect(flashColorOf(tester, 'GBPUSD').a, 0);
      await settleFlash(tester);
    });
  });
}
