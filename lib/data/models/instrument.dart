import 'package:equatable/equatable.dart';

/// A tradable symbol as described by `GET /instruments`.
///
/// [decimals] is authoritative for display: EURUSD quotes to 5 places, JPN225
/// to 0. Never guess it from the tick payload.
final class Instrument extends Equatable {
  const Instrument({
    required this.symbol,
    required this.name,
    required this.decimals,
  });

  final String symbol;
  final String name;
  final int decimals;

  static Instrument? tryParse(Object? json) {
    if (json is! Map) return null;
    final symbol = json['symbol'];
    final name = json['name'];
    final decimals = json['decimals'];
    if (symbol is! String || symbol.isEmpty) return null;
    if (decimals is! int || decimals < 0 || decimals > 10) return null;
    return Instrument(
      symbol: symbol,
      name: name is String ? name : symbol,
      decimals: decimals,
    );
  }

  @override
  List<Object?> get props => [symbol, name, decimals];
}
