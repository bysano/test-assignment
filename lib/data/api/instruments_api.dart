import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/instrument.dart';
import 'api_exception.dart';

/// `GET /instruments`.
class InstrumentsApi {
  InstrumentsApi({
    required Uri baseUrl,
    required http.Client client,
    Duration timeout = const Duration(seconds: 10),
  }) : _baseUrl = baseUrl,
       _client = client,
       _timeout = timeout;

  final Uri _baseUrl;
  final http.Client _client;
  final Duration _timeout;

  Future<List<Instrument>> fetch(String token) async {
    final response = await _client
        .get(
          _baseUrl.resolve('/instruments'),
          headers: {'authorization': 'Bearer $token'},
        )
        .timeout(_timeout);

    if (response.statusCode == 401) throw const UnauthorizedException();
    if (response.statusCode != 200) {
      throw ApiException(response.statusCode, response.body);
    }

    final Object? json = jsonDecode(response.body);
    if (json is! List) throw ApiException(200, 'malformed instruments response');

    // Skip unparseable entries rather than failing the whole list: one bad
    // instrument should not cost the user the other thirty-nine.
    final instruments = json
        .map(Instrument.tryParse)
        .nonNulls
        .toList(growable: false);
    if (instruments.isEmpty) throw ApiException(200, 'no usable instruments');
    return instruments;
  }
}
