import 'package:flutter/material.dart';

/// Colours the whole app agrees on for "the price moved" and "the connection
/// is in state X". Defined once so the badge, the banner and the row flash
/// cannot drift apart.
abstract final class PulseColors {
  static const Color up = Color(0xFF26A65B);
  static const Color down = Color(0xFFD8453E);

  static const Color live = Color(0xFF26A65B);
  static const Color warning = Color(0xFFE0A03A);
  static const Color danger = Color(0xFFD8453E);
  static const Color idle = Color(0xFF7A8290);
}

ThemeData buildPulseTheme() {
  final base = ThemeData.dark(useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: const Color(0xFF12151A),
    appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1A1E25)),
    colorScheme: base.colorScheme.copyWith(
      primary: PulseColors.live,
      surface: const Color(0xFF12151A),
    ),
    textTheme: base.textTheme.apply(fontFamily: 'SF Pro Text'),
    // Material 3 would pair the green primary with its own dark-purple
    // onPrimary, which is unreadable on it.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: PulseColors.live,
        foregroundColor: Colors.white,
      ),
    ),
  );
}

/// Tabular figures, so a price does not shuffle sideways as its digits change.
/// Without this every tick nudges the column and the list looks unstable even
/// when it is behaving perfectly.
const TextStyle kPriceStyle = TextStyle(
  fontFeatures: [FontFeature.tabularFigures()],
  fontSize: 15,
  fontWeight: FontWeight.w600,
);
