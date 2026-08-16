import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

/// Prints frame build and raster percentiles every few seconds.
///
/// The brief says frame times will be watched in DevTools during a burst, so
/// this exists to make that measurable from the command line too — run in
/// profile mode with:
///
/// ```
/// flutter run --profile --dart-define=PULSE_FRAME_STATS=true
/// ```
///
/// Off unless that define is set, so it costs nothing in a normal build.
abstract final class FrameStats {
  static const bool enabled = bool.fromEnvironment('PULSE_FRAME_STATS');

  static final List<int> _buildMicros = [];
  static final List<int> _rasterMicros = [];
  static int _reportedUpTo = 0;

  static void start() {
    if (!enabled) return;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  static void _onTimings(List<FrameTiming> timings) {
    for (final timing in timings) {
      _buildMicros.add(timing.buildDuration.inMicroseconds);
      _rasterMicros.add(timing.rasterDuration.inMicroseconds);
    }
    // Report every ~5s at 60fps, without needing a clock.
    if (_buildMicros.length - _reportedUpTo < 300) return;
    _reportedUpTo = _buildMicros.length;
    _report();
  }

  static void _report() {
    final build = List.of(_buildMicros)..sort();
    final raster = List.of(_rasterMicros)..sort();
    final jank = _buildMicros.indexed
        .where((e) => e.$2 + _rasterMicros[e.$1] > 16667)
        .length;

    debugPrint(
      '[pulse.frames] frames=${build.length} '
      'build p50=${_ms(build, 0.50)} p95=${_ms(build, 0.95)} p99=${_ms(build, 0.99)} '
      'raster p50=${_ms(raster, 0.50)} p95=${_ms(raster, 0.95)} p99=${_ms(raster, 0.99)} '
      'over16.7ms=$jank',
    );
  }

  static String _ms(List<int> sorted, double percentile) {
    if (sorted.isEmpty) return '-';
    final index = ((sorted.length - 1) * percentile).round();
    return '${(sorted[index] / 1000).toStringAsFixed(2)}ms';
  }
}
