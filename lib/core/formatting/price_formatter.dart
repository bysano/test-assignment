import 'package:intl/intl.dart';

/// Formats prices to each instrument's own precision.
///
/// Formatters are cached per decimal count. Building a [NumberFormat] is not
/// free, and a naive implementation would build one per price per frame — with
/// forty instruments ticking, that is the kind of allocation that shows up in
/// a DevTools timeline.
abstract final class PriceFormatter {
  static final Map<int, NumberFormat> _cache = {};

  static String format(double value, int decimals) =>
      _formatterFor(decimals).format(value);

  static NumberFormat _formatterFor(int decimals) => _cache.putIfAbsent(
    decimals,
    () => NumberFormat.decimalPatternDigits(decimalDigits: decimals),
  );
}
