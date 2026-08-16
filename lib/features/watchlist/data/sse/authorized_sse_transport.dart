import '../../../../core/errors/api_exception.dart';
import '../../../auth/domain/token_source.dart';
import 'sse_transport.dart';

/// Opens a stream that is already authorized.
///
/// The port [FeedConnection] depends on. It has no `token` parameter, and that
/// is the point: the connection state machine is about backoff, stalls and
/// reachability, and should not also be an authentication client.
abstract interface class AuthorizedStream {
  /// Throws [UnauthorizedException] if the server still refuses us after a
  /// token refresh, and [InvalidCredentialsException] if no token can be
  /// obtained at all — the caller decides which of those is worth retrying.
  Future<SseSubscription> open({int? lastEventId});
}

/// Wraps a raw [SseTransport] with the same attach-refresh-retry policy the
/// REST client uses.
///
/// `package:http`'s interceptor seam does not reach here — the stream runs on
/// `dart:io` for its abort semantics — so the policy is applied by decoration
/// instead. Same rules, one connect deeper.
class AuthorizedSseTransport implements AuthorizedStream {
  AuthorizedSseTransport({
    required SseTransport transport,
    required TokenSource tokens,
  }) : _transport = transport,
       _tokens = tokens;

  final SseTransport _transport;
  final TokenSource _tokens;

  @override
  Future<SseSubscription> open({int? lastEventId}) async {
    final token = await _tokens.currentToken();
    try {
      return await _transport.connect(token: token, lastEventId: lastEventId);
    } on UnauthorizedException {
      // Expected roughly once a minute: this server binds a token to the
      // connection and drops the stream when it expires, so the token in hand
      // is often the one that just died. Worth exactly one retry — a second
      // 401 is a real problem and belongs to the caller's backoff.
      final fresh = await _tokens.refreshAfter(token);
      return _transport.connect(token: fresh, lastEventId: lastEventId);
    }
  }
}
