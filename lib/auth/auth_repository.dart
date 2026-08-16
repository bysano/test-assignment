import 'dart:async';

import 'package:pulse_native/pulse_native.dart';

import '../data/api/api_exception.dart';
import '../data/api/auth_api.dart';
import '../data/api/token_source.dart';
import 'stored_session.dart';

/// Owns the token's whole life: obtaining it, keeping it fresh, persisting it
/// to the platform's secure store, and handing it out on demand.
///
/// Implements [TokenSource], so the REST interceptor and the stream decorator
/// can renew a token behind the user's back without knowing anything about
/// logins or the Keychain — and without either of them owning a private copy
/// of the policy.
class AuthRepository implements TokenSource {
  AuthRepository({
    required AuthApi api,
    required SecureTokenStore store,
    DateTime Function() clock = DateTime.now,
    Duration refreshMargin = const Duration(seconds: 10),
  }) : _api = api,
       _store = store,
       _clock = clock,
       _refreshMargin = refreshMargin;

  final AuthApi _api;
  final SecureTokenStore _store;
  final DateTime Function() _clock;

  /// How early to replace a token. The server checks expiry once a second and
  /// a connection can take a moment to establish, so handing over a token with
  /// two seconds left is asking for an immediate 401.
  final Duration _refreshMargin;

  String? _username;
  String? _password;
  String? _token;
  DateTime? _expiresAt;

  /// Deduplicates concurrent refreshes. Without it, a 401 arriving at the same
  /// moment as a proactive refresh would fire two logins and leave whichever
  /// finished second as the winner.
  Future<String>? _inFlightRefresh;

  /// True when we can produce a token — now or by logging in again.
  bool get hasSession => _username != null;

  /// Restores a session from secure storage.
  ///
  /// Succeeds on the *credentials*, not on the token: with a 60s TTL the
  /// stored token is usually dead by the next launch, and refusing to restore
  /// because of that would make the stored session almost worthless. A live
  /// token is adopted as a bonus; a dead one is simply left behind and the
  /// first [currentToken] mints a replacement.
  ///
  /// Returns false — never throws — when there is nothing usable. A Keychain
  /// that misbehaves should cost the user a login prompt, not a crash.
  Future<bool> restore() async {
    try {
      final raw = await _store.read();
      if (raw == null) return false;

      final session = StoredSession.tryParse(raw);
      if (session == null) {
        await _store.delete();
        return false;
      }

      _username = session.username;
      _password = session.password;
      if (_clock().isBefore(session.expiresAt)) {
        _token = session.token;
        _expiresAt = session.expiresAt;
      }
      return true;
    } on SecureStorageException {
      return false;
    }
  }

  Future<void> signIn({
    required String username,
    required String password,
  }) async {
    final result = await _api.login(username: username, password: password);
    _username = username;
    _password = password;
    await _adopt(result);
  }

  Future<void> signOut() async {
    _username = null;
    _password = null;
    _token = null;
    _expiresAt = null;
    _inFlightRefresh = null;
    try {
      await _store.delete();
    } on SecureStorageException {
      // Nothing useful to do; the in-memory session is already gone.
    }
  }

  @override
  Future<String> currentToken() async {
    final token = _token;
    final expiresAt = _expiresAt;
    final stillGood =
        token != null &&
        expiresAt != null &&
        _clock().isBefore(expiresAt.subtract(_refreshMargin));

    return stillGood ? token : refreshToken();
  }

  @override
  Future<String> refreshAfter(String rejected) {
    // Someone already replaced it. A burst of 401s across the REST client and
    // the stream then costs one login between them, not one each — and we do
    // not throw away a token that is perfectly good.
    final current = _token;
    if (current != null && current != rejected) return Future.value(current);

    // Forget it *before* trying to replace it. The server has told us this
    // token is dead; our own clock still thinks it has 50 seconds left. If the
    // replacement then fails, whoever asks next must not be handed the corpse
    // — that buys a guaranteed 401 and a wasted round trip before every
    // subsequent retry.
    if (current == rejected) {
      _token = null;
      _expiresAt = null;
    }
    return refreshToken();
  }

  /// Unconditionally obtains a new token. Prefer [refreshAfter], which avoids
  /// a login when the token in hand has already been superseded.
  Future<String> refreshToken() {
    return _inFlightRefresh ??= _refresh().whenComplete(() {
      _inFlightRefresh = null;
    });
  }

  Future<String> _refresh() async {
    final username = _username;
    final password = _password;
    // Only reachable after a sign-out (or with nothing ever stored). Reporting
    // it as rejected credentials sends the user to the login screen, which is
    // the only thing that can fix it.
    if (username == null || password == null) {
      throw const InvalidCredentialsException();
    }

    final result = await _api.login(username: username, password: password);
    await _adopt(result);
    return result.token;
  }

  Future<void> _adopt(LoginResult result) async {
    _token = result.token;
    _expiresAt = _clock().add(result.expiresIn);
    try {
      await _store.write(
        StoredSession(
          username: _username!,
          password: _password!,
          token: result.token,
          expiresAt: _expiresAt!,
        ).encode(),
      );
    } on SecureStorageException {
      // Persistence is a convenience; losing it must not fail the sign-in.
    }
  }
}
