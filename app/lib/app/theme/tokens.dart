import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

/// Design tokens — mirror docs/ARCHITECTURE.md §4 and prototype/styles.css.
abstract final class Brand {
  static const primaryLight = Color(0xFF4C5BFF);
  static const primaryDark = Color(0xFF8A94FF);
  static const primary2 = Color(0xFF7C5CFF);
  static const bgLight = Color(0xFFF3F4F9);
  static const bgDark = Color(0xFF0A0C12);
  static const textLight = Color(0xFF0E1120);
  static const textDark = Color(0xFFF2F3F8);
}

abstract final class Radii {
  static const chip = 12.0;
  static const card = 20.0;
  static const sheet = 28.0;
}

/// Colors Material's ColorScheme has no slot for: tool categories + glass.
@immutable
class PdfitColors extends ThemeExtension<PdfitColors> {
  const PdfitColors({
    required this.scan,
    required this.pdf,
    required this.image,
    required this.convert,
    required this.success,
    required this.danger,
    required this.muted,
    required this.surface,
    required this.surfaceStrong,
    required this.glassBorder,
    required this.hairline,
    required this.auroraA,
    required this.auroraB,
    required this.auroraC,
    required this.blur,
  });

  final Color scan, pdf, image, convert, success, danger, muted;
  final Color surface, surfaceStrong, glassBorder, hairline;
  final Color auroraA, auroraB, auroraC;
  final double blur;

  static const light = PdfitColors(
    scan: Color(0xFF0D9488),
    pdf: Color(0xFFE11D48),
    image: Color(0xFF7C3AED),
    convert: Color(0xFFD97706),
    success: Color(0xFF16A34A),
    danger: Color(0xFFDC2626),
    muted: Color(0xFF5A6077),
    surface: Color(0xADFFFFFF), // 68 %
    surfaceStrong: Color(0xEBFFFFFF),
    glassBorder: Color(0xBFFFFFFF),
    hairline: Color(0x140E1120),
    auroraA: Color(0x474C5BFF),
    auroraB: Color(0x337C3AED),
    auroraC: Color(0x2E0D9488),
    blur: 24,
  );

  static const dark = PdfitColors(
    scan: Color(0xFF2DD4BF),
    pdf: Color(0xFFFB7185),
    image: Color(0xFFA78BFA),
    convert: Color(0xFFFBBF24),
    success: Color(0xFF4ADE80),
    danger: Color(0xFFF87171),
    muted: Color(0xFF9CA2B6),
    surface: Color(0x8C1E212E), // 55 %
    surfaceStrong: Color(0xF0242736),
    glassBorder: Color(0x14FFFFFF),
    hairline: Color(0x14FFFFFF),
    auroraA: Color(0x4D4C5BFF),
    auroraB: Color(0x387C3AED),
    auroraC: Color(0x290D9488),
    blur: 24,
  );

  @override
  PdfitColors copyWith({
    Color? scan,
    Color? pdf,
    Color? image,
    Color? convert,
  }) => PdfitColors(
    scan: scan ?? this.scan,
    pdf: pdf ?? this.pdf,
    image: image ?? this.image,
    convert: convert ?? this.convert,
    success: success,
    danger: danger,
    muted: muted,
    surface: surface,
    surfaceStrong: surfaceStrong,
    glassBorder: glassBorder,
    hairline: hairline,
    auroraA: auroraA,
    auroraB: auroraB,
    auroraC: auroraC,
    blur: blur,
  );

  @override
  PdfitColors lerp(PdfitColors? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return PdfitColors(
      scan: c(scan, other.scan),
      pdf: c(pdf, other.pdf),
      image: c(image, other.image),
      convert: c(convert, other.convert),
      success: c(success, other.success),
      danger: c(danger, other.danger),
      muted: c(muted, other.muted),
      surface: c(surface, other.surface),
      surfaceStrong: c(surfaceStrong, other.surfaceStrong),
      glassBorder: c(glassBorder, other.glassBorder),
      hairline: c(hairline, other.hairline),
      auroraA: c(auroraA, other.auroraA),
      auroraB: c(auroraB, other.auroraB),
      auroraC: c(auroraC, other.auroraC),
      blur: lerpDouble(blur, other.blur, t)!,
    );
  }
}

/// Tool categories → color.
enum ToolCategory { scan, pdf, image, convert }

extension PdfitTheme on BuildContext {
  PdfitColors get px => Theme.of(this).extension<PdfitColors>()!;
  ColorScheme get cs => Theme.of(this).colorScheme;
  TextTheme get tt => Theme.of(this).textTheme;

  Color categoryColor(ToolCategory c) => switch (c) {
    ToolCategory.scan => px.scan,
    ToolCategory.pdf => px.pdf,
    ToolCategory.image => px.image,
    ToolCategory.convert => px.convert,
  };
}
