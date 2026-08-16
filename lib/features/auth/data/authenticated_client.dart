import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/token_source.dart';

/// An [http.Client] that keeps itself authorized.
///
/// Dart's answer to an interceptor: [http.BaseClient] routes every request
/// through one [send], which is the single place that attaches the bearer
/// token and reacts to a 401. Callers just make requests — no call site has to
/// remember to fetch a token, attach it, catch a 401, refresh and retry, and
/// no two call sites can drift apart on the policy.
///
/// **The login client must not be wrapped in this.** `/login` is how a token
/// is obtained; sending it through the thing that refreshes tokens would
/// recurse. The DI module deliberately hands [AuthApi] the raw client and only
/// this one to everything else.
class AuthenticatedClient extends http.BaseClient {
  AuthenticatedClient({required http.Client inner, required TokenSource tokens})
    : _inner = inner,
      _tokens = tokens;

  final http.Client _inner;
  final TokenSource _tokens;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final token = await _tokens.currentToken();
    // Safe to mutate: the request has not been finalized yet.
    request.headers[HttpHeaders.authorizationHeader] = 'Bearer $token';

    final response = await _inner.send(request);
    if (response.statusCode != HttpStatus.unauthorized) return response;

    // A body that has already been consumed cannot be sent a second time.
    // Hand the 401 back rather than pretending we can recover from it.
    if (request is! http.Request) return response;

    // Drain before reissuing, or the socket stays checked out of the pool.
    await response.stream.drain<void>();

    final fresh = await _tokens.refreshAfter(token);
    return _inner.send(_replay(request, fresh));
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }

  /// A [http.BaseRequest] is finalized when it is sent, so the retry needs its
  /// own copy rather than the original.
  ///
  /// Retrying is safe whatever the method, `POST` included: a 401 means the
  /// server rejected us before doing any work, so there is no side effect to
  /// duplicate.
  http.Request _replay(http.Request original, String token) {
    return http.Request(original.method, original.url)
      ..bodyBytes = original.bodyBytes
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection
      ..headers.addAll(original.headers)
      ..headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
  }
}
