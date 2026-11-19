import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// Builds light/dark ThemeData from the Pagecrane tokens.
/// On Android 12+ the app may pass a wallpaper-derived [dynamicPrimary]
/// (Material You). Category colors stay fixed so tool groups stay recognisable.
ThemeData buildTheme(Brightness brightness, {Color? dynamicPrimary}) {
  final dark = brightness == Brightness.dark;
  final primary =
      dynamicPrimary ?? (dark ? Brand.primaryDark : Brand.primaryLight);
  final bg = dark ? Brand.bgDark : Brand.bgLight;
  final text = dark ? Brand.textDark : Brand.textLight;
  final px = dark ? PdfitColors.dark : PdfitColors.light;

  final scheme =
      ColorScheme.fromSeed(seedColor: primary, brightness: brightness).copyWith(
        primary: primary,
        onPrimary: dark ? const Color(0xFF0B0D14) : Colors.white,
        surface: bg,
        onSurface: text,
        error: px.danger,
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    // SF Pro on iOS / Roboto on Android come from the platform default.
    splashFactory: InkSparkle.splashFactory,
    extensions: [px],
  );

  final tt = base.textTheme.apply(bodyColor: text, displayColor: text);
  return base.copyWith(
    textTheme: tt.copyWith(
      headlineLarge: tt.headlineLarge?.copyWith(
        fontSize: 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.6,
      ),
      titleLarge: tt.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
      ),
      titleMedium: tt.titleMedium?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: tt.bodyMedium?.copyWith(fontSize: 15),
      bodySmall: tt.bodySmall?.copyWith(fontSize: 13, color: px.muted),
      labelSmall: tt.labelSmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.8,
        color: px.muted,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: true,
      foregroundColor: text,
      systemOverlayStyle: dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
    ),
    // Solid selected segment: the default pale tint vanished over the aurora glow
    // (Files' All/Starred/Folders read as if the wrong tab was selected).
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.primary
              : px.surfaceStrong,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.onPrimary : text,
        ),
        textStyle: WidgetStateProperty.resolveWith(
          (s) => TextStyle(
            fontSize: 14,
            fontWeight: s.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        ),
        side: WidgetStatePropertyAll(BorderSide(color: px.glassBorder)),
        minimumSize: const WidgetStatePropertyAll(Size(0, 44)),
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.chip),
      ),
      side: BorderSide.none,
      backgroundColor: px.hairline,
      selectedColor: primary,
      labelStyle: TextStyle(color: text, fontWeight: FontWeight.w500),
      secondaryLabelStyle: TextStyle(
        color: scheme.onPrimary,
        fontWeight: FontWeight.w600,
      ),
      showCheckmark: false,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: px.surfaceStrong,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.sheet)),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: px.hairline,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: const Color(0xE0141620),
      contentTextStyle: const TextStyle(
        color: Colors.white,
        fontWeight: FontWeight.w500,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    // Page transitions: platform defaults (Cupertino slide on iOS, predictive back on Android).
  );
}
