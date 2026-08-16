import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pulse/core/errors/api_exception.dart';
import 'package:pulse/features/auth/domain/token_source.dart';
import 'package:pulse/features/watchlist/data/sse/authorized_sse_transport.dart';
import 'package:pulse/features/watchlist/data/sse/sse_frame.dart';
import 'package:pulse/features/watchlist/data/sse/sse_transport.dart';

class _Attempt {
  const _Attempt(this.token, this.lastEventId);

  final String token;
  final int? lastEventId;
}

class _FakeTransport implements SseTransport {
  final List<_Attempt> attempts = [];

  /// Errors for the next connects, in order. Empty means success.
  final List<Object> failures = [];

  @override
  Future<SseSubscription> connect({
    required String token,
    int? lastEventId,
  }) async {
    attempts.add(_Attempt(token, lastEventId));
    if (failures.isNotEmpty) throw failures.removeAt(0);
    return _FakeSubscription();
  }
}

class _FakeSubscription implements SseSubscription {
  @override
  Stream<SseFrame> get frames => const Stream<SseFrame>.empty();

  @override
  Future<void> cancel() async {}
}

class _FakeTokens implements TokenSource {
  int issued = 0;
  final List<String> rejectedSeen = [];
  Object? refreshError;

  @override
  Future<String> currentToken() async => 'token-$issued';

  @override
  Future<String> refreshAfter(String rejected) async {
    rejectedSeen.add(rejected);
    final error = refreshError;
    if (error != null) throw error;
    issued++;
    return 'token-$issued';
  }
}

void main() {
  late _FakeTransport transport;
  late _FakeTokens tokens;
  late AuthorizedSseTransport authorized;

  setUp(() {
    transport = _FakeTransport();
    tokens = _FakeTokens();
    authorized = AuthorizedSseTransport(transport: transport, tokens: tokens);
  });

  test('attaches the current token', () async {
    await authorized.open();

    expect(transport.attempts.single.token, 'token-0');
  });

  test('passes the resume cursor through untouched', () async {
    await authorized.open(lastEventId: 4242);

    expect(transport.attempts.single.lastEventId, 4242);
  });

  // The expected case roughly once a minute: this server binds a token to the
  // connection and drops the stream when it expires, so the token in hand is
  // often the one that just died.
  test('refreshes and retries once on a 401', () async {
    transport.failures.add(const UnauthorizedException());

    await authorized.open(lastEventId: 7);

    expect(transport.attempts, hasLength(2));
    expect(transport.attempts[0].token, 'token-0');
    expect(transport.attempts[1].token, 'token-1');
    expect(tokens.rejectedSeen, ['token-0']);
  });

  test('keeps the resume cursor across the retry', () async {
    transport.failures.add(const UnauthorizedException());

    await authorized.open(lastEventId: 99);

    expect(transport.attempts.map((a) => a.lastEventId), [99, 99]);
  });

  // A second 401 is not an expiry. It belongs to the caller's backoff, not to
  // an ever-deeper retry loop in here.
  test('gives up after one retry', () async {
    transport.failures.addAll([
      const UnauthorizedException(),
      const UnauthorizedException(),
    ]);

    await expectLater(authorized.open(), throwsA(isA<UnauthorizedException>()));
    expect(transport.attempts, hasLength(2));
  });

  test('propagates rejected credentials without retrying', () async {
    transport.failures.add(const UnauthorizedException());
    tokens.refreshError = const InvalidCredentialsException();

    await expectLater(
      authorized.open(),
      throwsA(isA<InvalidCredentialsException>()),
    );
    expect(transport.attempts, hasLength(1));
  });

  test('does not refresh for a non-auth failure', () async {
    transport.failures.add(const ApiException(500));

    await expectLater(authorized.open(), throwsA(isA<ApiException>()));
    expect(tokens.rejectedSeen, isEmpty);
    expect(transport.attempts, hasLength(1));
  });
}
