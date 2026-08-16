import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../../core/errors/api_exception.dart';

/// What `/login` hands back. Deliberately *not* an absolute expiry: turning
/// the server's relative TTL into a deadline is the repository's job, so the
/// clock stays injectable and testable.
final class LoginResult {
  const LoginResult({required this.token, required this.expiresIn});

  final String token;
  final Duration expiresIn;
}

/// `POST /login`.
class AuthApi {
  AuthApi({
    required Uri baseUrl,
    required http.Client client,
    Duration timeout = const Duration(seconds: 10),
  }) : _baseUrl = baseUrl,
       _client = client,
       _timeout = timeout;

  final Uri _baseUrl;
  final http.Client _client;
  final Duration _timeout;

  Future<LoginResult> login({
    required String username,
    required String password,
  }) async {
    final response = await _client
        .post(
          _baseUrl.resolve('/login'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'username': username, 'password': password}),
        )
        .timeout(_timeout);

    if (response.statusCode == 401) throw const InvalidCredentialsException();
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, response.body);
    }

    final Object? json = jsonDecode(response.body);
    if (json is! Map) throw ApiException(200, 'malformed login response');
    final token = json['token'];
    final expiresIn = json['expiresIn'];
    if (token is! String || token.isEmpty) {
      throw ApiException(200, 'login response has no token');
    }

    return LoginResult(
      token: token,
      // Fall back to the documented 60s rather than failing the login if the
      // server ever omits or mistypes the TTL.
      expiresIn: Duration(seconds: expiresIn is num ? expiresIn.toInt() : 60),
    );
  }
}
