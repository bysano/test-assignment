import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse/auth/auth_repository.dart';
import 'package:pulse/auth/stored_session.dart';
import 'package:pulse/data/api/api_exception.dart';
import 'package:pulse/data/api/auth_api.dart';
import 'package:pulse_native/pulse_native.dart';

/// Secure storage we can inspect and break on demand.
class RecordingStore implements SecureTokenStore {
  String? value;
  int writes = 0;
  int deletes = 0;
  Object? failWith;

  @override
  Future<void> write(String token) async {
    if (failWith != null) throw failWith!;
    writes++;
    value = token;
  }

  @override
  Future<String?> read() async {
    if (failWith != null) throw failWith!;
    return value;
  }

  @override
  Future<void> delete() async {
    if (failWith != null) throw failWith!;
    deletes++;
    value = null;
  }
}

void main() {
  late RecordingStore store;
  late DateTime now;
  late int logins;
  late Object? loginError;

  DateTime clock() => now;

  AuthRepository buildRepository() {
    final api = AuthApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      client: MockClient((_) async {
        if (loginError != null) throw loginError!;
        logins++;
        return http.Response('{"token":"token-$logins","expiresIn":60}', 200);
      }),
    );
    return AuthRepository(api: api, store: store, clock: clock);
  }

  setUp(() {
    store = RecordingStore();
    now = DateTime.utc(2026, 8, 16, 12);
    logins = 0;
    loginError = null;
  });

  group('sign in', () {
    test('obtains a token and persists it with its expiry', () async {
      final repository = buildRepository();

      await repository.signIn(username: 'trader', password: 'password123');

      expect(await repository.currentToken(), 'token-1');
      final stored = StoredSession.tryParse(store.value!);
      expect(stored!.token, 'token-1');
      expect(stored.expiresAt, now.add(const Duration(seconds: 60)));
    });

    test('surfaces rejected credentials to the caller', () async {
      loginError = const InvalidCredentialsException();
      final repository = buildRepository();

      await expectLater(
        repository.signIn(username: 'trader', password: 'nope'),
        throwsA(isA<InvalidCredentialsException>()),
      );
    });

    // Losing the Keychain costs us persistence, not the session.
    test('succeeds even when secure storage refuses to write', () async {
      store.failWith = const SecureStorageException('keychain_error', 'nope');
      final repository = buildRepository();

      await repository.signIn(username: 'trader', password: 'password123');

      expect(repository.hasSession, isTrue);
    });
  });

  group('currentToken', () {
    test('reuses a token that is comfortably valid', () async {
      final repository = buildRepository();
      await repository.signIn(username: 'trader', password: 'password123');

      now = now.add(const Duration(seconds: 30));

      expect(await repository.currentToken(), 'token-1');
      expect(logins, 1); // no second login
    });

    // The server checks expiry once a second and connecting takes a moment;
    // handing over a token with 2s left is asking for an instant 401.
    test('renews early, inside the refresh margin', () async {
      final repository = buildRepository();
      await repository.signIn(username: 'trader', password: 'password123');

      now = now.add(const Duration(seconds: 55)); // 5s left, margin is 10s

      expect(await repository.currentToken(), 'token-2');
      expect(logins, 2);
    });

    test('renews an already-expired token', () async {
      final repository = buildRepository();
      await repository.signIn(username: 'trader', password: 'password123');

      now = now.add(const Duration(seconds: 120));

      expect(await repository.currentToken(), 'token-2');
    });
  });

  group('refreshToken', () {
    // A proactive refresh landing at the same moment as a 401 must not fire
    // two logins and let the loser overwrite the winner.
    test('collapses concurrent refreshes into one login', () async {
      final repository = buildRepository();
      await repository.signIn(username: 'trader', password: 'password123');

      final results = await Future.wait([
        repository.refreshToken(),
        repository.refreshToken(),
        repository.refreshToken(),
      ]);

      expect(logins, 2); // the sign-in, plus exactly one refresh
      expect(results, ['token-2', 'token-2', 'token-2']);
    });

    test('allows a later refresh once the first has settled', () async {
      final repository = buildRepository();
      await repository.signIn(username: 'trader', password: 'password123');

      await repository.refreshToken();
      await repository.refreshToken();

      expect(logins, 3);
    });

    // A restored session has a token but no credentials behind it.
    test('reports rejected credentials when there is nothing to log in with',
        () async {
      store.value = StoredSession(
        token: 'restored',
        expiresAt: now.add(const Duration(seconds: 60)),
      ).encode();
      final repository = buildRepository();
      await repository.restore();

      await expectLater(
        repository.refreshToken(),
        throwsA(isA<InvalidCredentialsException>()),
      );
    });
  });

  group('restore', () {
    test('adopts a session that is still valid', () async {
      store.value = StoredSession(
        token: 'restored',
        expiresAt: now.add(const Duration(seconds: 30)),
      ).encode();
      final repository = buildRepository();

      expect(await repository.restore(), isTrue);
      expect(await repository.currentToken(), 'restored');
    });

    test('discards an expired session', () async {
      store.value = StoredSession(
        token: 'stale',
        expiresAt: now.subtract(const Duration(seconds: 1)),
      ).encode();
      final repository = buildRepository();

      expect(await repository.restore(), isFalse);
      expect(store.deletes, 1);
      expect(store.value, isNull);
    });

    test('returns false when nothing is stored', () async {
      expect(await buildRepository().restore(), isFalse);
    });

    test('discards an unreadable payload', () async {
      store.value = 'not json at all';

      expect(await buildRepository().restore(), isFalse);
      expect(store.deletes, 1);
    });

    // A misbehaving Keychain should cost a login prompt, not a crash.
    test('returns false when secure storage throws', () async {
      store.failWith = const SecureStorageException('keychain_error', 'nope');

      expect(await buildRepository().restore(), isFalse);
    });
  });

  group('sign out', () {
    test('clears the session and the stored copy', () async {
      final repository = buildRepository();
      await repository.signIn(username: 'trader', password: 'password123');

      await repository.signOut();

      expect(repository.hasSession, isFalse);
      expect(store.value, isNull);
      expect(store.deletes, 1);
    });

    test('forgets the credentials, so no silent re-login is possible', () async {
      final repository = buildRepository();
      await repository.signIn(username: 'trader', password: 'password123');

      await repository.signOut();

      await expectLater(
        repository.refreshToken(),
        throwsA(isA<InvalidCredentialsException>()),
      );
    });
  });

  test('StoredSession round-trips through JSON', () {
    final session = StoredSession(token: 'abc', expiresAt: now);

    final parsed = StoredSession.tryParse(session.encode());

    expect(parsed!.token, 'abc');
    expect(parsed.expiresAt, now);
    expect(jsonDecode(session.encode()), isA<Map<String, dynamic>>());
  });
}
