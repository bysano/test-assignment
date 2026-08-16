import 'package:flutter/material.dart';

import 'app/app.dart';
import 'app/di/injection.dart';
import 'core/diagnostics/frame_stats.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  configureDependencies();
  FrameStats.start(); // no-op unless --dart-define=PULSE_FRAME_STATS=true
  runApp(const PulseApp());
}
