import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/theme/tokens.dart';
import '../haptics.dart';
import 'common.dart';

/// One-line, highlighted maker credit that opens Instagram:
/// "♥ Built with love by @theairsolanki" inside a softly tinted, bordered pill.
///
/// Same footer as TrainPulse (CreatorFooterView.swift): the whole pill is the link
/// (44 pt tall target), it never wraps onto a second line, gives a light haptic on tap,
/// and does one soft heartbeat when it appears (skipped with Reduce Motion).
class CreatorFooter extends StatefulWidget {
  const CreatorFooter({super.key, this.handle = 'theairsolanki'});
  final String handle;

  @override
  State<CreatorFooter> createState() => _CreatorFooterState();
}

class _CreatorFooterState extends State<CreatorFooter>
    with SingleTickerProviderStateMixin {
  late final _beat = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  );
  late final _scale = TweenSequence<double>([
    TweenSequenceItem(
      tween: Tween(
        begin: 1.0,
        end: 1.12,
      ).chain(CurveTween(curve: Curves.easeOutBack)),
      weight: 45,
    ),
    TweenSequenceItem(
      tween: Tween(
        begin: 1.12,
        end: 1.0,
      ).chain(CurveTween(curve: Curves.easeOut)),
      weight: 55,
    ),
  ]).animate(_beat);
  bool _started = false;

  Uri get _url => Uri.parse('https://instagram.com/${widget.handle}');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (MediaQuery.disableAnimationsOf(context)) return;
    Future.delayed(const Duration(milliseconds: 200), () {
      if (mounted) _beat.forward();
    });
  }

  @override
  void dispose() {
    _beat.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    Haptics.light();
    await launchUrl(_url, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.cs.primary;
    const accentDeep = Brand.primary2;
    final small = context.tt.bodySmall?.fontSize ?? 13;

    Widget gradient(
      Widget child,
      List<Color> colors, {
      bool vertical = false,
    }) => ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (r) => LinearGradient(
        colors: colors,
        begin: vertical ? Alignment.topCenter : Alignment.centerLeft,
        end: vertical ? Alignment.bottomCenter : Alignment.centerRight,
      ).createShader(r),
      child: child,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 24, bottom: 8),
      child: Center(
        child: Semantics(
          link: true,
          button: true,
          label: 'Built with love by ${widget.handle}. Opens Instagram.',
          excludeSemantics: true,
          child: Pressable(
            onTap: _open,
            child: Container(
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: ShapeDecoration(
                color: accent.withValues(alpha: 0.12),
                shape: StadiumBorder(
                  side: BorderSide(color: accent.withValues(alpha: 0.25)),
                ),
              ),
              child: FittedBox(
                // Never wraps: scales down a little instead (minimumScaleFactor ≈ 0.85).
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ScaleTransition(
                      scale: _scale,
                      child: gradient(
                        Icon(Icons.favorite_rounded, size: small + 2),
                        const [Color(0xFFFF4F7B), Color(0xFFFF2D55)],
                        vertical: true,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'Built with love by',
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: small,
                        fontWeight: FontWeight.w500,
                        color: context.px.muted,
                      ),
                    ),
                    const SizedBox(width: 6),
                    gradient(
                      Text(
                        '@${widget.handle}',
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: small,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      [accent, accentDeep],
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.arrow_outward_rounded,
                      size: small - 1,
                      color: accent.withValues(alpha: 0.8),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
