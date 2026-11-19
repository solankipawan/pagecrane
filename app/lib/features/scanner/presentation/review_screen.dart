import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../documents/data/documents_provider.dart';
import '../domain/filters.dart';
import '../domain/scan_session.dart';
import 'capture_sheet.dart';

/// Review captured pages: filter, rotate, reorder, delete, add more, save.
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  final _pager = PageController();
  int _index = 0;
  bool _applyAll = false;

  static const _filterIcons = {
    ScanFilter.original: Icons.image_outlined,
    ScanFilter.magic: Icons.auto_awesome_rounded,
    ScanFilter.gray: Icons.contrast_rounded,
    ScanFilter.bw: Icons.text_snippet_outlined,
    ScanFilter.photo: Icons.wb_sunny_outlined,
  };

  @override
  void dispose() {
    _pager.dispose();
    super.dispose();
  }

  void _goTo(int i) {
    setState(() => _index = i);
    _pager.animateToPage(
      i,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  Future<bool> _confirmDiscard() async {
    final pages = ref.read(scanSessionProvider);
    if (pages.isEmpty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Discard this scan?'),
        content: Text('${plural(pages.length, 'page')} not saved yet.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Keep'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok ?? false) ref.read(scanSessionProvider.notifier).clear();
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final pages = ref.watch(scanSessionProvider);
    final session = ref.read(scanSessionProvider.notifier);
    if (pages.isEmpty) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.document_scanner_rounded,
          title: 'No pages',
          body: 'Add a page to get started.',
        ),
      );
    }
    final i = _index.clamp(0, pages.length - 1);
    final page = pages[i];
    final px = context.px;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmDiscard() && context.mounted) context.pop();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Back',
            icon: const Icon(Icons.chevron_left_rounded, size: 30),
            onPressed: () async {
              if (await _confirmDiscard() && context.mounted) context.pop();
            },
          ),
          title: Text('Page ${i + 1} of ${pages.length}'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                onPressed: () => _openSave(context),
                child: const Text('Save'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pager,
                itemCount: pages.length,
                onPageChanged: (v) {
                  Haptics.select();
                  setState(() => _index = v);
                },
                itemBuilder: (context, k) {
                  final p = pages[k];
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(28, 8, 28, 8),
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        child: p.preview == null
                            ? const SizedBox(
                                key: ValueKey('busy'),
                                width: 36,
                                height: 36,
                                child: CircularProgressIndicator(),
                              )
                            : DecoratedBox(
                                key: ValueKey(p.preview.hashCode),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x40000000),
                                      blurRadius: 40,
                                      offset: Offset(0, 12),
                                    ),
                                  ],
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.memory(
                                    p.preview!,
                                    gaplessPlayback: true,
                                    semanticLabel: 'Page ${k + 1}',
                                  ),
                                ),
                              ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // Filters
            SizedBox(
              height: 52,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                children: [
                  for (final f in ScanFilter.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        avatar: Icon(
                          _filterIcons[f],
                          size: 16,
                          color: page.filter == f ? context.cs.onPrimary : null,
                        ),
                        label: Text(f.label),
                        selected: page.filter == f,
                        onSelected: (_) {
                          Haptics.select();
                          session.setFilter(i, f, all: _applyAll);
                        },
                      ),
                    ),
                ],
              ),
            ),
            // Page strip (long-press + drag to reorder)
            SizedBox(
              height: 92,
              child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                itemCount: pages.length,
                onReorderItem: (a, b) {
                  Haptics.light();
                  session.reorder(a, b);
                  setState(() => _index = b);
                  _pager.jumpToPage(b);
                },
                itemBuilder: (context, k) {
                  final p = pages[k];
                  return Padding(
                    key: ValueKey(p.id),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    child: GestureDetector(
                      onTap: () => _goTo(k),
                      child: Stack(
                        children: [
                          Container(
                            width: 52,
                            height: 70,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: k == i
                                    ? context.cs.primary
                                    : px.hairline,
                                width: 2,
                              ),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: p.preview == null
                                ? null
                                : Image.memory(
                                    p.preview!,
                                    fit: BoxFit.cover,
                                    cacheWidth: 160,
                                    gaplessPlayback: true,
                                  ),
                          ),
                          Positioned(
                            left: 4,
                            bottom: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0x99000000),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '${k + 1}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            // Actions
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: px.hairline)),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    _Action(
                      icon: Icons.rotate_right_rounded,
                      label: 'Rotate',
                      onTap: () {
                        Haptics.select();
                        session.rotate(i);
                      },
                    ),
                    _Action(
                      icon: Icons.library_add_check_outlined,
                      label: 'Apply to all',
                      active: _applyAll,
                      onTap: () {
                        Haptics.select();
                        setState(() => _applyAll = !_applyAll);
                        if (_applyAll) {
                          session.setFilter(i, page.filter, all: true);
                        }
                      },
                    ),
                    _Action(
                      icon: Icons.add_rounded,
                      label: 'Add page',
                      onTap: () => startScan(context, ref),
                    ),
                    _Action(
                      icon: Icons.delete_outline_rounded,
                      label: 'Delete',
                      color: px.danger,
                      onTap: () {
                        Haptics.medium();
                        session.removeAt(i);
                        if (pages.length == 1) context.pop();
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openSave(BuildContext context) async {
    final name = TextEditingController(text: 'Scan ${fmtDay(DateTime.now())}');
    final docs = ref.read(documentsProvider).value ?? const [];
    final folders = {'Scans', ...docs.map((d) => d.folder)}.toList();
    var folder = 'Scans';
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (c) => StatefulBuilder(
        builder: (c, setSheet) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            MediaQuery.viewInsetsOf(c).bottom +
                MediaQuery.paddingOf(c).bottom +
                16, // keyboard + home indicator
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Save document', style: c.tt.titleLarge),
              const SizedBox(height: 4),
              Text(
                '${plural(ref.read(scanSessionProvider).length, 'page')} · PDF · stored on this device',
                style: c.tt.bodySmall,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final f in folders)
                    ChoiceChip(
                      label: Text(f),
                      selected: f == folder,
                      onSelected: (_) => setSheet(() => folder = f),
                    ),
                ],
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => Navigator.pop(c, true),
                icon: const Icon(Icons.check_rounded),
                label: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !context.mounted) return;

    final progress = ValueNotifier<double>(0);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: ValueListenableBuilder(
              valueListenable: progress,
              builder: (_, v, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(value: v == 0 ? null : v),
                  const SizedBox(height: 16),
                  const Text('Building PDF…'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    final session = ref.read(scanSessionProvider.notifier);
    final rendered = await session.renderAll(
      onProgress: (v) => progress.value = v * 0.9,
    );
    final title = name.text.trim().isEmpty
        ? 'Scan ${fmtDay(DateTime.now())}'
        : name.text.trim();
    final doc = await ref
        .read(documentsProvider.notifier)
        .add(name: title, folder: folder, pages: rendered);
    session.clear();
    Haptics.success();
    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // progress
    context.go('/');
    showToast(
      context,
      'Saved · ${plural(doc.pageCount, 'page')} · ${fmtSize(doc.sizeBytes)}',
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.color,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = active ? context.cs.primary : (color ?? context.cs.onSurface);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: c),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: active ? c : context.px.muted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
