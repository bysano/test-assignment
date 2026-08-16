import 'package:flutter/services.dart';

/// Something went wrong talking to the platform's secure storage.
///
/// Deliberately a package-level type: callers should not have to import
/// `flutter/services.dart` to catch a [PlatformException].
final class SecureStorageException implements Exception {
  const SecureStorageException(this.code, this.message);

  final String code;
  final String? message;

  @override
  String toString() => 'SecureStorageException($code): $message';
}

/// Persists the auth token in whatever secure store the platform provides.
///
/// Platform-agnostic on purpose. Nothing here mentions Keychain, and nothing
/// above here knows which platform is answering.
abstract interface class SecureTokenStore {
  Future<void> write(String token);

  /// The stored token, or null if there is none.
  Future<String?> read();

  Future<void> delete();
}

/// Talks to the native side over a [MethodChannel].
///
/// iOS backs this with the Keychain. An Android implementation would answer
/// the same three method names on the same channel with EncryptedSharedPrefs;
/// no Dart above this file would change.
class MethodChannelSecureTokenStore implements SecureTokenStore {
  const MethodChannelSecureTokenStore();

  static const MethodChannel channel = MethodChannel('pulse/secure_token_store');

  @override
  Future<void> write(String token) =>
      _guard(() => channel.invokeMethod<void>('write', {'token': token}));

  @override
  Future<String?> read() => _guard(() => channel.invokeMethod<String>('read'));

  @override
  Future<void> delete() => _guard(() => channel.invokeMethod<void>('delete'));

  Future<T?> _guard<T>(Future<T?> Function() call) async {
    try {
      return await call();
    } on PlatformException catch (error) {
      throw SecureStorageException(error.code, error.message);
    } on MissingPluginException {
      throw const SecureStorageException(
        'unimplemented',
        'No secure storage on this platform',
      );
    }
  }
}

/// Fallback for platforms with no native implementation yet.
///
/// NOT secure — it keeps the token in process memory and loses it on restart.
/// It exists so the app still runs (and the tests still pass) somewhere other
/// than iOS, and so a missing platform is an obvious downgrade rather than a
/// crash.
class InMemorySecureTokenStore implements SecureTokenStore {
  String? _token;

  @override
  Future<void> write(String token) async => _token = token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> delete() async => _token = null;
}
