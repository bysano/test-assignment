import 'dart:convert';

/// What we persist in the platform's secure storage.
///
/// Two things travel together, and both are needed:
///
/// * **The token and its expiry.** The expiry comes along because a token
///   alone is unusable — with a 60s TTL a restored token is more often dead
///   than alive, and firing a doomed request to discover that is a worse
///   start than checking a clock.
///
/// * **The credentials.** This server issues no refresh token, so the only
///   way to renew a 60s token across a cold start is to still hold the
///   credentials. Without them a restored session would expire a minute after
///   launch and dump the user at the login screen having never typed
///   anything. Storing a password is exactly the case the Keychain exists
///   for; the tradeoff is written up in NOTES.md.
final class StoredSession {
  const StoredSession({
    required this.username,
    required this.password,
    required this.token,
    required this.expiresAt,
  });

  final String username;
  final String password;
  final String token;
  final DateTime expiresAt;

  String encode() => jsonEncode({
    'username': username,
    'password': password,
    'token': token,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  });

  static StoredSession? tryParse(String raw) {
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map) return null;

      final username = json['username'];
      final password = json['password'];
      final token = json['token'];
      final expiresAt = json['expiresAt'];
      if (username is! String || username.isEmpty) return null;
      if (password is! String) return null;
      if (token is! String || token.isEmpty) return null;
      if (expiresAt is! String) return null;

      final parsed = DateTime.tryParse(expiresAt);
      if (parsed == null) return null;

      return StoredSession(
        username: username,
        password: password,
        token: token,
        expiresAt: parsed,
      );
    } on FormatException {
      return null;
    }
  }
}
