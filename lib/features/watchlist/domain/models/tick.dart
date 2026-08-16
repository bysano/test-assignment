import 'dart:convert';

import 'package:equatable/equatable.dart';

/// One price update.
///
/// [id] is the SSE event id — a global, strictly increasing sequence assigned
/// by the server at emit time. [ts] is the *market* timestamp and is NOT
/// ordered: the feed replays older timestamps on purpose. The two are used for
/// different jobs in [TickPipeline]: [id] for dedup and resume, [ts] for
/// staleness.
final class Tick extends Equatable {
  const Tick({
    required this.id,
    required this.symbol,
    required this.bid,
    required this.ask,
    required this.ts,
  });

  final int id;
  final String symbol;
  final double bid;
  final double ask;
  final int ts;

  /// Decodes an SSE `data:` payload, returning null for anything malformed.
  ///
  /// The feed emits deliberate garbage (`###garbage-not-json###`), so failure
  /// here is an expected, routine outcome — never an exception.
  static Tick? tryParse(int id, String data) {
    final Object? json;
    try {
      json = jsonDecode(data);
    } on FormatException {
      return null;
    }
    if (json is! Map) return null;

    final symbol = json['s'];
    final bid = json['b'];
    final ask = json['a'];
    final ts = json['ts'];
    // Whole-number prices decode as int, so accept any num.
    if (symbol is! String || symbol.isEmpty) return null;
    if (bid is! num || ask is! num || ts is! num) return null;
    if (!bid.isFinite || !ask.isFinite) return null;

    return Tick(
      id: id,
      symbol: symbol,
      bid: bid.toDouble(),
      ask: ask.toDouble(),
      ts: ts.toInt(),
    );
  }

  @override
  List<Object?> get props => [id, symbol, bid, ask, ts];
}
