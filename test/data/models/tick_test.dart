import 'package:flutter_test/flutter_test.dart';
import 'package:pulse/data/models/tick.dart';

void main() {
  group('Tick.tryParse', () {
    test('parses a well-formed payload', () {
      final tick = Tick.tryParse(
        1042,
        '{"s":"EURUSD","b":1.08123,"a":1.08141,"ts":1752912000123}',
      );

      expect(tick, isNotNull);
      expect(tick!.id, 1042);
      expect(tick.symbol, 'EURUSD');
      expect(tick.bid, 1.08123);
      expect(tick.ask, 1.08141);
      expect(tick.ts, 1752912000123);
    });

    // JSON has no int/double distinction, so a whole-number price such as
    // JPN225's 41190 arrives as an int and must not be rejected.
    test('accepts integral prices', () {
      final tick = Tick.tryParse(1, '{"s":"JPN225","b":41190,"a":41192,"ts":5}');

      expect(tick, isNotNull);
      expect(tick!.bid, 41190.0);
      expect(tick.ask, 41192.0);
    });

    test('returns null for the feed\'s garbage payload', () {
      expect(Tick.tryParse(1, '###garbage-not-json###'), isNull);
    });

    test('returns null for valid JSON of the wrong shape', () {
      expect(Tick.tryParse(1, '[1,2,3]'), isNull);
      expect(Tick.tryParse(1, '"a string"'), isNull);
      expect(Tick.tryParse(1, 'null'), isNull);
    });

    test('returns null when a field is missing or mistyped', () {
      expect(Tick.tryParse(1, '{"b":1.0,"a":1.1,"ts":5}'), isNull);
      expect(Tick.tryParse(1, '{"s":"X","a":1.1,"ts":5}'), isNull);
      expect(Tick.tryParse(1, '{"s":"X","b":1.0,"a":1.1}'), isNull);
      expect(Tick.tryParse(1, '{"s":"X","b":"1.0","a":1.1,"ts":5}'), isNull);
      expect(Tick.tryParse(1, '{"s":42,"b":1.0,"a":1.1,"ts":5}'), isNull);
    });

    test('returns null for an empty symbol', () {
      expect(Tick.tryParse(1, '{"s":"","b":1.0,"a":1.1,"ts":5}'), isNull);
    });

    test('returns null for a truncated payload', () {
      expect(Tick.tryParse(1, '{"s":"EURUSD","b":1.08'), isNull);
    });
  });
}
