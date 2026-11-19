import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../app/theme/tokens.dart';

const _indigo = Color(0xFF5B3DF5);
const _violet = Color(0xFF7C3AED);

/// Calm, centred empty state: illustration, headline, short body, then up to two
/// actions. Used for the first-run library and "no search results".
class IllustratedEmptyState extends StatelessWidget {
  const IllustratedEmptyState({
    super.key,
    required this.art,
    required this.title,
    required this.body,
    this.primaryLabel,
    this.primaryIcon,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.extra,
  });

  final Widget art;
  final String title;
  final String body;
  final String? primaryLabel;
  final IconData? primaryIcon;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  /// Shown between the body text and the buttons (e.g. filter chips).
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 28, 12, 20),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(child: art),
              const SizedBox(height: 24),
              Semantics(
                header: true,
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  style: context.tt.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: context.tt.bodyMedium?.copyWith(
                  color: context.px.muted,
                  height: 1.45,
                ),
              ),
              if (extra != null) ...[const SizedBox(height: 20), extra!],
              if (primaryLabel != null) ...[
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: _indigo,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    onPressed: onPrimary,
                    icon: Icon(primaryIcon ?? Icons.document_scanner_rounded),
                    label: Text(primaryLabel!),
                  ),
                ),
              ],
              if (secondaryLabel != null) ...[
                SizedBox(height: primaryLabel != null ? 10 : 24),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: dark ? const Color(0xFFC9BFFF) : _indigo,
                      side: BorderSide(
                        color: dark
                            ? const Color(0x52B4A3FF)
                            : _indigo.withValues(alpha: 0.35),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    onPressed: onSecondary,
                    child: Text(secondaryLabel!),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A sheet of paper inside scan-frame corners, with a soft indigo halo.
class ScanEmptyArt extends StatelessWidget {
  const ScanEmptyArt({super.key, this.size = 168});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _ArtPainter(
        dark: Theme.of(context).brightness == Brightness.dark,
        search: false,
      ),
    ),
  );
}

/// A sheet of paper with a magnifying glass over it.
class SearchEmptyArt extends StatelessWidget {
  const SearchEmptyArt({super.key, this.size = 152});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(
      painter: _ArtPainter(
        dark: Theme.of(context).brightness == Brightness.dark,
        search: true,
      ),
    ),
  );
}

class _ArtPainter extends CustomPainter {
  _ArtPainter({required this.dark, required this.search});
  final bool dark, search;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final c = Offset(s / 2, s / 2);
    final accent = dark ? const Color(0xFF9D8BFF) : _indigo;
    final paper = dark ? const Color(0xFF1F2436) : Colors.white;
    final line = accent.withValues(alpha: dark ? 0.45 : 0.22);

    // Halo.
    canvas.drawCircle(
      c,
      s * 0.48,
      Paint()
        ..shader = RadialGradient(
          colors: [
            _indigo.withValues(alpha: dark ? 0.22 : 0.12),
            _indigo.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: c, radius: s * 0.48)),
    );

    // Paper, slightly tilted.
    canvas.save();
    canvas.translate(c.dx - (search ? s * 0.06 : 0), c.dy);
    canvas.rotate(-6 * math.pi / 180);
    final w = s * 0.42, h = s * 0.54;
    final sheet = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: w, height: h),
      Radius.circular(s * 0.04),
    );
    canvas.drawRRect(
      sheet.shift(Offset(0, s * 0.02)),
      Paint()
        ..color = Colors.black.withValues(alpha: dark ? 0.35 : 0.10)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, s * 0.03),
    );
    canvas.drawRRect(sheet, Paint()..color = paper);
    canvas.drawRRect(
      sheet,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = accent.withValues(alpha: dark ? 0.35 : 0.18),
    );
    // Text lines: a heading, then body lines.
    final left = -w / 2 + w * 0.16;
    canvas.drawLine(
      Offset(left, -h * 0.30),
      Offset(left + w * 0.40, -h * 0.30),
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = s * 0.028
        ..color = accent.withValues(alpha: dark ? 0.8 : 0.55),
    );
    final body = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * 0.016
      ..color = line;
    for (final (dy, len) in const [
      (-0.14, 0.68),
      (-0.03, 0.60),
      (0.08, 0.68),
      (0.19, 0.44),
    ]) {
      canvas.drawLine(
        Offset(left, h * dy),
        Offset(left + w * len, h * dy),
        body,
      );
    }
    canvas.restore();

    final frame = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.026
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = accent;

    if (!search) {
      // Scan-frame corners around the sheet.
      final r = Rect.fromCenter(center: c, width: s * 0.66, height: s * 0.78);
      final k = s * 0.11;
      for (final (corner, dx, dy) in [
        (r.topLeft, 1.0, 1.0),
        (r.topRight, -1.0, 1.0),
        (r.bottomRight, -1.0, -1.0),
        (r.bottomLeft, 1.0, -1.0),
      ]) {
        canvas.drawPath(
          Path()
            ..moveTo(corner.dx, corner.dy + dy * k)
            ..lineTo(corner.dx, corner.dy)
            ..lineTo(corner.dx + dx * k, corner.dy),
          frame,
        );
      }
      // Scan beam.
      final y = c.dy + s * 0.04;
      canvas.drawLine(
        Offset(r.left + s * 0.05, y),
        Offset(r.right - s * 0.05, y),
        Paint()
          ..strokeWidth = s * 0.014
          ..strokeCap = StrokeCap.round
          ..shader = LinearGradient(
            colors: [
              _indigo.withValues(alpha: 0),
              dark ? const Color(0xFFB4A3FF) : _violet,
              _indigo.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromLTWH(r.left, y - 2, r.width, 4)),
      );
    } else {
      // Magnifier over the lower-right of the sheet.
      final lc = Offset(c.dx + s * 0.13, c.dy + s * 0.08);
      final lr = s * 0.17;
      canvas.drawCircle(
        lc,
        lr,
        Paint()
          ..color = (dark ? const Color(0xFF151927) : Colors.white).withValues(
            alpha: 0.88,
          ),
      );
      canvas.drawCircle(lc, lr, frame);
      final dir = Offset(math.cos(math.pi / 4), math.sin(math.pi / 4));
      canvas.drawLine(
        lc + dir * (lr + s * 0.01),
        lc + dir * (lr + s * 0.15),
        Paint()
          ..strokeWidth = s * 0.05
          ..strokeCap = StrokeCap.round
          ..color = accent,
      );
      // "Nothing here": a short dash in the lens.
      canvas.drawLine(
        lc - Offset(lr * 0.4, 0),
        lc + Offset(lr * 0.4, 0),
        Paint()
          ..strokeWidth = s * 0.022
          ..strokeCap = StrokeCap.round
          ..color = accent.withValues(alpha: 0.7),
      );
    }
  }

  @override
  bool shouldRepaint(_ArtPainter old) =>
      old.dark != dark || old.search != search;
}
