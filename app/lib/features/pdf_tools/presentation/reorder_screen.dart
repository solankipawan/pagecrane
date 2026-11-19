import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../documents/data/doc_repository.dart';
import '../../documents/data/documents_provider.dart';
import '../../documents/presentation/doc_actions.dart';
import '../../documents/presentation/doc_tile.dart';

/// Drag pages into a new order, then save over the same document.
class ReorderScreen extends ConsumerStatefulWidget {
  const ReorderScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ReorderScreen> createState() => _ReorderScreenState();
}

class _ReorderScreenState extends ConsumerState<ReorderScreen> {
  List<int>? _order;
  bool _saving = false;

  bool get _changed {
    final o = _order;
    if (o == null) return false;
    for (var i = 0; i < o.length; i++) {
      if (o[i] != i) return true;
    }
    return false;
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref
          .read(documentsProvider.notifier)
          .reorderPages(widget.id, _order!);
    } on StorageException catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSaveError(context, e);
      }
      return;
    }
    Haptics.success();
    if (!mounted) return;
    context.pop();
    showToast(context, 'Page order saved');
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).value;
    final doc = docs?.where((d) => d.id == widget.id).firstOrNull;
    final repo = ref.watch(repoSyncProvider);
    if (doc == null || repo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reorder pages')),
        body: docs == null
            ? const Center(child: CircularProgressIndicator())
            : const EmptyState(
                icon: Icons.description_outlined,
                title: 'Document not found',
              ),
      );
    }
    final files = repo.pagesOf(doc);
    final order = _order ??= List.generate(files.length, (i) => i);
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final px = context.px;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Reorder pages'),
        actions: [
          if (_changed)
            TextButton(
              onPressed: _saving
                  ? null
                  : () => setState(
                      () => _order = List.generate(files.length, (i) => i),
                    ),
              child: const Text('Reset'),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              '${doc.name} · drag the handles to change the order',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: context.tt.bodySmall,
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              buildDefaultDragHandles: false,
              itemCount: order.length,
              onReorderItem: (a, b) {
                Haptics.light();
                setState(() => order.insert(b, order.removeAt(a)));
              },
              itemBuilder: (context, i) {
                final page = order[i];
                final moved = page != i;
                return Padding(
                  key: ValueKey(page),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: px.surfaceStrong,
                    borderRadius: BorderRadius.circular(16),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 13,
                            backgroundColor: context.cs.primary,
                            child: Text(
                              '${i + 1}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: context.cs.onPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Image.file(
                              files[page],
                              width: 48,
                              height: 64,
                              fit: BoxFit.cover,
                              cacheWidth: (48 * dpr).ceil(),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              moved
                                  ? 'Page ${page + 1} → position ${i + 1}'
                                  : 'Page ${page + 1}',
                              style: context.tt.titleMedium,
                            ),
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
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
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _changed && !_saving ? _save : null,
            icon: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(_changed ? 'Save order' : 'Drag pages to reorder'),
          ),
        ),
      ),
    );
  }
}
