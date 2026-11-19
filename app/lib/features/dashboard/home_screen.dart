import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/glass.dart';
import '../../app/theme/tokens.dart';
import '../../core/format.dart';
import '../../core/haptics.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/creator_footer.dart';
import '../../core/widgets/empty_states.dart';
import '../documents/data/documents_provider.dart';
import '../documents/data/stored_doc.dart';
import '../documents/presentation/doc_tile.dart';
import '../scanner/presentation/capture_sheet.dart';
import '../settings/settings_provider.dart';
import '../tools/tool_catalog.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docsAsync = ref.watch(documentsProvider);
    final docs = docsAsync.value ?? const <StoredDoc>[];
    final dark = Theme.of(context).brightness == Brightness.dark;
    final recent = docs.take(4).toList();
    // First run: no documents yet. Keep it calm: one clear next step.
    final firstRun = docsAsync is AsyncData && docs.isEmpty;

    return RefreshIndicator(
      onRefresh: () => ref.refresh(documentsProvider.future),
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          MediaQuery.paddingOf(context).top + 12,
          20,
          140,
        ),
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      greetingFor(DateTime.now()),
                      style: context.tt.bodySmall,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        ClipRRect(
                          // iOS-style corner radius ≈ 22 % of the side.
                          borderRadius: BorderRadius.circular(7),
                          child: Image.asset(
                            'assets/brand/icon.png',
                            width: 32,
                            height: 32,
                            cacheWidth:
                                96, // decode at 3× display size, not 256 px
                            excludeFromSemantics: true,
                          ),
                        ),
                        const SizedBox(width: 10),
                        // Shrinks rather than overflows on narrow phones / large text.
                        Flexible(
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Pagecrane',
                              style: context.tt.headlineLarge,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              GlassSurface(
                radius: 22,
                child: IconButton(
                  tooltip: dark ? 'Light mode' : 'Dark mode',
                  icon: Icon(
                    dark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
                  ),
                  onPressed: () {
                    Haptics.select();
                    ref
                        .read(settingsProvider.notifier)
                        .setTheme(dark ? ThemeMode.light : ThemeMode.dark);
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Pressable(
            onTap: () => context.go('/files'),
            semanticLabel: 'Search documents',
            child: GlassSurface(
              radius: 16,
              child: SizedBox(
                height: 48,
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    Icon(Icons.search_rounded, color: context.px.muted),
                    const SizedBox(width: 10),
                    Text(
                      'Search documents',
                      style: TextStyle(color: context.px.muted, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (firstRun)
            IllustratedEmptyState(
              art: const ScanEmptyArt(),
              title: 'No documents scanned yet',
              body: 'Scan receipts, notes, or IDs into crisp PDFs right on your device.',
              primaryLabel: 'Scan First Document',
              onPrimary: () => startScan(context, ref),
            )
          else
            _Hero(docs: docs, onScan: () => startScan(context, ref)),
          const SectionLabel('Quick tools'),
          GridView.count(
            crossAxisCount: 4,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 0.86,
            children: [
              for (final id in quickTools)
                Pressable(
                  onTap: () => openTool(context, ref, tools[id]!),
                  semanticLabel: tools[id]!.name,
                  child: GlassSurface(
                    radius: 18,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        ToolIcon(
                          tools[id]!.icon,
                          context.categoryColor(tools[id]!.cat),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          tools[id]!.label,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          if (!firstRun) ...[
            SectionLabel(
              'Recent',
              trailing: TextButton(
                onPressed: () => context.go('/files'),
                child: const Text('See all'),
              ),
            ),
            GlassSurface(
              child: switch (docsAsync) {
                AsyncData() when docs.isEmpty => const EmptyState(
                  icon: Icons.document_scanner_rounded,
                  title: 'No documents yet',
                  body: 'Tap the scan button to capture your first page.',
                ),
                AsyncData() => Column(
                  children: [
                    for (final (i, d) in recent.indexed)
                      DocTile(d, showDivider: i < recent.length - 1),
                  ],
                ),
                AsyncError(:final error) => EmptyState(
                  icon: Icons.error_outline_rounded,
                  title: 'Could not load library',
                  body: '$error',
                ),
                _ => const Column(
                  children: [_SkeletonRow(), _SkeletonRow(), _SkeletonRow()],
                ),
              },
            ),
            const SectionLabel('Storage'),
            _StorageCard(docs: docs),
          ],
          const CreatorFooter(),
        ],
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  const _Hero({required this.docs, required this.onScan});
  final List<StoredDoc> docs;
  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final pages = docs.fold(0, (a, d) => a + d.pageCount);
    final bytes = docs.fold(0, (a, d) => a + d.sizeBytes);
    Widget stat(String v, String l) => Expanded(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: const Color(0x24FFFFFF),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FittedBox(
              child: Text(
                v,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            Text(
              l,
              style: const TextStyle(color: Color(0xCCFFFFFF), fontSize: 12),
            ),
          ],
        ),
      ),
    );
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4C5BFF), Color(0xFF7C5CFF), Color(0xFFB15CFF)],
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x594C5BFF),
            blurRadius: 40,
            offset: Offset(0, 16),
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Scan to PDF',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 21,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Auto edge-detect, batch pages, on-device.',
                      style: TextStyle(color: Color(0xD9FFFFFF), fontSize: 14),
                    ),
                  ],
                ),
              ),
              Pressable(
                onTap: onScan,
                semanticLabel: 'Scan',
                child: Container(
                  height: 40,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: const Color(0x38FFFFFF),
                    borderRadius: BorderRadius.circular(99),
                    border: Border.all(color: const Color(0x59FFFFFF)),
                  ),
                  child: const Row(
                    children: [
                      Icon(
                        Icons.document_scanner_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Scan',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              stat('${docs.length}', 'Documents'),
              const SizedBox(width: 8),
              stat('$pages', 'Pages'),
              const SizedBox(width: 8),
              stat(fmtSize(bytes), 'On device'),
            ],
          ),
        ],
      ),
    );
  }
}

class _SkeletonRow extends StatelessWidget {
  const _SkeletonRow();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    child: Row(
      children: [
        Skeleton(width: 42, height: 54),
        SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Skeleton(width: 170, height: 12),
            SizedBox(height: 8),
            Skeleton(width: 110, height: 10),
          ],
        ),
      ],
    ),
  );
}

class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.docs});
  final List<StoredDoc> docs;

  @override
  Widget build(BuildContext context) {
    final px = context.px;
    final total = docs.fold(0, (a, d) => a + d.sizeBytes);
    final starred = docs
        .where((d) => d.starred)
        .fold(0, (a, d) => a + d.sizeBytes);
    final rest = total - starred;
    return GlassSurface(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Used by Pagecrane · on device',
                  style: context.tt.bodyMedium,
                ),
              ),
              Text(fmtSize(total), style: context.tt.titleLarge),
            ],
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: SizedBox(
              height: 10,
              child: total == 0
                  ? ColoredBox(color: px.hairline)
                  : Row(
                      children: [
                        if (starred > 0)
                          Expanded(
                            flex: starred,
                            child: ColoredBox(color: px.convert),
                          ),
                        if (rest > 0)
                          Expanded(
                            flex: rest,
                            child: ColoredBox(color: px.scan),
                          ),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${plural(docs.length, 'document')} · nothing is uploaded',
            style: context.tt.bodySmall,
          ),
        ],
      ),
    );
  }
}
