import 'package:material_ui/material_ui.dart';

import '../../app/theme/tokens.dart';

/// Scales down slightly while pressed (0.96) — the press feedback used app-wide.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _down = true),
        onTapCancel: () => setState(() => _down = false),
        onTapUp: (_) => setState(() => _down = false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _down ? 0.96 : 1,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOutCubic,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Shimmering placeholder block for skeleton loaders.
class Skeleton extends StatefulWidget {
  const Skeleton({
    super.key,
    required this.width,
    required this.height,
    this.radius = 8,
  });
  final double width, height, radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = context.px.hairline;
    final hi = Theme.of(context).brightness == Brightness.dark
        ? const Color(0x1FFFFFFF)
        : const Color(0x80FFFFFF);
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value * 3 - 1;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              begin: Alignment(t - 1, 0),
              end: Alignment(t + 1, 0),
              colors: [base, hi, base],
            ),
          ),
        );
      },
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 24, 0, 10),
    child: Row(
      children: [
        Expanded(child: Text(text.toUpperCase(), style: context.tt.labelSmall)),
        ?trailing,
      ],
    ),
  );
}

/// Rounded tinted square holding a category icon.
class ToolIcon extends StatelessWidget {
  const ToolIcon(this.icon, this.color, {super.key, this.size = 44});
  final IconData icon;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.14),
      borderRadius: BorderRadius.circular(size * 0.32),
    ),
    child: Icon(icon, color: color, size: size * 0.5),
  );
}

void showToast(
  BuildContext context,
  String msg, {
  IconData icon = Icons.check_circle_rounded,
}) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(
    SnackBar(
      content: Row(
        children: [
          Icon(icon, color: const Color(0xFF4ADE80), size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(msg, overflow: TextOverflow.ellipsis)),
        ],
      ),
      duration: const Duration(milliseconds: 2400),
    ),
  );
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
  });
  final IconData icon;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
    child: Column(
      children: [
        Icon(icon, size: 40, color: context.cs.primary),
        const SizedBox(height: 12),
        Text(title, style: context.tt.titleMedium, textAlign: TextAlign.center),
        if (body != null) ...[
          const SizedBox(height: 4),
          Text(body!, style: context.tt.bodySmall, textAlign: TextAlign.center),
        ],
      ],
    ),
  );
}
