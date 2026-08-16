import 'package:flutter/material.dart';

import '../../application/feed/feed_status.dart';
import 'connection_badge.dart';

/// Says in words what the badge says in colour.
///
/// Hidden while live so the healthy case is uncluttered, and unmissable
/// otherwise — the requirement is that a user can never mistake a frozen price
/// for a live one, and a small coloured dot alone does not carry that weight.
class StatusBanner extends StatelessWidget {
  const StatusBanner({required this.status, super.key});

  final FeedStatus status;

  @override
  Widget build(BuildContext context) {
    final visible = !status.isLive && status is! FeedIdle;
    final presentation = FeedStatusPresentation.of(status);

    return AnimatedSize(
      duration: const Duration(milliseconds: 180),
      alignment: Alignment.topCenter,
      child: visible
          ? Container(
              width: double.infinity,
              color: presentation.color.withValues(alpha: 0.18),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 18,
                    color: presentation.color,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      presentation.detail,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: presentation.color,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox(width: double.infinity),
    );
  }
}
