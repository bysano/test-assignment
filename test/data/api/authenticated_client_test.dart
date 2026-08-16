import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse/core/errors/api_exception.dart';
import 'package:pulse/features/auth/data/authenticated_client.dart';
import 'package:pulse/features/auth/domain/token_source.dart';

/// Hands out `token-0`, then `token-1`, and so on.
class FakeTokens implements TokenSource {
  int issued = 0;
  int refreshes = 0;
  Object? refreshError;

  /// Tokens handed out, in order — lets a test see exactly what was attached.
  final List<String> handed = [];

  String get _current => 'token-$issued';

  @override
  Future<String> currentToken() async {
    handed.add(_current);
    return _current;
  }

  @override
  Future<String> refreshAfter(String rejected) async {
    final error = refreshError;
    if (error != null) throw error;
    refreshes++;
    // The real repository skips the login when the token has already moved on.
    if (rejected != _current) return _current;
    issued++;
    handed.add(_current);
    return _current;
  }
}

void main() {
  late FakeTokens tokens;
  late List<http.BaseRequest> sent;

  setUp(() {
    tokens = FakeTokens();
    sent = [];
  });

  AuthenticatedClient clientReturning(
    List<http.Response> responses, {
    void Function(http.BaseRequest request)? onSend,
  }) {
    var call = 0;
    return AuthenticatedClient(
      tokens: tokens,
      inner: MockClient((request) async {
        sent.add(request);
        onSend?.call(request);
        final index = call < responses.length ? call : responses.length - 1;
        call++;
        return responses[index];
      }),
    );
  }

  test('attaches the bearer token', () async {
    final client = clientReturning([http.Response('{}', 200)]);

    await client.get(Uri.parse('http://localhost:8080/instruments'));

    expect(sent.single.headers['authorization'], 'Bearer token-0');
  });

  test('passes a healthy response straight through', () async {
    final client = clientReturning([http.Response('hello', 200)]);

    final response = await client.get(Uri.parse('http://localhost:8080/x'));

    expect(response.body, 'hello');
    expect(tokens.refreshes, 0);
  });

  group('on 401', () {
    test('refreshes once and retries with the new token', () async {
      final client = clientReturning([
        http.Response('', 401),
        http.Response('ok', 200),
      ]);

      final response = await client.get(Uri.parse('http://localhost:8080/x'));

      expect(response.statusCode, 200);
      expect(sent, hasLength(2));
      expect(sent[0].headers['authorization'], 'Bearer token-0');
      expect(sent[1].headers['authorization'], 'Bearer token-1');
    });

    test('tells the source which token was rejected', () async {
      final client = clientReturning([
        http.Response('', 401),
        http.Response('ok', 200),
      ]);

      await client.get(Uri.parse('http://localhost:8080/x'));

      expect(tokens.refreshes, 1);
    });

    // One retry, not a loop: a second 401 is a real authorization failure and
    // belongs to the caller.
    test('gives up after one retry', () async {
      final client = clientReturning([
        http.Response('', 401),
        http.Response('', 401),
      ]);

      final response = await client.get(Uri.parse('http://localhost:8080/x'));

      expect(response.statusCode, 401);
      expect(sent, hasLength(2));
      expect(tokens.refreshes, 1);
    });

    test('propagates rejected credentials rather than retrying', () async {
      tokens.refreshError = const InvalidCredentialsException();
      final client = clientReturning([http.Response('', 401)]);

      await expectLater(
        client.get(Uri.parse('http://localhost:8080/x')),
        throwsA(isA<InvalidCredentialsException>()),
      );
      expect(sent, hasLength(1));
    });

    // The retry must be a faithful copy: a BaseRequest is finalized on send,
    // so this is where a naive implementation silently drops the body.
    test('replays the method, body and headers', () async {
      final client = clientReturning([
        http.Response('', 401),
        http.Response('ok', 200),
      ]);

      await client.post(
        Uri.parse('http://localhost:8080/thing'),
        headers: {'content-type': 'application/json', 'x-trace': 'abc'},
        body: jsonEncode({'hello': 'world'}),
      );

      final retry = sent[1] as http.Request;
      expect(retry.method, 'POST');
      expect(jsonDecode(retry.body), {'hello': 'world'});
      expect(retry.headers['x-trace'], 'abc');
      expect(retry.url.path, '/thing');
    });
  });

  // Two callers hitting a 401 at the same moment should cost one login, not
  // one each — the repository decides that, and the client must pass through
  // the token it was rejected on for it to be able to.
  test('a second caller reuses a token another already refreshed', () async {
    final client = clientReturning([
      http.Response('', 401),
      http.Response('ok', 200),
    ]);
    await client.get(Uri.parse('http://localhost:8080/a')); // moves to token-1

    // A caller still holding token-0 asks again.
    final replacement = await tokens.refreshAfter('token-0');

    expect(replacement, 'token-1'); // handed the existing one
    expect(tokens.issued, 1); // no second login
  });
}
