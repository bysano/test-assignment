import 'package:flutter/material.dart';

import '../../../../app/theme/theme.dart';
import '../../application/feed/feed_status.dart';

/// How a [FeedStatus] should read to a person.
///
/// Shared by the badge and the banner so the two can never disagree about
/// what is happening.
final class FeedStatusPresentation {
  const FeedStatusPresentation({
    required this.label,
    required this.detail,
    required this.color,
  });

  factory FeedStatusPresentation.of(FeedStatus status) => switch (status) {
    FeedIdle() => const FeedStatusPresentation(
      label: 'Idle',
      detail: 'Not connected.',
      color: PulseColors.idle,
    ),
    FeedConnecting() => const FeedStatusPresentation(
      label: 'Connecting',
      detail: 'Opening the price stream…',
      color: PulseColors.warning,
    ),
    FeedLive() => const FeedStatusPresentation(
      label: 'Live',
      detail: 'Prices are current.',
      color: PulseColors.live,
    ),
    // Spelled out plainly: this is the state a user would otherwise misread
    // as a quiet market.
    FeedStalled() => const FeedStatusPresentation(
      label: 'Stalled',
      detail: 'The connection went silent. These prices are frozen.',
      color: PulseColors.warning,
    ),
    FeedReconnecting(:final attempt, :final delay) => FeedStatusPresentation(
      label: 'Reconnecting',
      detail:
          'Attempt $attempt in ${(delay.inMilliseconds / 1000).toStringAsFixed(1)}s. '
          'Prices are frozen.',
      color: PulseColors.warning,
    ),
    FeedOffline() => const FeedStatusPresentation(
      label: 'Offline',
      detail: 'No network. Waiting to reconnect. Prices are frozen.',
      color: PulseColors.danger,
    ),
    FeedFatal(:final message) => FeedStatusPresentation(
      label: 'Signed out',
      detail: message,
      color: PulseColors.danger,
    ),
  };

  final String label;
  final String detail;
  final Color color;
}

/// Compact status pill for the app bar.
class ConnectionBadge extends StatelessWidget {
  const ConnectionBadge({required this.status, super.key});

  final FeedStatus status;

  @override
  Widget build(BuildContext context) {
    final presentation = FeedStatusPresentation.of(status);
    return Semantics(
      label: 'Connection: ${presentation.label}',
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: presentation.color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusDot(color: presentation.color, pulsing: status is FeedLive),
            const SizedBox(width: 7),
            Text(
              presentation.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: presentation.color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A dot that breathes while live, so "connected" is legible at a glance even
/// with the label out of focus.
class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.color, required this.pulsing});

  final Color color;
  final bool pulsing;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  );

  @override
  void initState() {
    super.initState();
    if (widget.pulsing) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(_StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulsing == oldWidget.pulsing) return;
    if (widget.pulsing) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: widget.color.withValues(alpha: 1 - _pulse.value * 0.6),
        ),
      ),
    );
  }
}
