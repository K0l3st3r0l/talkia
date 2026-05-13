import 'package:flutter/material.dart';

class AppTheme {
  static const Color background = Color(0xFF0A0A0F);
  static const Color surface = Color(0xFF16161E);
  static const Color accent = Color(0xFF00D4FF);
  static const Color transmitColor = Color(0xFFFF4444);
  static const Color receiveColor = Color(0xFF00CC66);
  static const Color idleColor = Color(0xFF3A3A4A);
  static const Color textPrimary = Color(0xFFE8E8F0);
  static const Color textSecondary = Color(0xFF7A7A8A);

  static ThemeData get dark => ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: background,
        colorScheme: const ColorScheme.dark(
          primary: accent,
          surface: surface,
        ),
        fontFamily: 'monospace',
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: textPrimary),
          bodyMedium: TextStyle(color: textSecondary),
        ),
      );
}
