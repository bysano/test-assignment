
import 'pulse_native_platform_interface.dart';

class PulseNative {
  Future<String?> getPlatformVersion() {
    return PulseNativePlatform.instance.getPlatformVersion();
  }
}
