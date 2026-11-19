import 'package:material_ui/material_ui.dart';

import '../../app/theme/tokens.dart';

const _indigo = Color(0xFF5B3DF5);
const _violet = Color(0xFF7C3AED);

bool _dark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

BoxDecoration _card(BuildContext context) => BoxDecoration(
  color: _dark(context) ? const Color(0xFF161A26) : Colors.white,
  borderRadius: BorderRadius.circular(24),
  border: Border.all(color: context.px.hairline),
  boxShadow: [
    BoxShadow(
      color: _dark(context) ? const Color(0x66000000) : const Color(0x1414183C),
      blurRadius: 28,
      offset: const Offset(0, 10),
    ),
  ],
);

/// A permission request card: icon, headline, why, then the fix and an alternative.
class PermissionCard extends StatelessWidget {
  const PermissionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.primaryIcon,
    this.secondaryLabel,
    this.onSecondary,
    this.tertiaryLabel,
    this.onTertiary,
  });

  final IconData icon;
  final String title, body, primaryLabel;
  final IconData? primaryIcon;
  final VoidCallback onPrimary;
  final String? secondaryLabel, tertiaryLabel;
  final VoidCallback? onSecondary, onTertiary;

  @override
  Widget build(BuildContext context) {
    final dark = _dark(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 380),
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
      decoration: _card(context),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _indigo.withValues(alpha: dark ? 0.22 : 0.10),
            ),
            child: Icon(
              icon,
              size: 34,
              color: dark ? const Color(0xFFB4A3FF) : _indigo,
            ),
          ),
          const SizedBox(height: 18),
          Semantics(
            header: true,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: context.tt.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
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
          const SizedBox(height: 22),
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
              icon: Icon(primaryIcon ?? Icons.settings_rounded),
              label: Text(primaryLabel),
            ),
          ),
          if (secondaryLabel != null) ...[
            const SizedBox(height: 10),
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
          if (tertiaryLabel != null) ...[
            const SizedBox(height: 4),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: context.px.muted,
                minimumSize: const Size(0, 44),
              ),
              onPressed: onTertiary,
              child: Text(tertiaryLabel!),
            ),
          ],
        ],
      ),
    );
  }
}

/// Calm error card: warm amber tint, coral accent, dark readable text, and the
/// actions that fix it. Not a red alarm; the user can always recover.
class IssueCard extends StatelessWidget {
  const IssueCard({
    super.key,
    required this.title,
    required this.reason,
    this.icon = Icons.lock_outline_rounded,
    this.primaryLabel,
    this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
    this.onDismiss,
  });

  final String title, reason;
  final IconData icon;
  final String? primaryLabel, secondaryLabel;
  final VoidCallback? onPrimary, onSecondary, onDismiss;

  @override
  Widget build(BuildContext context) {
    final dark = _dark(context);
    final bg = dark ? const Color(0xFF2A1D16) : const Color(0xFFFFF7ED);
    final border = dark ? const Color(0x66F59E0B) : const Color(0xFFFCD9A8);
    final coral = dark ? const Color(0xFFFF8A7A) : const Color(0xFFDC2626);
    final titleColor = dark ? const Color(0xFFFFD7CF) : const Color(0xFF7F1D1D);
    final textColor = dark ? const Color(0xFFE9E1DA) : const Color(0xFF44372C);
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: coral.withValues(alpha: dark ? 0.18 : 0.12),
                  ),
                  child: Icon(icon, color: coral, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          reason,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 14,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (onDismiss != null)
                  IconButton(
                    tooltip: 'Dismiss',
                    onPressed: onDismiss,
                    icon: Icon(Icons.close_rounded, color: textColor),
                  ),
              ],
            ),
            if (primaryLabel != null || secondaryLabel != null) ...[
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(left: 52, right: 8),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (primaryLabel != null)
                      FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: dark
                              ? const Color(0xFFFF8A7A)
                              : const Color(0xFFC81E1E),
                          foregroundColor: dark
                              ? const Color(0xFF2A0F0A)
                              : Colors.white,
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: onPrimary,
                        child: Text(primaryLabel!),
                      ),
                    if (secondaryLabel != null)
                      OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: titleColor,
                          side: BorderSide(color: border),
                          minimumSize: const Size(0, 44),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: onSecondary,
                        child: Text(secondaryLabel!),
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Progress for a multi-step job: ring + bar, a plain-language step, a tabular
/// percentage, and a safe Cancel. [value] null = preparing (indeterminate).
class ProgressCard extends StatelessWidget {
  const ProgressCard({
    super.key,
    required this.title,
    required this.value,
    this.detail,
    this.onCancel,
  });

  final String title;
  final String? detail;
  final double? value;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final dark = _dark(context);
    final v = value;
    final pct = v == null ? null : (v * 100).clamp(0, 100).floor();
    final track = _indigo.withValues(alpha: dark ? 0.25 : 0.14);
    final accent = dark ? const Color(0xFF9D8BFF) : _indigo;
    return Semantics(
      liveRegion: true,
      label: pct == null ? title : '$title $pct percent',
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        decoration: _card(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                SizedBox.square(
                  dimension: 40,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      CircularProgressIndicator(
                        value: v,
                        strokeWidth: 4,
                        strokeCap: StrokeCap.round,
                        color: accent,
                        backgroundColor: track,
                      ),
                      Icon(Icons.layers_rounded, size: 18, color: accent),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.tt.titleMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      if (detail != null)
                        Text(
                          detail!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.tt.bodySmall,
                        ),
                    ],
                  ),
                ),
                if (pct != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text(
                      '$pct%',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: dark ? Colors.white : const Color(0xFF141726),
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                if (onCancel != null)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(64, 44),
                      foregroundColor: dark ? const Color(0xFFC9BFFF) : _indigo,
                    ),
                    onPressed: onCancel,
                    child: const Text('Cancel'),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: SizedBox(
                  height: 8,
                  child: v == null
                      ? LinearProgressIndicator(
                          color: accent,
                          backgroundColor: track,
                        )
                      : Stack(
                          children: [
                            Positioned.fill(child: ColoredBox(color: track)),
                            Positioned.fill(
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: v.clamp(0.0, 1.0),
                                heightFactor: 1,
                                child: const DecoratedBox(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [_indigo, _violet],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
