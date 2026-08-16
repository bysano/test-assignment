import 'package:flutter/material.dart';

import '../../feed/feed_update.dart';

/// A running count of everything the feed has thrown at us and we discarded.
///
/// Not decoration: it is the only way to *see* that dedup, the staleness guard
/// and the malformed-payload handling are doing anything. Without it the
/// correct behaviour and a no-op look identical on screen.
class FeedDiagnostics extends StatelessWidget {
  const FeedDiagnostics({required this.stats, super.key});

  final FeedStats stats;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF1A1E25),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _Counter(label: 'shown', value: stats.accepted),
              _Counter(label: 'dupes', value: stats.duplicates),
              _Counter(label: 'stale', value: stats.stale),
              _Counter(label: 'bad', value: stats.malformed),
              _Counter(label: 'gaps', value: stats.gaps),
            ],
          ),
        ),
      ),
    );
  }
}

class _Counter extends StatelessWidget {
  const _Counter({required this.label, required this.value});

  final String label;
  final int value;

  @override
  Widget build(BuildContext context) {
    final muted = Colors.white.withValues(alpha: 0.4);
    return Row(
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: muted)),
        const SizedBox(width: 5),
        Text(
          '$value',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: Colors.white.withValues(alpha: value == 0 ? 0.4 : 0.85),
          ),
        ),
      ],
    );
  }
}
