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
import '../domain/page_ranges.dart';

enum _Mode { extract, every }

/// Extract chosen pages into a new PDF, or split into parts of N pages.
/// The original document is never modified.
class SplitScreen extends ConsumerStatefulWidget {
  const SplitScreen({super.key, this.initialId});
  final String? initialId;

  @override
  ConsumerState<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends ConsumerState<SplitScreen> {
  String? _id;
  var _mode = _Mode.extract;
  final _selected = <int>{};
  int _every = 1;
  final _ranges = TextEditingController();
  String? _rangeError;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _id = widget.initialId;
  }

  @override
  void dispose() {
    _ranges.dispose();
    super.dispose();
  }

  void _pickDoc(String id) {
    Haptics.select();
    setState(() {
      _id = id;
      _selected.clear();
      _ranges.clear();
      _rangeError = null;
      _every = 1;
    });
  }

  void _toggle(int i) {
    Haptics.select();
    setState(() {
      _selected.contains(i) ? _selected.remove(i) : _selected.add(i);
      _ranges.text = formatPageRanges(_selected.toList());
      _rangeError = null;
    });
  }

  void _onRanges(String v, int pageCount) {
    try {
      final idx = parsePageRanges(v, pageCount);
      setState(() {
        _selected
          ..clear()
          ..addAll(idx);
        _rangeError = null;
      });
    } on FormatException catch (e) {
      setState(() => _rangeError = e.message);
    }
  }

  Future<void> _run(StoredDoc d, List<List<int>> groups) async {
    setState(() => _busy = true);
    final created = await ref
        .read(documentsProvider.notifier)
        .split(d.id, groups);
    Haptics.success();
    if (!mounted) return;
    context.pop();
    if (created.length == 1) context.push('/doc/${created.first.id}');
    showToast(
      context,
      created.length == 1
          ? 'Extracted ${plural(created.first.pageCount, 'page')}'
          : 'Split into ${created.length} files',
    );
  }

  @override
  Widget build(BuildContext context) {
    final docs = (ref.watch(documentsProvider).value ?? const <StoredDoc>[])
        .where((d) => d.pageCount > 1)
        .toList();
    final repo = ref.watch(repoSyncProvider);
    if (docs.isEmpty || repo == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Split PDF')),
        body: const EmptyState(
          icon: Icons.content_cut_rounded,
          title: 'Nothing to split',
          body: 'Split needs a document with at least 2 pages.',
        ),
      );
    }
    if (_id == null || !docs.any((d) => d.id == _id)) _id = docs.first.id;
    final doc = docs.firstWhere((d) => d.id == _id);
    final n = doc.pageCount;
    final parts = chunkPages(n, _every);
    final sel = _selected.toList()..sort();
    final px = context.px;

    final canRun =
        !_busy &&
        (_mode == _Mode.every
            ? parts.length > 1
            : sel.isNotEmpty && _rangeError == null);
    final label = _mode == _Mode.every
        ? 'Split into ${parts.length} files'
        : sel.isEmpty
        ? 'Select pages'
        : 'Extract ${plural(sel.length, 'page')} → new PDF';

    return Scaffold(
      appBar: AppBar(title: const Text('Split PDF')),
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
                      onSelected: _busy ? null : (_) => _pickDoc(d.id),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SegmentedButton<_Mode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: _Mode.extract, label: Text('Extract pages')),
              ButtonSegment(value: _Mode.every, label: Text('Every N pages')),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 16),
          if (_mode == _Mode.extract) ...[
            TextField(
              controller: _ranges,
              decoration: InputDecoration(
                labelText: 'Pages',
                hintText: 'e.g. 1-3, 7',
                errorText: _rangeError,
              ),
              onChanged: (v) => _onRanges(v, n),
            ),
            Row(
              children: [
                Text(
                  '${sel.length} of $n selected',
                  style: context.tt.bodySmall,
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    final all = sel.length < n;
                    _selected.clear();
                    if (all) _selected.addAll(List.generate(n, (i) => i));
                    _ranges.text = formatPageRanges(_selected.toList());
                    _rangeError = null;
                  }),
                  child: Text(sel.length < n ? 'Select all' : 'Clear'),
                ),
              ],
            ),
          ] else ...[
            Text('PAGES PER FILE · $_every', style: context.tt.labelSmall),
            if (n > 2)
              Slider(
                value: _every.toDouble(),
                min: 1,
                max: (n - 1).toDouble(),
                divisions: n - 2,
                label: '$_every',
                onChanged: (v) => setState(() => _every = v.round()),
              )
            else
              const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (i, p) in parts.indexed)
                  Chip(label: Text('File ${i + 1}: p${formatPageRanges(p)}')),
              ],
            ),
            const SizedBox(height: 12),
          ],
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.72,
            ),
            itemCount: n,
            itemBuilder: (_, i) {
              final on = _mode == _Mode.extract ? _selected.contains(i) : true;
              final part = _mode == _Mode.every ? i ~/ _every : -1;
              final tint = part >= 0
                  ? [px.scan, px.image, px.convert, px.pdf][part % 4]
                  : context.cs.primary;
              return Semantics(
                button: true,
                selected: on,
                label: 'Page ${i + 1}',
                child: GestureDetector(
                  onTap: _mode == _Mode.extract ? () => _toggle(i) : null,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: on ? tint : px.hairline,
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
                              color: on ? tint : const Color(0x99000000),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              part >= 0
                                  ? 'F${part + 1} · ${i + 1}'
                                  : '${i + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        if (_mode == _Mode.extract && on)
                          Positioned(
                            right: 6,
                            top: 6,
                            child: Icon(
                              Icons.check_circle_rounded,
                              color: tint,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 8),
          Text(
            'The original stays untouched; new files are saved next to it.',
            style: context.tt.bodySmall,
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: FilledButton.icon(
          onPressed: canRun
              ? () => _run(doc, _mode == _Mode.every ? parts : [sel])
              : null,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.content_cut_rounded),
          label: Text(label),
        ),
      ),
    );
  }
}
