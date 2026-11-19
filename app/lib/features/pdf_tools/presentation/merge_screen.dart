import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../documents/data/documents_provider.dart';
import '../../documents/data/stored_doc.dart';
import '../../documents/presentation/doc_tile.dart';

/// Pick documents, drag to set order, merge into a new PDF.
class MergeScreen extends ConsumerStatefulWidget {
  const MergeScreen({super.key});

  @override
  ConsumerState<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends ConsumerState<MergeScreen> {
  final _order = <String>[];
  bool _busy = false;

  Future<void> _merge(List<StoredDoc> picked) async {
    setState(() => _busy = true);
    final doc = await ref
        .read(documentsProvider.notifier)
        .merge(_order, 'Merged — ${picked.first.name}');
    Haptics.success();
    if (!mounted) return;
    context.pop();
    context.push('/doc/${doc.id}');
    showToast(
      context,
      'Merged ${plural(picked.length, 'file')} · ${plural(doc.pageCount, 'page')}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).value ?? const <StoredDoc>[];
    final byId = {for (final d in docs) d.id: d};
    _order.removeWhere((id) => !byId.containsKey(id));
    final picked = [for (final id in _order) byId[id]!];
    final rest = docs.where((d) => !_order.contains(d.id)).toList();
    final pages = picked.fold(0, (a, d) => a + d.pageCount);
    final px = context.px;

    return Scaffold(
      appBar: AppBar(title: const Text('Merge PDFs')),
      body: docs.length < 2
          ? const EmptyState(
              icon: Icons.layers_rounded,
              title: 'Need at least 2 documents',
              body: 'Scan or import a couple of documents first.',
            )
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                    child: Text(
                      picked.isEmpty
                          ? 'Tap documents below to add them.'
                          : 'In this order · drag the handles to reorder',
                      style: context.tt.bodySmall,
                    ),
                  ),
                ),
                SliverReorderableList(
                  itemCount: picked.length,
                  onReorderItem: (a, b) {
                    Haptics.light();
                    setState(() => _order.insert(b, _order.removeAt(a)));
                  },
                  itemBuilder: (context, i) {
                    final d = picked[i];
                    return Padding(
                      key: ValueKey(d.id),
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Material(
                        color: px.surfaceStrong,
                        borderRadius: BorderRadius.circular(16),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 11,
                                backgroundColor: context.cs.primary,
                                child: Text(
                                  '${i + 1}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: context.cs.onPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              DocThumb(d, width: 34, height: 44),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      d.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: context.tt.titleMedium,
                                    ),
                                    Text(
                                      '${plural(d.pageCount, 'page')} · ${fmtSize(d.sizeBytes)}',
                                      style: context.tt.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                tooltip: 'Remove',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () =>
                                    setState(() => _order.remove(d.id)),
                              ),
                              ReorderableDragStartListener(
                                index: i,
                                child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: Icon(
                                    Icons.drag_indicator_rounded,
                                    color: px.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
                if (rest.isNotEmpty)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SectionLabel('Add documents'),
                    ),
                  ),
                SliverList.builder(
                  itemCount: rest.length,
                  itemBuilder: (_, i) => ListTile(
                    leading: DocThumb(rest[i], width: 34, height: 44),
                    title: Text(
                      rest[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${plural(rest[i].pageCount, 'page')} · ${fmtSize(rest[i].sizeBytes)}',
                    ),
                    trailing: Icon(
                      Icons.add_circle_outline_rounded,
                      color: context.cs.primary,
                    ),
                    onTap: () {
                      Haptics.select();
                      setState(() => _order.add(rest[i].id));
                    },
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
      bottomNavigationBar: docs.length < 2
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: FilledButton.icon(
                onPressed: picked.length < 2 || _busy
                    ? null
                    : () => _merge(picked),
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.layers_rounded),
                label: Text(
                  picked.length < 2
                      ? 'Pick at least 2'
                      : 'Merge ${plural(picked.length, 'file')} · $pages pages',
                ),
              ),
            ),
    );
  }
}
