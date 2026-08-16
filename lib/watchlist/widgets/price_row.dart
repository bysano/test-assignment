import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../core/price_formatter.dart';
import '../../core/theme.dart';
import '../../data/models/instrument.dart';
import '../../data/models/quote.dart';
import '../quote_store.dart';

/// One instrument. The only widget in the app that a tick can rebuild.
///
/// Three things keep a burst cheap here:
///
/// * The row watches its own symbol's listenable, so a tick for EURUSD cannot
///   rebuild the GBPUSD row, the list, or the scaffold.
/// * Only the price cell sits inside the `ValueListenableBuilder` — the symbol
///   and name are built once and never again.
/// * The flash is an `AnimatedBuilder` with its subtree passed as `child`, so
///   sixty animation frames repaint a `ColoredBox` without rebuilding the
///   price text even once.
class PriceRow extends StatefulWidget {
  const PriceRow({
    required this.instrument,
    required this.quotes,
    super.key,
  });

  static const double height = 62;

  final Instrument instrument;
  final QuoteStore quotes;

  @override
  State<PriceRow> createState() => _PriceRowState();
}

class _PriceRowState extends State<PriceRow>
    with SingleTickerProviderStateMixin {
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 250),
  );

  late ValueListenable<Quote?> _quote;
  Color _flashColor = PulseColors.up;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(PriceRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The list recycles rows as it scrolls, so a row can be handed a different
    // instrument without being rebuilt from scratch.
    if (oldWidget.instrument.symbol != widget.instrument.symbol) {
      _quote.removeListener(_onQuote);
      _flash.value = 0;
      _bind();
    }
  }

  void _bind() {
    _quote = widget.quotes.listenTo(widget.instrument.symbol);
    _quote.addListener(_onQuote);
  }

  void _onQuote() {
    final direction = _quote.value?.direction;
    // Flat covers the first price of a session and any move that nets to zero
    // across a conflation window — neither is something to flash about.
    if (direction == null || direction == PriceDirection.flat) return;
    _flashColor = direction == PriceDirection.up
        ? PulseColors.up
        : PulseColors.down;
    // reverse(from: 1), not forward(from: 1): forward would start the
    // controller already at its upper bound, complete instantly, and leave
    // every row permanently tinted.
    _flash.reverse(from: 1);
  }

  @override
  void dispose() {
    _quote.removeListener(_onQuote);
    _flash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: SizedBox(
        height: PriceRow.height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(child: _Identity(instrument: widget.instrument)),
              AnimatedBuilder(
                animation: _flash,
                // Passed through untouched on every animation frame.
                child: _Prices(
                  quote: _quote,
                  decimals: widget.instrument.decimals,
                ),
                builder: (context, child) => DecoratedBox(
                  decoration: BoxDecoration(
                    // Decays fast so a busy instrument reads as a series of
                    // pops rather than a permanent wash of colour.
                    color: _flashColor.withValues(
                      alpha: Curves.easeOut.transform(_flash.value) * 0.30,
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Identity extends StatelessWidget {
  const _Identity({required this.instrument});

  final Instrument instrument;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          instrument.symbol,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(
          instrument.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.5)),
        ),
      ],
    );
  }
}

class _Prices extends StatelessWidget {
  const _Prices({required this.quote, required this.decimals});

  final ValueListenable<Quote?> quote;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Quote?>(
      valueListenable: quote,
      builder: (context, value, _) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PriceCell(label: 'BID', value: value?.bid, decimals: decimals),
            const SizedBox(width: 18),
            _PriceCell(label: 'ASK', value: value?.ask, decimals: decimals),
          ],
        ),
      ),
    );
  }
}

class _PriceCell extends StatelessWidget {
  const _PriceCell({
    required this.label,
    required this.value,
    required this.decimals,
  });

  final String label;
  final double? value;
  final int decimals;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisAlignment: MainAxisAlignment.center,
        // Sized to its content. Left at `max` the column claims the row's
        // full height and overflows the moment a font's metrics run taller
        // than the ones it was eyeballed against.
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 0.8,
              color: Colors.white.withValues(alpha: 0.35),
            ),
          ),
          Text(
            // An em dash until the first tick — an empty cell reads as a bug.
            value == null ? '—' : PriceFormatter.format(value!, decimals),
            // A price must never wrap: a wrapped number is unreadable, and it
            // would change the row's height mid-scroll.
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: kPriceStyle,
          ),
        ],
      ),
    );
  }
}
