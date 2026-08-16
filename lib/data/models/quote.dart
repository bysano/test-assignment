import 'package:equatable/equatable.dart';

/// Which way the price moved relative to the last quote the user actually saw.
///
/// Relative to what was *displayed*, not to the previous tick: ticks conflated
/// away inside one flush window were never on screen, so flashing against them
/// would be a lie.
enum PriceDirection { up, down, flat }

/// A price as rendered by a row.
final class Quote extends Equatable {
  const Quote({
    required this.bid,
    required this.ask,
    required this.ts,
    this.direction = PriceDirection.flat,
  });

  final double bid;
  final double ask;
  final int ts;
  final PriceDirection direction;

  @override
  List<Object?> get props => [bid, ask, ts, direction];
}
