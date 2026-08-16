import 'dart:async';

import 'package:flutter/foundation.dart';

import '../domain/models/quote.dart';
import '../domain/models/tick.dart';

/// Holds the current price of every instrument and gives each row its own
/// listenable.
///
/// This is the reason a burst is cheap. Prices never enter bloc state, so a
/// tick does not rebuild the list, the scaffold, or the rows that did not
/// change — it sets one [ValueNotifier], and the single
/// `ValueListenableBuilder` watching it repaints.
///
/// On top of that, ticks are **conflated**: only the newest price per symbol
/// survives a flush window, and the window is [flushInterval] long. The
/// feed's bursts are ~220 ticks in ~100ms spread over the five most active
/// instruments; conflation collapses that to at most five notifications.
///
/// Why 100ms: the flash animation runs for 250ms, so a faster cadence cannot
/// be perceived — it would only cut flashes short. In calm conditions the
/// busiest instruments tick about eight times a second, so at 10Hz almost
/// nothing is dropped in normal use; the rate only bites during the bursts it
/// exists for.
///
/// Foundation only — no widgets — so this is unit-testable without pumping a
/// widget tree.
class QuoteStore {
  QuoteStore({this.flushInterval = const Duration(milliseconds: 100)});

  final Duration flushInterval;

  final Map<String, ValueNotifier<Quote?>> _quotes = {};
  final Map<String, Tick> _pending = {};

  /// One-shot rather than periodic: a quiet feed schedules no timers at all.
  Timer? _flush;
  StreamSubscription<Tick>? _ticks;

  /// Creates a notifier per symbol up front, so rows never mutate the store
  /// while building and the map never rehashes mid-burst.
  void prime(Iterable<String> symbols) {
    for (final symbol in symbols) {
      _quotes.putIfAbsent(symbol, () => ValueNotifier<Quote?>(null));
    }
  }

  /// The listenable a row watches. Null until that symbol's first tick.
  ValueListenable<Quote?> listenTo(String symbol) => _notifierFor(symbol);

  /// Routes accepted ticks into the store. Called once, at startup.
  void bindTo(Stream<Tick> ticks) {
    _ticks?.cancel();
    _ticks = ticks.listen(add);
  }

  void add(Tick tick) {
    _pending[tick.symbol] = tick; // latest wins; the rest were never displayed
    _flush ??= Timer(flushInterval, _publishPending);
  }

  void _publishPending() {
    _flush = null;
    for (final tick in _pending.values) {
      final notifier = _notifierFor(tick.symbol);
      notifier.value = Quote(
        bid: tick.bid,
        ask: tick.ask,
        ts: tick.ts,
        // Against the last price the user actually saw, not the last tick we
        // received: ticks conflated away were never on screen, so flashing
        // relative to them would report a move nobody witnessed.
        direction: _directionFrom(notifier.value?.bid, tick.bid),
      );
    }
    _pending.clear();
  }

  PriceDirection _directionFrom(double? previous, double next) {
    if (previous == null || previous == next) return PriceDirection.flat;
    return next > previous ? PriceDirection.up : PriceDirection.down;
  }

  ValueNotifier<Quote?> _notifierFor(String symbol) =>
      _quotes.putIfAbsent(symbol, () => ValueNotifier<Quote?>(null));

  /// Stops consuming ticks. The counterpart to [bindTo].
  ///
  /// The store outlives any one watchlist session, so whoever bound it has to
  /// unbind it; otherwise a closed bloc leaves a live subscription behind.
  Future<void> detach() async {
    await _ticks?.cancel();
    _ticks = null;
  }

  /// Drops every price, so a new session cannot display — or flash against —
  /// the previous one's numbers.
  ///
  /// Also drops anything queued for the next flush: a tick that arrived just
  /// before sign-out must not land after it.
  void clear() {
    _flush?.cancel();
    _flush = null;
    _pending.clear();
    for (final notifier in _quotes.values) {
      notifier.value = null;
    }
  }

  Future<void> dispose() async {
    await _ticks?.cancel();
    _ticks = null;
    _flush?.cancel();
    _flush = null;
    _pending.clear();
    for (final notifier in _quotes.values) {
      notifier.dispose();
    }
    _quotes.clear();
  }
}
