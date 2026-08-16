/// Runtime configuration.
///
/// The base URL is a compile-time define so the same build can point at a
/// simulator's `localhost`, a device's LAN address, or a test double:
///
/// ```
/// flutter run --dart-define=PULSE_BASE_URL=http://192.168.1.20:8080
/// ```
final class AppConfig {
  const AppConfig({required this.baseUrl});

  factory AppConfig.fromEnvironment() => AppConfig(
    baseUrl: Uri.parse(
      const String.fromEnvironment(
        'PULSE_BASE_URL',
        defaultValue: 'http://localhost:8080',
      ),
    ),
  );

  final Uri baseUrl;
}
