/// A dispatched unit from the SSE wire format.
sealed class SseFrame {
  const SseFrame();
}

/// A comment line (`: ping`).
///
/// Carries no data, but it is the *only* proof of life during quiet markets,
/// so the stall watchdog treats it exactly like an event.
final class SseComment extends SseFrame {
  const SseComment(this.text);

  final String text;
}

/// A dispatched event: `id` + `event` + accumulated `data`.
final class SseEvent extends SseFrame {
  const SseEvent({required this.id, required this.event, required this.data});

  /// Null only if the server never sent an `id:` field.
  final int? id;

  /// Defaults to `message` per the SSE spec when no `event:` field is present.
  final String event;

  final String data;
}
