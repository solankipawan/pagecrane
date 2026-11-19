import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/haptics.dart';
import '../domain/doc_detect.dart' show Pt;
import '../domain/page_pipeline.dart';

const _indigo = Color(0xFF5B3DF5);

/// Opens the corner editor on [original]. Returns the chosen corners (normalised
/// TL TR BR BL), `(corners: null)` for "use the whole photo", or null if cancelled.
Future<({List<Pt>? corners})?> openCropEditor(
  BuildContext context, {
  required Uint8List original,
  required List<Pt>? corners,
}) => Navigator.of(context, rootNavigator: true).push(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => CropScreen(original: original, corners: corners),
  ),
);

const _whole = <Pt>[(0, 0), (1, 0), (1, 1), (0, 1)];

/// Drag the four corners onto the page edges. A magnifier shows the corner under
/// your finger; handles are 48 pt targets; the outline can't be twisted.
class CropScreen extends StatefulWidget {
  const CropScreen({super.key, required this.original, required this.corners});
  final Uint8List original;
  final List<Pt>? corners;

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  ui.Image? _image;
  late List<Offset> _c = [
    for (final (x, y) in widget.corners ?? _whole) Offset(x, y),
  ];
  int? _drag;
  bool _detecting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final codec = await ui.instantiateImageCodec(
      widget.original,
      targetWidth: 1600,
    );
    final frame = await codec.getNextFrame();
    if (mounted) {
      setState(() => _image = frame.image);
    } else {
      frame.image.dispose();
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  bool _isWhole() => _c.every(
    (p) =>
        (p.dx.abs() < 0.002 || (p.dx - 1).abs() < 0.002) &&
        (p.dy.abs() < 0.002 || (p.dy - 1).abs() < 0.002),
  );

  /// Convex and not collapsed (each turn spans a real area on screen).
  bool _convex(List<Offset> q, Size s) {
    var sign = 0;
    for (var i = 0; i < 4; i++) {
      final o = q[i].scale(s.width, s.height),
          a = q[(i + 1) % 4].scale(s.width, s.height),
          b = q[(i + 2) % 4].scale(s.width, s.height);
      final c = (a.dx - o.dx) * (b.dy - a.dy) - (a.dy - o.dy) * (b.dx - a.dx);
      if (c.abs() < 400) return false;
      final sg = c > 0 ? 1 : -1;
      if (sign == 0) {
        sign = sg;
      } else if (sg != sign) {
        return false;
      }
    }
    return true;
  }

  Future<void> _autoDetect() async {
    setState(() => _detecting = true);
    final found = await compute(detectCorners, widget.original);
    if (!mounted) return;
    setState(() {
      _detecting = false;
      if (found != null) _c = [for (final (x, y) in found) Offset(x, y)];
    });
    Haptics.select();
    if (found == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No page edges found. Drag the corners.')),
      );
    }
  }

  void _apply() {
    Haptics.success();
    Navigator.pop(context, (
      corners: _isWhole()
          ? null
          : [for (final p in _c) (p.dx.clamp(0.0, 1.0), p.dy.clamp(0.0, 1.0))],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF0D0F17),
        appBar: AppBar(
          backgroundColor: const Color(0xFF0D0F17),
          foregroundColor: Colors.white,
          systemOverlayStyle: SystemUiOverlayStyle.light,
          title: const Text('Adjust corners'),
          leading: IconButton(
            tooltip: 'Cancel',
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.pop(context),
          ),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: _indigo,
                  minimumSize: const Size(0, 40),
                ),
                onPressed: image == null ? null : _apply,
                child: const Text('Apply'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  'Drag each corner onto a corner of the page.',
                  style: TextStyle(color: Color(0xB3FFFFFF), fontSize: 13),
                ),
              ),
              Expanded(
                child: image == null
                    ? const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      )
                    : LayoutBuilder(
                        builder: (context, box) {
                          // Photo inset by 28 pt so edge handles stay grabbable.
                          const pad = 28.0;
                          final ar = image.width / image.height;
                          var w = box.maxWidth - 2 * pad, h = w / ar;
                          if (h > box.maxHeight - 2 * pad) {
                            h = box.maxHeight - 2 * pad;
                            w = h * ar;
                          }
                          final rect = Rect.fromLTWH(
                            (box.maxWidth - w) / 2,
                            (box.maxHeight - h) / 2,
                            w,
                            h,
                          );
                          return _editor(image, rect);
                        },
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: _BarButton(
                        icon: Icons.auto_fix_high_rounded,
                        label: 'Auto detect',
                        busy: _detecting,
                        onTap: image == null || _detecting ? null : _autoDetect,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _BarButton(
                        icon: Icons.crop_free_rounded,
                        label: 'Whole photo',
                        onTap: image == null
                            ? null
                            : () {
                                Haptics.select();
                                setState(
                                  () => _c = [
                                    for (final (x, y) in _whole) Offset(x, y),
                                  ],
                                );
                              },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _editor(ui.Image image, Rect rect) {
    final size = rect.size;
    Offset toPx(Offset n) =>
        rect.topLeft + Offset(n.dx * size.width, n.dy * size.height);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (d) {
        // Nearest corner within reach of the finger.
        var best = -1;
        var bestD = 48.0;
        for (var i = 0; i < 4; i++) {
          final dist = (toPx(_c[i]) - d.localPosition).distance;
          if (dist < bestD) {
            bestD = dist;
            best = i;
          }
        }
        if (best < 0) return;
        Haptics.select();
        setState(() => _drag = best);
      },
      onPanUpdate: (d) {
        final i = _drag;
        if (i == null) return;
        final next = [..._c];
        final p =
            next[i] + Offset(d.delta.dx / size.width, d.delta.dy / size.height);
        next[i] = Offset(p.dx.clamp(0.0, 1.0), p.dy.clamp(0.0, 1.0));
        if (!_convex(next, size)) return;
        setState(() => _c = next);
      },
      onPanEnd: (_) => setState(() => _drag = null),
      onPanCancel: () => setState(() => _drag = null),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fromRect(
            rect: rect,
            child: RawImage(image: image, fit: BoxFit.fill),
          ),
          Positioned.fromRect(
            rect: rect,
            child: CustomPaint(
              painter: _CropPainter([
                for (final c in _c)
                  Offset(c.dx * size.width, c.dy * size.height),
              ], _drag),
            ),
          ),
          if (_drag != null) _loupe(image, toPx(_c[_drag!]), size),
        ],
      ),
    );
  }

  /// Magnifier floating above (or below, near the top) the dragged corner so the
  /// finger doesn't hide what's being lined up.
  /// Shows the photo itself (not the handle) zoomed 2.5× around the corner, with a
  /// crosshair, so the corner can be placed exactly on the page edge.
  Widget _loupe(ui.Image image, Offset corner, Size shown) {
    const d = 112.0, lift = 100.0;
    final dy = corner.dy - lift - d / 2 > -40 ? -lift : lift;
    return Positioned(
      left: corner.dx - d / 2,
      top: corner.dy + dy - d / 2,
      child: IgnorePointer(
        child: Container(
          width: d,
          height: d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [
              BoxShadow(color: Color(0x80000000), blurRadius: 12),
            ],
          ),
          child: ClipOval(
            child: CustomPaint(
              painter: _LoupePainter(
                image: image,
                at: _c[_drag!],
                quad: _c,
                // Photo px → loupe px: on-screen scale × 2.5.
                scale: shown.width / image.width * 2.5,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoupePainter extends CustomPainter {
  _LoupePainter({
    required this.image,
    required this.at,
    required this.quad,
    required this.scale,
  });
  final ui.Image image;
  final Offset at; // normalised
  final List<Offset> quad; // normalised
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(scale);
    canvas.translate(-at.dx * image.width, -at.dy * image.height);
    canvas.drawImage(
      image,
      Offset.zero,
      Paint()..filterQuality = FilterQuality.medium,
    );
    canvas.drawPath(
      Path()..addPolygon([
        for (final q in quad) Offset(q.dx * image.width, q.dy * image.height),
      ], true),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 / scale
        ..color = const Color(0xFF7C3AED),
    );
    canvas.restore();
    final cross = Paint()
      ..strokeWidth = 1.5
      ..color = _indigo;
    canvas.drawLine(c - const Offset(10, 0), c + const Offset(10, 0), cross);
    canvas.drawLine(c - const Offset(0, 10), c + const Offset(0, 10), cross);
  }

  @override
  bool shouldRepaint(_LoupePainter old) =>
      old.at != at || old.scale != scale || old.image != image;
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.pts, this.active);
  final List<Offset> pts;
  final int? active;

  @override
  void paint(Canvas canvas, Size size) {
    final quad = Path()..addPolygon(pts, true);
    // Dim everything outside the page.
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        quad,
      ),
      Paint()..color = const Color(0x8C000000),
    );
    canvas.drawPath(
      quad,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFF7C3AED),
    );
    for (var i = 0; i < 4; i++) {
      final p = pts[i];
      final on = i == active;
      canvas.drawCircle(
        p,
        on ? 17 : 14,
        Paint()..color = const Color(0x477C3AED),
      );
      canvas.drawCircle(p, on ? 11 : 10, Paint()..color = Colors.white);
      canvas.drawCircle(
        p,
        on ? 9 : 8.5,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = _indigo,
      );
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.active != active ||
      List.generate(4, (i) => old.pts[i] != pts[i]).any((x) => x);
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.busy = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    style: OutlinedButton.styleFrom(
      foregroundColor: Colors.white,
      side: const BorderSide(color: Color(0x40FFFFFF)),
      minimumSize: const Size(0, 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    onPressed: onTap,
    icon: busy
        ? const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          )
        : Icon(icon, size: 20),
    label: Text(label),
  );
}
