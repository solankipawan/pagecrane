import 'dart:ui';

import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// Marks a subtree whose glass sits only on the static [AuroraBackground] (the tab
/// pages, see AppShell). Blurring a smooth gradient gives back the same gradient, so
/// [GlassSurface]s in here skip the backdrop blur: same look, no blur work. Measured on
/// an Android emulator, the blur cost ~150–200 ms before the first frame (5 extra GPU
/// shaders compiled on every launch) plus a blur pass per card on every frame.
class FlatGlassScope extends InheritedWidget {
  const FlatGlassScope({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FlatGlassScope>() != null;

  @override
  bool updateShouldNotify(FlatGlassScope oldWidget) => false;
}

/// Liquid-glass surface: backdrop blur + translucent fill + specular top edge.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = Radii.card,
    this.padding,
    this.strong = false,
    this.blur = true,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final bool strong;

  /// False draws only the translucent fill. Ignored (always off) in a [FlatGlassScope].
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final px = context.px;
    final r = BorderRadius.circular(radius);
    final fill = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: strong ? px.surfaceStrong : px.surface,
        borderRadius: r,
        border: Border.all(color: px.glassBorder),
      ),
      child: child,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).brightness == Brightness.dark
                ? const Color(0x73000000)
                : const Color(0x1A14183C),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: blur && !FlatGlassScope.of(context)
            ? BackdropFilter(
                filter: ImageFilter.blur(sigmaX: px.blur, sigmaY: px.blur),
                child: fill,
              )
            : fill,
      ),
    );
  }
}

/// [GlassSurface] whose blur switches on just after the app's first frame, so the blur
/// shaders compile after the UI is already on screen instead of delaying it. Used for
/// the tab bar: at launch nothing has scrolled under it yet, so it looks the same.
class DeferredGlassSurface extends StatefulWidget {
  const DeferredGlassSurface({
    super.key,
    required this.child,
    this.radius = Radii.card,
  });
  final Widget child;
  final double radius;

  @override
  State<DeferredGlassSurface> createState() => _DeferredGlassSurfaceState();
}

class _DeferredGlassSurfaceState extends State<DeferredGlassSurface> {
  bool _blur = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _blur = true);
    });
  }

  @override
  Widget build(BuildContext context) =>
      GlassSurface(radius: widget.radius, blur: _blur, child: widget.child);
}

/// Soft aurora blobs painted behind the whole app.
///
/// Each blob is a radial gradient shaped like a disc blurred with σ≈60. That looks the
/// same as blurring solid discs, but costs nothing per frame: a full-screen σ60
/// [ImageFiltered] used to be re-run on every repaint and was the main startup/jank cost
/// on Android GPUs. The [RepaintBoundary] keeps scrolling from repainting it at all.
class AuroraBackground extends StatelessWidget {
  const AuroraBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final px = context.px;
    return Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: ColoredBox(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: LayoutBuilder(
                builder: (context, box) {
                  // Same placement as Align(a, child: disc of size w×h), but the gradient
                  // box is bigger than the disc, so it is positioned by its centre.
                  Widget blob(Alignment a, double w, double h, Color c) {
                    final cx = (box.maxWidth - w) * (a.x + 1) / 2 + w / 2;
                    final cy = (box.maxHeight - h) * (a.y + 1) / 2 + h / 2;
                    final d =
                        (w + h) / 2 + 300; // disc + ~2.5σ falloff each side
                    return Positioned(
                      left: cx - d / 2,
                      top: cy - d / 2,
                      width: d,
                      height: d,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            colors: [
                              c,
                              c.withValues(alpha: c.a * 0.85),
                              c.withValues(alpha: c.a * 0.5),
                              c.withValues(alpha: c.a * 0.12),
                              c.withValues(alpha: 0),
                            ],
                            stops: const [0, 0.25, 0.46, 0.75, 1],
                          ),
                        ),
                      ),
                    );
                  }

                  return Stack(
                    children: [
                      blob(const Alignment(-0.9, -1.0), 300, 260, px.auroraA),
                      blob(const Alignment(1.1, -0.55), 260, 240, px.auroraB),
                      blob(const Alignment(-0.2, 0.9), 260, 220, px.auroraC),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
        child,
      ],
    );
  }
}
