import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../../core/errors/api_exception.dart';
import 'sse_frame.dart';
import 'sse_parser.dart';
import 'sse_transport.dart';

/// SSE over `dart:io`'s [HttpClient].
///
/// Why not `package:http` (which the REST calls do use)? Because the stall
/// watchdog has to guarantee a socket is *gone*, not merely unsubscribed —
/// otherwise a half-dead connection lingers while we open its replacement.
/// [HttpClient.close] with `force: true` gives that guarantee, so each
/// connection gets its own client and cancelling destroys it outright.
class HttpSseTransport implements SseTransport {
  HttpSseTransport({
    required Uri baseUrl,
    HttpClient Function()? clientFactory,
    Duration connectionTimeout = const Duration(seconds: 10),
  }) : _baseUrl = baseUrl,
       _clientFactory = clientFactory ?? HttpClient.new,
       _connectionTimeout = connectionTimeout;

  final Uri _baseUrl;
  final HttpClient Function() _clientFactory;
  final Duration _connectionTimeout;

  @override
  Future<SseSubscription> connect({
    required String token,
    int? lastEventId,
  }) async {
    final client = _clientFactory()..connectionTimeout = _connectionTimeout;
    try {
      final request = await client.getUrl(_baseUrl.resolve('/stream'));
      request.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..set(HttpHeaders.acceptHeader, 'text/event-stream')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      if (lastEventId != null) {
        request.headers.set('Last-Event-ID', '$lastEventId');
      }

      final response = await request.close();
      if (response.statusCode == HttpStatus.unauthorized) {
        throw const UnauthorizedException();
      }
      if (response.statusCode != HttpStatus.ok) {
        throw ApiException(response.statusCode);
      }
      return _HttpSseSubscription(client, response);
    } catch (_) {
      client.close(force: true);
      rethrow;
    }
  }
}

class _HttpSseSubscription implements SseSubscription {
  _HttpSseSubscription(this._client, HttpClientResponse response) {
    final parser = SseParser();
    _socket = response
        .transform(
          utf8.decoder,
        ) // handles multi-byte chars split across packets
        .listen(
          (chunk) {
            for (final frame in parser.add(chunk)) {
              if (!_frames.isClosed) _frames.add(frame);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!_frames.isClosed) _frames.addError(error, stack);
            unawaited(cancel());
          },
          onDone: () => unawaited(cancel()),
          cancelOnError: true,
        );
  }

  final HttpClient _client;
  final StreamController<SseFrame> _frames = StreamController<SseFrame>();
  late final StreamSubscription<String> _socket;
  bool _cancelled = false;

  @override
  Stream<SseFrame> get frames => _frames.stream;

  @override
  Future<void> cancel() async {
    if (_cancelled) return;
    _cancelled = true;
    await _socket.cancel();
    _client.close(force: true);
    if (!_frames.isClosed) await _frames.close();
  }
}
