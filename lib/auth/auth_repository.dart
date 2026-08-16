import 'dart:async';

import 'package:pulse_native/pulse_native.dart';

import '../data/api/api_exception.dart';
import '../data/api/auth_api.dart';
import '../feed/feed_connection.dart';
import 'stored_session.dart';

/// Owns the token's whole life: obtaining it, keeping it fresh, persisting it
/// to the platform's secure store, and handing it to the feed on demand.
///
/// Implements [FeedTokenProvider], so the feed can refresh a token behind the
/// user's back without knowing anything about logins or the Keychain.
class AuthRepository implements FeedTokenProvider {
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

  bool get hasSession => _token != null;

  /// Restores a still-valid session from secure storage.
  ///
  /// Returns false — never throws — when there is nothing usable. A Keychain
  /// that misbehaves should cost the user a login prompt, not a crash.
  Future<bool> restore() async {
    try {
      final raw = await _store.read();
      if (raw == null) return false;

      final session = StoredSession.tryParse(raw);
      if (session == null || !_clock().isBefore(session.expiresAt)) {
        await _store.delete();
        return false;
      }
      _token = session.token;
      _expiresAt = session.expiresAt;
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
    // Held in memory only, so the feed can re-authenticate for the rest of the
    // session. Deliberately not persisted — see NOTES.md.
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
  Future<String> refreshToken() {
    return _inFlightRefresh ??= _refresh().whenComplete(() {
      _inFlightRefresh = null;
    });
  }

  Future<String> _refresh() async {
    final username = _username;
    final password = _password;
    // A restored session has a token but no credentials: we can use what we
    // have until it expires, but we cannot mint a new one. Surfacing this as
    // rejected credentials sends the user to the login screen, which is the
    // only thing that can actually fix it.
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
        StoredSession(token: result.token, expiresAt: _expiresAt!).encode(),
      );
    } on SecureStorageException {
      // Persistence is a convenience; losing it must not fail the sign-in.
    }
  }
}
