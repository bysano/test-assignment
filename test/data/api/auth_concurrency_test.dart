import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse/core/errors/api_exception.dart';
import 'package:pulse/features/auth/data/auth_api.dart';
import 'package:pulse/features/auth/data/auth_repository.dart';
import 'package:pulse/features/auth/data/authenticated_client.dart';
import 'package:pulse_native/pulse_native.dart';

/// One token serves the REST client and the stream, so a single expiry 401s
/// everything in flight at once. These tests pin what happens then — the
/// answers are not obvious from reading any one file, because the behaviour
/// comes from `AuthenticatedClient` and `AuthRepository` together.
class _LoginStub implements AuthApi {
  _LoginStub(this._issue);

  final String Function() _issue;

  /// When set, logins hang until it completes — lets a test hold a refresh
  /// open and send more traffic into it.
  Completer<void>? gate;

  @override
  Future<LoginResult> login({
    required String username,
    required String password,
  }) async {
    await gate?.future;
    return LoginResult(token: _issue(), expiresIn: const Duration(seconds: 60));
  }
}

void main() {
  late int logins;
  late bool loginWorks;
  late _LoginStub loginStub;
  late AuthRepository auth;

  late int serverCalls;
  late List<String?> tokensReceived;
  late int rejectUntilCall;

  setUp(() async {
    logins = 0;
    loginWorks = true;
    serverCalls = 0;
    tokensReceived = [];
    rejectUntilCall = 1 << 30; // reject everything unless a test says otherwise

    loginStub = _LoginStub(() {
      logins++;
      if (!loginWorks) throw const InvalidCredentialsException();
      return 'token-$logins';
    });
    auth = AuthRepository(api: loginStub, store: InMemorySecureTokenStore());
    await auth.signIn(username: 'trader', password: 'password123');
  });

  AuthenticatedClient buildClient() => AuthenticatedClient(
    tokens: auth,
    inner: MockClient((request) async {
      serverCalls++;
      tokensReceived.add(request.headers['authorization']);
      return serverCalls <= rejectUntilCall
          ? http.Response('', 401)
          : http.Response('ok', 200);
    }),
  );

  group('a burst of 401s', () {
    test(
      'costs exactly one login, however many requests are in flight',
      () async {
        final client = buildClient();
        final loginsBefore = logins;

        await Future.wait([
          for (final path in ['a', 'b', 'c', 'd', 'e'])
            client.get(Uri.parse('http://x/$path')),
        ]);

        expect(logins - loginsBefore, 1);
      },
    );

    // There is no explicit queue. Each suspended send() is holding its own
    // request, so "replay everything pending" falls out of the shared future.
    test('replays every pending request with the same new token', () async {
      rejectUntilCall = 3; // the three first attempts fail, retries succeed
      final client = buildClient();

      final responses = await Future.wait([
        for (final path in ['a', 'b', 'c'])
          client.get(Uri.parse('http://x/$path')),
      ]);

      expect(responses.map((r) => r.statusCode), [200, 200, 200]);
      expect(serverCalls, 6); // 3 rejected, 3 replayed
      expect(tokensReceived.take(3), everyElement('Bearer token-1'));
      expect(tokensReceived.skip(3), everyElement('Bearer token-2'));
    });

    test(
      'a request arriving mid-refresh joins it rather than starting another',
      () async {
        rejectUntilCall = 1; // only the opening request 401s
        final client = buildClient();
        loginStub.gate = Completer<void>();
        final loginsBefore = logins;

        final first = client.get(
          Uri.parse('http://x/a'),
        ); // 401s, opens a refresh
        await pumpEventQueue();
        final second = client.get(
          Uri.parse('http://x/b'),
        ); // arrives mid-flight

        loginStub.gate!.complete();
        await Future.wait([first, second]);

        expect(logins - loginsBefore, 1);
      },
    );
  });

  group('when the refresh itself fails', () {
    test('every waiter fails, with the same error', () async {
      loginWorks = false;
      final client = buildClient();

      final outcomes = await Future.wait([
        for (final path in ['a', 'b', 'c'])
          client
              .get(Uri.parse('http://x/$path'))
              .then<Object>((r) => r.statusCode)
              .catchError((Object e) => e),
      ]);

      expect(outcomes, everyElement(isA<InvalidCredentialsException>()));
    });

    test('still only one login attempt is made', () async {
      loginWorks = false;
      final client = buildClient();
      final loginsBefore = logins;

      await Future.wait([
        for (final path in ['a', 'b', 'c'])
          client
              .get(Uri.parse('http://x/$path'))
              .then<Object?>((r) => null)
              .catchError((Object _) => null),
      ]);

      expect(logins - loginsBefore, 1);
    });

    // The server has told us the token is dead; our own clock still thinks it
    // has 50 seconds left. Keeping it would buy a guaranteed 401 before every
    // later retry.
    test('the rejected token is never handed out again', () async {
      loginWorks = false;
      final client = buildClient();
      await client
          .get(Uri.parse('http://x/a'))
          .then<Object?>((r) => null)
          .catchError((Object _) => null);

      serverCalls = 0;
      await client
          .get(Uri.parse('http://x/later'))
          .then<Object?>((r) => null)
          .catchError((Object _) => null);

      // It failed at the login, without wasting a request on a dead token.
      expect(serverCalls, 0);
    });

    test('recovers once logins work again', () async {
      loginWorks = false;
      final client = buildClient();
      await client
          .get(Uri.parse('http://x/a'))
          .then<Object?>((r) => null)
          .catchError((Object _) => null);

      loginWorks = true;
      rejectUntilCall = 0; // the server is happy now
      final response = await client.get(Uri.parse('http://x/b'));

      expect(response.statusCode, 200);
    });
  });

  test('a healthy token is reused rather than refreshed', () async {
    rejectUntilCall = 0;
    final client = buildClient();
    final loginsBefore = logins;

    await client.get(Uri.parse('http://x/a'));
    await client.get(Uri.parse('http://x/b'));

    expect(logins - loginsBefore, 0);
    expect(tokensReceived, everyElement('Bearer token-1'));
  });
}
