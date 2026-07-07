import 'package:flutter/material.dart';

/// Marketing/version string for the 1.1 line. Keep in sync with pubspec.yaml.
const kLumenVersion = '1.1.13';

/// Aurora — the Lumen 1.1 design language.
///
/// A 10-foot-first system that borrows the best of the big three:
/// - Apple TV's calm, white-forward focus model and generous type,
/// - Netflix's content-density and billboard hero,
/// - Prime Video's clear top navigation and information hierarchy.
///
/// Principles:
/// - **Content is the color.** Chrome is near-black glass; the artwork glows.
/// - **Focus is white.** One focus language everywhere: a white ring, a gentle
///   lift, a soft shadow. Accents are reserved for state (progress, live).
/// - **No real blur in scroll paths.** Android TV GPUs choke on BackdropFilter,
///   so "glass" is layered translucency + hairlines — indistinguishable at
///   couch distance, buttery on a $30 box.
class Aurora {
  Aurora._();

  // ---- Palette -------------------------------------------------------------
  static const bg = Color(0xFF06070B); // near-black, cool undertone
  static const bgRaised = Color(0xFF0D0F16); // dialogs / panels
  static const glass = Color(0x14FFFFFF); // 8% white — resting surface
  static const glassHi = Color(0x24FFFFFF); // 14% white — hovered/active
  static const hairline = Color(0x1CFFFFFF); // 11% white — borders
  static const scrim = Color(0xB306070B); // 70% bg — over art

  static const text = Color(0xFFF3F5F9);
  static const textDim = Color(0xFFA7ADBC);
  static const textFaint = Color(0xFF636A7C);

  static const accent = Color(0xFF4CC2FF); // ice cyan
  static const accentAlt = Color(0xFF8A7BFF); // violet partner
  static const live = Color(0xFFFF4E45);
  static const good = Color(0xFF34D399);

  /// The brand gradient — used very sparingly (wordmark, progress fills,
  /// the experience gate) so it stays special.
  static const gradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [accent, accentAlt],
  );

  // ---- Motion --------------------------------------------------------------
  static const fast = Duration(milliseconds: 140);
  static const normal = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 420);
  static const curve = Curves.easeOutCubic;

  // ---- Layout --------------------------------------------------------------
  /// Horizontal page gutter. Scales down on narrow (phone) layouts.
  static double margin(BuildContext context) =>
      MediaQuery.of(context).size.width >= 900 ? 48.0 : 20.0;

  /// Base card width for poster shelves, clamped for phones.
  static double posterWidth(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return (w / 7.2).clamp(104.0, 158.0);
  }

  /// Base card width for wide (16:9) shelves.
  static double wideWidth(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    return (w / 4.4).clamp(196.0, 300.0);
  }

  // ---- Type ----------------------------------------------------------------
  static const display = TextStyle(
    fontSize: 42,
    fontWeight: FontWeight.w800,
    height: 1.02,
    letterSpacing: -1.2,
    color: text,
  );
  static const title = TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w800,
    letterSpacing: -0.4,
    color: text,
  );
  static const shelfTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: text,
  );
  static const body = TextStyle(
    fontSize: 13.5,
    height: 1.5,
    color: textDim,
  );
  static const label = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    color: text,
  );
  static const caption = TextStyle(
    fontSize: 11.5,
    color: textFaint,
  );

  // ---- ThemeData -----------------------------------------------------------
  static ThemeData theme() {
    final base = ThemeData.dark(useMaterial3: true);
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(
      surface: bgRaised,
      surfaceContainerHighest: const Color(0xFF161925),
      primary: accent,
    );
    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      splashFactory: NoSplash.splashFactory, // ripples feel dated on TV
      highlightColor: Colors.transparent,
      textTheme: base.textTheme.apply(
        bodyColor: text,
        displayColor: text,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: bgRaised,
        contentTextStyle: const TextStyle(color: text, fontSize: 13.5),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: hairline),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: const BorderSide(color: hairline),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: glass,
        hintStyle: const TextStyle(color: textFaint),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Colors.white, width: 1.6),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: bg,
          textStyle: const TextStyle(fontWeight: FontWeight.w700),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
      ),
    );
  }
}
