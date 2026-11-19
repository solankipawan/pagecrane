import 'package:flutter/foundation.dart' show compute;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../documents/data/documents_provider.dart';
import '../../documents/data/stored_doc.dart';
import '../../documents/presentation/doc_tile.dart';
import '../../scanner/domain/page_pipeline.dart';

/// PDF → images: export a library document's pages as JPG or PNG through the share sheet
/// (Save to Photos, Files, AirDrop, mail…).
class ExportImagesScreen extends ConsumerStatefulWidget {
  const ExportImagesScreen({super.key, this.initialId});
  final String? initialId;

  @override
  ConsumerState<ExportImagesScreen> createState() => _ExportImagesScreenState();
}

class _ExportImagesScreenState extends ConsumerState<ExportImagesScreen> {
  static const _sizes = <(String, int?)>[
    ('Original', null),
    ('2000 px', 2000),
    ('1200 px', 1200),
  ];

  String? _id;
  final _selected = <int>{};
  var _format = ExportFormat.jpg;
  double _quality = 92;
  int? _maxDim;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _id = widget.initialId;
  }

  void _pickDoc(StoredDoc d) {
    Haptics.select();
    setState(() {
      _id = d.id;
      _selected
        ..clear()
        ..addAll(List.generate(d.pageCount, (i) => i));
    });
  }

  Future<void> _export(StoredDoc d) async {
    final repo = ref.read(repoSyncProvider)!;
    final pages = _selected.toList()..sort();
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    setState(() => _progress = 0);
    final ext = _format == ExportFormat.png ? 'png' : 'jpg';
    final mime = _format == ExportFormat.png ? 'image/png' : 'image/jpeg';
    final base = d.name.replaceAll(RegExp(r'[\\/:*?"<>|]+'), '-');
    final files = <XFile>[];
    final names = <String>[];
    var total = 0;
    for (final (k, i) in pages.indexed) {
      final src = await repo.pageOf(d.id, i).readAsBytes();
      final format = _format, quality = _quality.round(), maxDim = _maxDim;
      final bytes = await compute(exportPage, (
        src: src,
        format: format,
        quality: quality,
        maxDim: maxDim,
      ));
      final name = d.pageCount == 1
          ? '$base.$ext'
          : '$base - p${(i + 1).toString().padLeft(2, '0')}.$ext';
      files.add(XFile.fromData(bytes, mimeType: mime, name: name));
      names.add(name);
      total += bytes.length;
      if (mounted) setState(() => _progress = (k + 1) / pages.length);
    }
    if (!mounted) return;
    setState(() => _progress = null);
    Haptics.success();
    final r = await SharePlus.instance.share(
      ShareParams(
        files: files,
        fileNameOverrides: names,
        sharePositionOrigin: origin,
      ),
    );
    if (!mounted) return;
    if (r.status == ShareResultStatus.success) {
      showToast(
        context,
        'Exported ${plural(files.length, 'image')} · ${fmtSize(total)}',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).value ?? const <StoredDoc>[];
    final repo = ref.watch(repoSyncProvider);
    if (docs.isEmpty || repo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('PDF to images')),
        body: const EmptyState(
          icon: Icons.image_outlined,
          title: 'No documents yet',
          body: 'Scan or import a document first.',
        ),
      );
    }
    if (_id == null || !docs.any((d) => d.id == _id)) _id = docs.first.id;
    final doc = docs.firstWhere((d) => d.id == _id);
    // Default (and after a document shrinks): every page selected.
    if (_selected.isEmpty || _selected.any((i) => i >= doc.pageCount)) {
      _selected
        ..clear()
        ..addAll(List.generate(doc.pageCount, (i) => i));
    }
    final px = context.px;
    final busy = _progress != null;
    final n = _selected.length;

    return Scaffold(
      appBar: AppBar(title: const Text('PDF to images')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final d in docs)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 160),
                        child: Text(d.name, overflow: TextOverflow.ellipsis),
                      ),
                      selected: d.id == _id,
                      onSelected: busy ? null : (_) => _pickDoc(d),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SegmentedButton<ExportFormat>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ExportFormat.jpg, label: Text('JPG')),
              ButtonSegment(value: ExportFormat.png, label: Text('PNG')),
            ],
            selected: {_format},
            onSelectionChanged: busy
                ? null
                : (s) => setState(() => _format = s.first),
          ),
          const SizedBox(height: 14),
          Text('SIZE', style: context.tt.labelSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final (label, dim) in _sizes)
                ChoiceChip(
                  label: Text(label),
                  selected: _maxDim == dim,
                  onSelected: busy
                      ? null
                      : (_) => setState(() => _maxDim = dim),
                ),
            ],
          ),
          if (_format == ExportFormat.jpg) ...[
            const SizedBox(height: 14),
            Text('QUALITY ${_quality.round()}%', style: context.tt.labelSmall),
            Slider(
              value: _quality,
              min: 50,
              max: 100,
              divisions: 10,
              label: '${_quality.round()}%',
              onChanged: busy ? null : (v) => setState(() => _quality = v),
            ),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'PNG is lossless and much larger; best for further editing.',
                style: context.tt.bodySmall,
              ),
            ),
          Row(
            children: [
              Text('$n of ${doc.pageCount} pages', style: context.tt.bodySmall),
              const Spacer(),
              if (doc.pageCount > 1)
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                          if (n == doc.pageCount) {
                            _selected
                              ..clear()
                              ..add(0);
                          } else {
                            _selected.addAll(
                              List.generate(doc.pageCount, (i) => i),
                            );
                          }
                        }),
                  child: Text(
                    n == doc.pageCount ? 'Only page 1' : 'Select all',
                  ),
                ),
            ],
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.72,
            ),
            itemCount: doc.pageCount,
            itemBuilder: (_, i) {
              final on = _selected.contains(i);
              return Semantics(
                button: true,
                selected: on,
                label: 'Page ${i + 1}',
                child: GestureDetector(
                  onTap: busy
                      ? null
                      : () {
                          Haptics.select();
                          setState(() {
                            // Keep at least one page selected.
                            if (on && _selected.length > 1) {
                              _selected.remove(i);
                            } else {
                              _selected.add(i);
                            }
                          });
                        },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: on ? context.cs.primary : px.hairline,
                        width: on ? 3 : 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        Image.file(
                          repo.pageOf(doc.id, i),
                          key: ValueKey('${doc.updatedAt}$i'),
                          fit: BoxFit.cover,
                          cacheWidth: 300,
                        ),
                        Positioned(
                          left: 6,
                          bottom: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: on
                                  ? context.cs.primary
                                  : const Color(0x99000000),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              '${i + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        if (on)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Icon(
                              Icons.check_circle_rounded,
                              color: context.cs.primary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          if (busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(
              value: _progress,
              borderRadius: BorderRadius.circular(99),
            ),
          ],
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: FilledButton.icon(
          onPressed: busy ? null : () => _export(doc),
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.ios_share_rounded),
          label: Text(
            'Export ${plural(n, 'page')} as ${_format == ExportFormat.png ? 'PNG' : 'JPG'}',
          ),
        ),
      ),
    );
  }
}
