import 'package:flutter/material.dart';

import 'app.dart';
import 'core/frame_stats.dart';
import 'di/injection.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  configureDependencies();
  FrameStats.start(); // no-op unless --dart-define=PULSE_FRAME_STATS=true
  runApp(const PulseApp());
}
