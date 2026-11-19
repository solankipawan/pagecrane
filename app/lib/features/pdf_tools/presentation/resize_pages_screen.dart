import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../documents/data/doc_repository.dart';
import '../../documents/data/documents_provider.dart';
import '../../documents/presentation/doc_actions.dart';
import '../../documents/presentation/doc_tile.dart';
import '../domain/pdf_builder.dart';

/// Puts every page on a standard paper size (A4 / Letter / Legal), either fitting
/// the whole page with white margins or filling the paper and trimming edges.
class ResizePagesScreen extends ConsumerStatefulWidget {
  const ResizePagesScreen({super.key, required this.id});
  final String id;

  @override
  ConsumerState<ResizePagesScreen> createState() => _ResizePagesScreenState();
}

class _ResizePagesScreenState extends ConsumerState<ResizePagesScreen> {
  var _paper = 'A4';
  var _fill = false;
  double? _progress;

  static const _sizeLabel = {
    'A4': '210 × 297 mm',
    'Letter': '8.5 × 11 in',
    'Legal': '8.5 × 14 in',
  };

  Future<void> _run() async {
    final (w, h) = paperSizes[_paper]!;
    setState(() => _progress = 0);
    try {
      await ref
          .read(documentsProvider.notifier)
          .resizePages(
            widget.id,
            ratio: h / w,
            fill: _fill,
            onProgress: (v) {
              if (mounted) setState(() => _progress = v);
            },
          );
    } on StorageException catch (e) {
      if (mounted) {
        setState(() => _progress = null);
        showSaveError(context, e);
      }
      return;
    }
    Haptics.success();
    if (!mounted) return;
    context.pop();
    showToast(context, 'Pages set to $_paper');
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).value;
    final doc = docs?.where((d) => d.id == widget.id).firstOrNull;
    final repo = ref.watch(repoSyncProvider);
    if (doc == null || repo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Resize pages')),
        body: docs == null
            ? const Center(child: CircularProgressIndicator())
            : const EmptyState(
                icon: Icons.description_outlined,
                title: 'Document not found',
              ),
      );
    }
    final first = repo.pagesOf(doc).first;
    final (pw, ph) = paperSizes[_paper]!;
    final busy = _progress != null;
    final px = context.px;

    return Scaffold(
      appBar: AppBar(title: const Text('Resize pages')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          Text(
            '${doc.name} · ${plural(doc.pageCount, 'page')}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: context.tt.bodySmall,
          ),
          const SizedBox(height: 16),
          // Preview: page 1 on the chosen paper.
          Center(
            child: SizedBox(
              height: 300,
              child: AspectRatio(
                aspectRatio: pw / ph,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x2914183C),
                        blurRadius: 20,
                        offset: Offset(0, 8),
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Image.file(
                    first,
                    fit: _fill ? BoxFit.cover : BoxFit.contain,
                    cacheWidth: 600,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              'Page 1 preview · ${_sizeLabel[_paper]}',
              style: context.tt.bodySmall,
            ),
          ),
          const SectionLabel('Paper size'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in paperSizes.keys)
                ChoiceChip(
                  label: Text('$p · ${_sizeLabel[p]}'),
                  selected: _paper == p,
                  onSelected: busy
                      ? null
                      : (_) {
                          Haptics.select();
                          setState(() => _paper = p);
                        },
                ),
            ],
          ),
          const SectionLabel('Fit'),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.fit_screen_rounded, size: 18),
                label: Text('Fit whole page'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.crop_rounded, size: 18),
                label: Text('Fill paper'),
              ),
            ],
            selected: {_fill},
            onSelectionChanged: busy
                ? null
                : (s) {
                    Haptics.select();
                    setState(() => _fill = s.first);
                  },
          ),
          const SizedBox(height: 10),
          Text(
            _fill
                ? 'Fills the paper edge to edge; anything outside it is trimmed.'
                : 'Keeps every part of the page and adds white margins where needed.',
            style: context.tt.bodySmall,
          ),
          const SizedBox(height: 6),
          Text(
            'Landscape pages use landscape paper. The document is updated in place.',
            style: context.tt.bodySmall?.copyWith(color: px.muted),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: busy ? null : _run,
            icon: busy
                ? SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: _progress,
                    ),
                  )
                : const Icon(Icons.aspect_ratio_rounded),
            label: Text(
              busy
                  ? 'Resizing… ${((_progress ?? 0) * 100).round()}%'
                  : 'Resize ${plural(doc.pageCount, 'page')} to $_paper',
            ),
          ),
        ),
      ),
    );
  }
}
