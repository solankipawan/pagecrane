import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/glass.dart';
import '../../app/theme/tokens.dart';
import '../../core/format.dart';
import '../../core/haptics.dart';
import '../../core/widgets/common.dart';
import '../documents/data/documents_provider.dart';
import '../documents/data/stored_doc.dart';
import '../documents/presentation/doc_tile.dart';
import '../documents/presentation/import_pdf_flow.dart';

enum _View { all, starred, folders }

enum _Sort { date, name, size }

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

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).value ?? const <StoredDoc>[];
    final q = _q.toLowerCase();
    final list =
        docs
            .where((d) => _view != _View.starred || d.starred)
            .where((d) => _folder == null || d.folder == _folder)
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
                  onChanged: (v) => setState(() => _q = v),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search',
                    prefixIcon: const Icon(Icons.search_rounded),
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
        if (_folder != null)
          Align(
            alignment: Alignment.centerLeft,
            child: InputChip(
              avatar: const Icon(Icons.folder_open_rounded, size: 18),
              label: Text(_folder!),
              onDeleted: () => setState(() => _folder = null),
            ),
          ),
        if (showFolders)
          _FolderGrid(docs: docs, onOpen: (f) => setState(() => _folder = f))
        else if (list.isEmpty)
          EmptyState(
            icon: q.isEmpty
                ? Icons.folder_open_rounded
                : Icons.search_off_rounded,
            title: q.isEmpty ? 'Nothing here yet' : 'No results for “$_q”',
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
