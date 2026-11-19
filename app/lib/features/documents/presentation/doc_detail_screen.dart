import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../data/documents_provider.dart';
import 'doc_tile.dart';
import 'pdf_reader.dart';

/// Page viewer + document actions (share, star, rename, compress, delete).
/// Annotation (signature, highlight, comments) is a later milestone.
class DocDetailScreen extends ConsumerStatefulWidget {
  const DocDetailScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<DocDetailScreen> createState() => _DocDetailScreenState();
}

class _DocDetailScreenState extends ConsumerState<DocDetailScreen> {
  int _page = 0;

  /// Horizontal mode's controller, recreated at the current page after a switch
  /// so changing direction keeps your place.
  PageController? _pc;

  @override
  void dispose() {
    _pc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).value;
    final doc = docs?.where((d) => d.id == widget.id).firstOrNull;
    final repo = ref.watch(repoSyncProvider);
    if (doc == null || repo == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const EmptyState(
          icon: Icons.description_outlined,
          title: 'Document not found',
        ),
      );
    }
    final notifier = ref.read(documentsProvider.notifier);
    final px = context.px;

    Future<void> rename() async {
      final c = TextEditingController(text: doc.name);
      final name = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Rename'),
          content: TextField(
            controller: c,
            autofocus: true,
            onSubmitted: (v) => Navigator.pop(d, v),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(d, c.text),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (name != null && name.trim().isNotEmpty) {
        await notifier.rename(doc.id, name.trim());
      }
    }

    Future<void> delete() async {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Delete document?'),
          content: Text(
            '“${doc.name}” will be removed from this device. This can’t be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(d, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(d, true),
              child: Text('Delete', style: TextStyle(color: px.danger)),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
      Haptics.medium();
      context.pop();
      await notifier.remove(doc.id);
    }

    Future<void> share() async {
      Haptics.light();
      final box = context.findRenderObject() as RenderBox?;
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile(
              repo.pdfOf(doc.id).path,
              mimeType: 'application/pdf',
              name: '${doc.name}.pdf',
            ),
          ],
          title: doc.name,
          sharePositionOrigin: box == null
              ? null
              : box.localToGlobal(Offset.zero) & box.size,
        ),
      );
    }

    final pages = repo.pagesOf(doc);
    final vertical = ref.watch(readerVerticalProvider);
    if (vertical && _pc != null) {
      final old = _pc!;
      _pc = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(doc.name, overflow: TextOverflow.ellipsis),
        actions: [
          const ScrollDirectionButton(),
          IconButton(
            tooltip: doc.starred ? 'Remove star' : 'Star',
            icon: Icon(
              doc.starred ? Icons.star_rounded : Icons.star_outline_rounded,
              color: doc.starred ? const Color(0xFFF5B301) : null,
            ),
            onPressed: () {
              Haptics.select();
              notifier.toggleStar(doc.id);
            },
          ),
          PopupMenuButton<String>(
            onSelected: (v) => switch (v) {
              'rename' => rename(),
              'compress' => context.push('/tool/compress?id=${doc.id}'),
              'split' => context.push('/tool/split?id=${doc.id}'),
              'images' => context.push('/tool/export-images?id=${doc.id}'),
              'delete' => delete(),
              _ => null,
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              const PopupMenuItem(value: 'compress', child: Text('Compress')),
              if (doc.pageCount > 1)
                const PopupMenuItem(value: 'split', child: Text('Split')),
              const PopupMenuItem(
                value: 'images',
                child: Text('Export as images'),
              ),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: vertical
                ? PdfReader(
                    // New file version (compress, resize…) → reload.
                    key: ValueKey(doc.updatedAt),
                    path: repo.pdfOf(doc.id).path,
                    vertical: true,
                    initialPage: _page,
                    onPage: (p) {
                      if (p != _page) setState(() => _page = p);
                    },
                  )
                : PageView.builder(
                    controller: _pc ??= PageController(initialPage: _page),
                    itemCount: pages.length,
                    onPageChanged: (i) => setState(() => _page = i),
                    itemBuilder: (_, i) => InteractiveViewer(
                      maxScale: 4,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                        child: Center(
                          child: DecoratedBox(
                            decoration: const BoxDecoration(
                              boxShadow: [
                                BoxShadow(
                                  color: Color(0x33000000),
                                  blurRadius: 30,
                                  offset: Offset(0, 10),
                                ),
                              ],
                            ),
                            child: Image.file(
                              pages[i],
                              key: ValueKey('${doc.updatedAt}$i'),
                              gaplessPlayback: true,
                              semanticLabel: 'Page ${i + 1}',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Page ${_page + 1} of ${pages.length} · ${fmtSize(doc.sizeBytes)} · ${doc.folder}',
              style: context.tt.bodySmall,
            ),
          ),
          SafeArea(
            top: false,
            minimum: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () =>
                        context.push('/doc/${doc.id}/annotate?page=$_page'),
                    icon: const Icon(Icons.draw_rounded),
                    label: const Text('Annotate'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: share,
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('Share PDF'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
