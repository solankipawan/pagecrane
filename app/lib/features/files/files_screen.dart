import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/glass.dart';
import '../../app/theme/tokens.dart';
import '../../core/format.dart';
import '../../core/haptics.dart';
import '../../core/widgets/common.dart';
import '../../core/widgets/empty_states.dart';
import '../documents/data/documents_provider.dart';
import '../documents/data/stored_doc.dart';
import '../documents/presentation/doc_tile.dart';
import '../documents/presentation/import_pdf_flow.dart';
import '../scanner/presentation/capture_sheet.dart';

enum _View { all, starred, folders }

enum _Sort { date, name, size }

/// Quick filters offered when a search finds nothing (and shown as a removable
/// chip while active).
enum _Filter {
  pdf('PDF'),
  today('Scanned Today'),
  small('Under 1 MB');

  const _Filter(this.label);
  final String label;

  bool test(StoredDoc d) {
    final now = DateTime.now();
    return switch (this) {
      _Filter.pdf => true, // every stored document is a PDF
      _Filter.today =>
        d.createdAt.year == now.year &&
            d.createdAt.month == now.month &&
            d.createdAt.day == now.day,
      _Filter.small => d.sizeBytes < 1000000,
    };
  }
}

class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  var _view = _View.all;
  var _sort = _Sort.date;
  var _q = '';
  String? _folder;
  _Filter? _filter;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clearSearch() {
    Haptics.select();
    _search.clear();
    setState(() => _q = '');
  }

  /// From the no-results state: drop the query and show [f] (null = everything).
  void _applyFilter(_Filter? f) {
    Haptics.select();
    _search.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _q = '';
      _filter = f;
      _folder = null;
      if (_view == _View.folders) _view = _View.all;
    });
  }

  @override
  Widget build(BuildContext context) {
    final docsAsync = ref.watch(documentsProvider);
    final docs = docsAsync.value ?? const <StoredDoc>[];
    final q = _q.toLowerCase();
    final list =
        docs
            .where((d) => _view != _View.starred || d.starred)
            .where((d) => _folder == null || d.folder == _folder)
            .where((d) => _filter == null || _filter!.test(d))
            .where(
              (d) =>
                  q.isEmpty ||
                  d.name.toLowerCase().contains(q) ||
                  d.folder.toLowerCase().contains(q),
            )
            .toList()
          ..sort(
            (a, b) => switch (_sort) {
              _Sort.name => a.name.toLowerCase().compareTo(
                b.name.toLowerCase(),
              ),
              _Sort.size => b.sizeBytes.compareTo(a.sizeBytes),
              _Sort.date => b.updatedAt.compareTo(a.updatedAt),
            },
          );
    final showFolders = _view == _View.folders && _folder == null && q.isEmpty;

    return ListView(
      padding: EdgeInsets.fromLTRB(
        20,
        MediaQuery.paddingOf(context).top + 12,
        20,
        140,
      ),
      children: [
        Row(
          children: [
            Expanded(child: Text('Files', style: context.tt.headlineLarge)),
            GlassSurface(
              radius: 22,
              child: IconButton(
                tooltip: 'Import PDF',
                icon: const Icon(Icons.file_open_rounded),
                onPressed: () => importPdf(context, ref),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SegmentedButton<_View>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: _View.all, label: Text('All')),
            ButtonSegment(value: _View.starred, label: Text('Starred')),
            ButtonSegment(value: _View.folders, label: Text('Folders')),
          ],
          selected: {_view},
          onSelectionChanged: (s) {
            Haptics.select();
            setState(() {
              _view = s.first;
              _folder = null;
            });
          },
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: GlassSurface(
                radius: 16,
                child: TextField(
                  controller: _search,
                  onChanged: (v) => setState(() => _q = v),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _q.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: _clearSearch,
                          ),
                    filled: false,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(vertical: 14),
                    hintStyle: TextStyle(color: context.px.muted),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            GlassSurface(
              radius: 16,
              child: PopupMenuButton<_Sort>(
                tooltip: 'Sort',
                initialValue: _sort,
                icon: const Icon(Icons.sort_rounded),
                onSelected: (s) => setState(() => _sort = s),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: _Sort.date, child: Text('Newest')),
                  PopupMenuItem(value: _Sort.name, child: Text('Name')),
                  PopupMenuItem(value: _Sort.size, child: Text('Size')),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (_folder != null || _filter != null)
          Wrap(
            spacing: 8,
            children: [
              if (_folder != null)
                InputChip(
                  avatar: const Icon(Icons.folder_open_rounded, size: 18),
                  label: Text(_folder!),
                  onDeleted: () => setState(() => _folder = null),
                ),
              if (_filter != null)
                InputChip(
                  avatar: const Icon(Icons.filter_list_rounded, size: 18),
                  label: Text(_filter!.label),
                  deleteButtonTooltipMessage: 'Remove filter',
                  onDeleted: () => setState(() => _filter = null),
                ),
            ],
          ),
        if (docsAsync is AsyncData && docs.isEmpty)
          IllustratedEmptyState(
            art: const ScanEmptyArt(),
            title: 'No documents scanned yet',
            body: 'Scan receipts, notes, or IDs into crisp PDFs right on your device.',
            primaryLabel: 'Scan First Document',
            onPrimary: () => startScan(context, ref),
            secondaryLabel: 'Import PDF',
            onSecondary: () => importPdf(context, ref),
          )
        else if (showFolders)
          _FolderGrid(docs: docs, onOpen: (f) => setState(() => _folder = f))
        else if (list.isEmpty && q.isNotEmpty)
          IllustratedEmptyState(
            art: const SearchEmptyArt(),
            title: 'No matches for “$_q”',
            body: docs.length == 1
                ? 'Check spelling or clear search to view your 1 on\u2011device document.'
                : 'Check spelling or clear search to view all ${docs.length} on\u2011device documents.',
            extra: _QuickFilters(selected: _filter, onSelected: _applyFilter),
            secondaryLabel: 'Clear Search',
            onSecondary: _clearSearch,
          )
        else if (list.isEmpty)
          EmptyState(
            icon: _view == _View.starred
                ? Icons.star_outline_rounded
                : Icons.filter_list_off_rounded,
            title: _view == _View.starred
                ? 'No starred documents'
                : 'Nothing matches this filter',
            body: _view == _View.starred
                ? 'Tap the star on a document to keep it here.'
                : null,
          )
        else
          GlassSurface(
            child: Column(
              children: [
                for (final (i, d) in list.indexed)
                  DocTile(d, showDivider: i < list.length - 1),
              ],
            ),
          ),
      ],
    );
  }
}

class _QuickFilters extends StatelessWidget {
  const _QuickFilters({required this.selected, required this.onSelected});
  final _Filter? selected;
  final ValueChanged<_Filter?> onSelected;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.center,
    spacing: 8,
    runSpacing: 8,
    children: [
      ChoiceChip(
        label: const Text('All'),
        selected: selected == null,
        onSelected: (_) => onSelected(null),
      ),
      for (final f in _Filter.values)
        ChoiceChip(
          label: Text(f.label),
          selected: selected == f,
          onSelected: (_) => onSelected(f),
        ),
    ],
  );
}

class _FolderGrid extends StatelessWidget {
  const _FolderGrid({required this.docs, required this.onOpen});
  final List<StoredDoc> docs;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final folders = <String, List<StoredDoc>>{};
    for (final d in docs) {
      (folders[d.folder] ??= []).add(d);
    }
    if (folders.isEmpty) {
      return const EmptyState(
        icon: Icons.folder_open_rounded,
        title: 'No folders yet',
      );
    }
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.5,
      children: [
        for (final MapEntry(key: f, value: list) in folders.entries)
          Pressable(
            onTap: () => onOpen(f),
            semanticLabel: 'Folder $f',
            child: GlassSurface(
              radius: 18,
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Icon(
                    Icons.folder_rounded,
                    color: context.cs.primary,
                    size: 28,
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(f, style: context.tt.titleMedium),
                      Text(
                        '${plural(list.length, 'file')} · ${fmtSize(list.fold(0, (a, d) => a + d.sizeBytes))}',
                        style: context.tt.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
