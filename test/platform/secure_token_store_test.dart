import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pulse_native/pulse_native.dart';

/// Pins the Dart half of the MethodChannel contract: method names, argument
/// shape, and how platform errors surface. The Swift half is verified by
/// running the app; this is the part that can regress silently.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const store = MethodChannelSecureTokenStore();
  final calls = <MethodCall>[];

  void mockNative(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(MethodChannelSecureTokenStore.channel, (
      call,
    ) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);

  tearDown(() {
    messenger.setMockMethodCallHandler(
      MethodChannelSecureTokenStore.channel,
      null,
    );
  });

  group('MethodChannelSecureTokenStore', () {
    test('write sends the token under the agreed key', () async {
      mockNative((_) async => null);

      await store.write('abc123');

      expect(calls.single.method, 'write');
      expect(calls.single.arguments, {'token': 'abc123'});
    });

    test('read returns the stored token', () async {
      mockNative((_) async => 'abc123');

      expect(await store.read(), 'abc123');
      expect(calls.single.method, 'read');
    });

    test('read returns null when nothing is stored', () async {
      mockNative((_) async => null);

      expect(await store.read(), isNull);
    });

    test('delete invokes delete', () async {
      mockNative((_) async => null);

      await store.delete();

      expect(calls.single.method, 'delete');
    });

    // Callers should never need flutter/services just to catch a failure.
    test('translates a platform error into a package exception', () async {
      mockNative(
        (_) async => throw PlatformException(
          code: 'keychain_error',
          message: 'OSStatus -34018',
        ),
      );

      await expectLater(
        store.read(),
        throwsA(
          isA<SecureStorageException>()
              .having((e) => e.code, 'code', 'keychain_error')
              .having((e) => e.message, 'message', contains('-34018')),
        ),
      );
    });

    test('reports a missing plugin as unimplemented rather than crashing', () {
      // No mock handler registered at all.
      expect(
        store.read(),
        throwsA(
          isA<SecureStorageException>().having((e) => e.code, 'code', 'unimplemented'),
        ),
      );
    });
  });

  group('InMemorySecureTokenStore', () {
    test('round-trips and deletes', () async {
      final fallback = InMemorySecureTokenStore();

      expect(await fallback.read(), isNull);
      await fallback.write('abc');
      expect(await fallback.read(), 'abc');
      await fallback.delete();
      expect(await fallback.read(), isNull);
    });
  });
}
