/// Timing knobs for [FeedConnection]. Injected so tests can shrink them and
/// so the numbers are stated in one place rather than scattered as literals.
final class FeedConfig {
  const FeedConfig({
    this.staleAfter = const Duration(seconds: 6),
    this.killAfter = const Duration(seconds: 8),
    this.backoffBase = const Duration(milliseconds: 500),
    this.backoffCap = const Duration(seconds: 15),
  });

  /// Silence — no ticks *and* no heartbeats — after which the connection is
  /// declared stalled and the UI stops presenting prices as live.
  ///
  /// Heartbeats arrive every ~5s, so 6s of total silence is already anomalous.
  /// The server's stall suppresses heartbeats too, which is exactly what makes
  /// it detectable.
  final Duration staleAfter;

  /// Total silence after which we stop hoping and force a reconnect. The
  /// server's stalls last ~25s, so waiting one out costs far more than
  /// re-establishing a stream and replaying from `Last-Event-ID`.
  ///
  /// Expected to exceed [staleAfter] — warn first, then act. Not asserted
  /// because a `const` constructor cannot compare two [Duration]s; if the two
  /// are inverted the kill simply fires as soon as the warning does.
  final Duration killAfter;

  /// First retry delay; doubles per consecutive failure.
  final Duration backoffBase;

  /// Ceiling on the retry delay. Bounded so a user who walks back into
  /// coverage is not left staring at a dead app — "don't wait forever".
  final Duration backoffCap;
}
