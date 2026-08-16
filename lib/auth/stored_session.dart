import 'dart:convert';

/// What we persist in the platform's secure storage.
///
/// The expiry travels with the token because a token alone is unusable: with a
/// 60s TTL, a restored token is far more often expired than not, and firing a
/// doomed request to find that out is a worse start than checking a clock.
final class StoredSession {
  const StoredSession({required this.token, required this.expiresAt});

  final String token;
  final DateTime expiresAt;

  String encode() => jsonEncode({
    'token': token,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  });

  static StoredSession? tryParse(String raw) {
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map) return null;
      final token = json['token'];
      final expiresAt = json['expiresAt'];
      if (token is! String || token.isEmpty || expiresAt is! String) return null;
      final parsed = DateTime.tryParse(expiresAt);
      if (parsed == null) return null;
      return StoredSession(token: token, expiresAt: parsed);
    } on FormatException {
      return null;
    }
  }
}
