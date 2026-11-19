import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/glass.dart';
import '../../app/theme/tokens.dart';
import '../../core/haptics.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/creator_footer.dart';
import '../scanner/domain/filters.dart';
import 'settings_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    final n = ref.read(settingsProvider.notifier);
    final px = context.px;

    Widget row(
      IconData icon,
      Color c,
      String title,
      String sub, {
      Widget? trailing,
      bool divider = true,
    }) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        border: divider ? Border(bottom: BorderSide(color: px.hairline)) : null,
      ),
      child: Row(
        children: [
          ToolIcon(icon, c, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.tt.titleMedium),
                Text(sub, style: context.tt.bodySmall),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );

    return ListView(
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.paddingOf(context).top + 12,
        20,
        140,
      ),
      children: [
        Text('Settings', style: context.tt.headlineLarge),
        const SectionLabel('Appearance'),
        SegmentedButton<ThemeMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ThemeMode.system, label: Text('System')),
            ButtonSegment(value: ThemeMode.light, label: Text('Light')),
            ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
          ],
          selected: {s.theme},
          onSelectionChanged: (v) {
            Haptics.select();
            n.setTheme(v.first);
          },
        ),
        const SectionLabel('Scanner'),
        GlassSurface(
          child: Column(
            children: [
              row(
                Icons.vibration_rounded,
                px.image,
                'Haptic feedback',
                'Ticks on capture, save and selection',
                trailing: Switch.adaptive(
                  value: s.haptics,
                  onChanged: n.setHaptics,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ToolIcon(
                          Icons.auto_awesome_rounded,
                          px.convert,
                          size: 36,
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Default filter',
                              style: context.tt.titleMedium,
                            ),
                            Text(
                              'Applied to new pages',
                              style: context.tt.bodySmall,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final f in ScanFilter.values)
                          ChoiceChip(
                            label: Text(f.label),
                            selected: s.defaultFilter == f,
                            onSelected: (_) {
                              Haptics.select();
                              n.setDefaultFilter(f);
                            },
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SectionLabel('Privacy'),
        GlassSurface(
          child: Column(
            children: [
              row(
                Icons.shield_rounded,
                px.scan,
                'On-device only',
                'No account, no uploads. Files leave only when you share them.',
              ),
              row(
                Icons.lock_rounded,
                px.pdf,
                'Secure Vault',
                'Face ID / fingerprint + AES-256 · coming soon',
                divider: false,
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const CreatorFooter(),
        Center(child: Text('Pagecrane 0.1.0', style: context.tt.bodySmall)),
      ],
    );
  }
}
