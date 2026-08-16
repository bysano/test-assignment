import 'sse_frame.dart';

/// Opens SSE streams.
///
/// The connection state machine talks only to this interface, which is what
/// lets [FeedConnection] be tested against a fake with no sockets, no server
/// and no real time.
abstract interface class SseTransport {
  /// Opens `GET /stream`.
  ///
  /// Pass [lastEventId] to ask the server to replay everything it still holds
  /// after that id. Throws [UnauthorizedException] on 401 and [ApiException]
  /// on any other non-200; connection-level failures throw whatever the socket
  /// layer throws.
  Future<SseSubscription> connect({required String token, int? lastEventId});
}

/// A live stream. Closing it must be immediate and idempotent — the stall
/// watchdog aborts connections that are still nominally healthy.
abstract interface class SseSubscription {
  /// Frames in arrival order. Completes when the server ends the stream, and
  /// emits an error if the socket fails.
  Stream<SseFrame> get frames;

  /// Tears down the socket. Safe to call repeatedly, and safe to call while
  /// frames are still arriving.
  Future<void> cancel();
}
