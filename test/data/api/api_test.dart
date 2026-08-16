import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pulse/data/api/api_exception.dart';
import 'package:pulse/data/api/auth_api.dart';
import 'package:pulse/data/api/instruments_api.dart';

final _baseUrl = Uri.parse('http://localhost:8080');

void main() {
  group('AuthApi', () {
    test('returns the token and TTL', () async {
      final api = AuthApi(
        baseUrl: _baseUrl,
        client: MockClient((request) async {
          expect(request.url.path, '/login');
          expect(jsonDecode(request.body), {
            'username': 'trader',
            'password': 'password123',
          });
          return http.Response('{"token":"abc","expiresIn":60}', 200);
        }),
      );

      final result = await api.login(
        username: 'trader',
        password: 'password123',
      );

      expect(result.token, 'abc');
      expect(result.expiresIn, const Duration(seconds: 60));
    });

    test('throws InvalidCredentialsException on 401', () {
      final api = AuthApi(
        baseUrl: _baseUrl,
        client: MockClient(
          (_) async => http.Response('{"error":"invalid credentials"}', 401),
        ),
      );

      expect(
        () => api.login(username: 'trader', password: 'wrong'),
        throwsA(isA<InvalidCredentialsException>()),
      );
    });

    test('defaults the TTL when the server omits it', () async {
      final api = AuthApi(
        baseUrl: _baseUrl,
        client: MockClient((_) async => http.Response('{"token":"abc"}', 200)),
      );

      final result = await api.login(
        username: 'trader',
        password: 'password123',
      );

      expect(result.expiresIn, const Duration(seconds: 60));
    });

    test('throws when the response carries no token', () {
      final api = AuthApi(
        baseUrl: _baseUrl,
        client: MockClient((_) async => http.Response('{"expiresIn":60}', 200)),
      );

      expect(
        () => api.login(username: 'trader', password: 'password123'),
        throwsA(isA<ApiException>()),
      );
    });
  });

  group('InstrumentsApi', () {
    const body = '''
[{"symbol":"EURUSD","name":"Euro / US Dollar","decimals":5},
 {"symbol":"JPN225","name":"Nikkei 225","decimals":0}]''';

    test('parses instruments', () async {
      final api = InstrumentsApi(
        baseUrl: _baseUrl,
        // No token here: AuthenticatedClient attaches it upstream.
        client: MockClient((_) async => http.Response(body, 200)),
      );

      final instruments = await api.fetch();

      expect(instruments, hasLength(2));
      expect(instruments.first.symbol, 'EURUSD');
      expect(instruments.first.decimals, 5);
      expect(instruments.last.decimals, 0);
    });

    test('throws UnauthorizedException on 401', () {
      final api = InstrumentsApi(
        baseUrl: _baseUrl,
        client: MockClient((_) async => http.Response('', 401)),
      );

      expect(() => api.fetch(), throwsA(isA<UnauthorizedException>()));
    });

    // One malformed row should not cost the user the other thirty-nine.
    test('skips unparseable entries but keeps the rest', () async {
      final api = InstrumentsApi(
        baseUrl: _baseUrl,
        client: MockClient(
          (_) async => http.Response(
            '[{"symbol":"EURUSD","name":"Euro","decimals":5},'
            '{"name":"no symbol","decimals":2},'
            '{"symbol":"BAD","name":"bad decimals","decimals":"five"}]',
            200,
          ),
        ),
      );

      final instruments = await api.fetch();

      expect(instruments.map((i) => i.symbol), ['EURUSD']);
    });

    test('throws when nothing in the list is usable', () {
      final api = InstrumentsApi(
        baseUrl: _baseUrl,
        client: MockClient((_) async => http.Response('[{"nope":1}]', 200)),
      );

      expect(() => api.fetch(), throwsA(isA<ApiException>()));
    });
  });
}
