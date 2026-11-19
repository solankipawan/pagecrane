import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/glass.dart';
import '../../app/theme/tokens.dart';
import '../../core/format.dart';
import '../../core/haptics.dart';
import '../../core/widgets/common.dart';
import '../documents/data/documents_provider.dart';
import '../documents/data/stored_doc.dart';
import '../documents/presentation/doc_actions.dart';
import '../documents/presentation/doc_tile.dart';
import 'tool_catalog.dart';

enum _Sort {
  recent('Recent'),
  name('Name'),
  size('Size');

  const _Sort(this.label);
  final String label;
}

/// Tools & Files: every tool in three groups (grid or list), then the documents
/// with a per-row menu and long-press multi-select.
class ToolsScreen extends ConsumerStatefulWidget {
  const ToolsScreen({super.key});

  static const groups = [
    (
      'Capture & Convert',
      ['scan', 'convert', 'idcard', 'batch', 'pdf2img', 'importpdf'],
    ),
    ('Organize & Edit', ['merge', 'split', 'reorder', 'sign']),
    (
      'Optimize Size',
      ['compress', 'targetpdf', 'resizepdf', 'resize', 'target'],
    ),
  ];

  @override
  ConsumerState<ToolsScreen> createState() => _ToolsScreenState();
}

class _ToolsScreenState extends ConsumerState<ToolsScreen> {
  var _grid = true;
  var _sort = _Sort.recent;
  final _selected = <String>{};

  bool get _selecting => _selected.isNotEmpty;

  void _toggle(StoredDoc d) {
    Haptics.select();
    setState(() {
      if (!_selected.remove(d.id)) _selected.add(d.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final docs = [...ref.watch(documentsProvider).value ?? const <StoredDoc>[]]
      ..sort(
        (a, b) => switch (_sort) {
          _Sort.recent => b.updatedAt.compareTo(a.updatedAt),
          _Sort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          _Sort.size => b.sizeBytes.compareTo(a.sizeBytes),
        },
      );
    _selected.removeWhere((id) => !docs.any((d) => d.id == id));
    final picked = docs.where((d) => _selected.contains(d.id)).toList();
    final mq = MediaQuery.of(context);
    // The shell's tab bar: 96 pt tall above the bottom inset (14 pt when none).
    final navTop = (mq.padding.bottom > 0 ? mq.padding.bottom : 14) + 96;

    return PopScope(
      canPop: !_selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_selected.clear);
      },
      child: Stack(
        children: [
          ListView(
            padding: EdgeInsets.fromLTRB(
              20,
              mq.padding.top + 12,
              20,
              navTop + (_selecting ? 96 : 28),
            ),
            children: [
              Text('Tools & Files', style: context.tt.headlineLarge),
              const SizedBox(height: 14),
              Row(
                children: [
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      padding: WidgetStatePropertyAll(
                        EdgeInsets.symmetric(horizontal: 12),
                      ),
                    ),
                    segments: const [
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.grid_view_rounded, size: 18),
                        label: Text('Grid'),
                      ),
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.view_list_rounded, size: 18),
                        label: Text('List'),
                      ),
                    ],
                    selected: {_grid},
                    onSelectionChanged: (s) {
                      Haptics.select();
                      setState(() => _grid = s.first);
                    },
                  ),
                  const Spacer(),
                  _SortPill(
                    value: _sort,
                    onChanged: (s) {
                      Haptics.select();
                      setState(() => _sort = s);
                    },
                  ),
                ],
              ),
              for (final (title, ids) in ToolsScreen.groups) ...[
                SectionLabel(title),
                _grid ? _ToolGrid(ids: ids) : _ToolList(ids: ids),
              ],
              SectionLabel(
                _selecting
                    ? '${_selected.length} selected'
                    : 'Your files · ${docs.length}',
                trailing: _selecting
                    ? TextButton(
                        onPressed: () => setState(
                          () => _selected.addAll(docs.map((d) => d.id)),
                        ),
                        child: const Text('Select all'),
                      )
                    : null,
              ),
              if (docs.isEmpty)
                const GlassSurface(
                  child: EmptyState(
                    icon: Icons.document_scanner_rounded,
                    title: 'No documents yet',
                    body: 'Scan or import one and it shows up here.',
                  ),
                )
              else ...[
                if (!_selecting)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: 8),
                    child: Text(
                      'Long-press a file to select several.',
                      style: context.tt.bodySmall,
                    ),
                  ),
                GlassSurface(
                  child: Column(
                    children: [
                      for (final (i, d) in docs.indexed)
                        _FileRow(
                          doc: d,
                          divider: i < docs.length - 1,
                          selecting: _selecting,
                          selected: _selected.contains(d.id),
                          onTap: () => _selecting
                              ? _toggle(d)
                              : context.push('/doc/${d.id}'),
                          onLongPress: () => _toggle(d),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          if (_selecting)
            Positioned(
              left: 16,
              right: 16,
              bottom: navTop + 8,
              child: _SelectionBar(
                count: picked.length,
                onClose: () => setState(_selected.clear),
                onShare: () => shareDocs(context, ref, picked),
                onMerge: picked.length < 2
                    ? null
                    : () {
                        final ids = picked.map((d) => d.id).join(',');
                        setState(_selected.clear);
                        context.push('/tool/merge?ids=$ids');
                      },
                onDelete: () async {
                  if (await deleteDocs(context, ref, picked) && mounted) {
                    setState(_selected.clear);
                  }
                },
              ),
            ),
        ],
      ),
    );
  }
}

// ---- tools ----------------------------------------------------------------------

class _ToolGrid extends StatelessWidget {
  const _ToolGrid({required this.ids});
  final List<String> ids;

  @override
  Widget build(BuildContext context) {
    final rows = <List<String>>[
      for (var i = 0; i < ids.length; i += 2)
        ids.sublist(i, i + 2 > ids.length ? ids.length : i + 2),
    ];
    return Column(
      children: [
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            // Each pair shares its tallest height, so long labels never clip.
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (k, id) in row.indexed) ...[
                    if (k > 0) const SizedBox(width: 10),
                    Expanded(child: _ToolTile(t: tools[id]!)),
                  ],
                  if (row.length == 1) ...[
                    const SizedBox(width: 10),
                    const Expanded(child: SizedBox()),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _ToolTile extends ConsumerWidget {
  const _ToolTile({required this.t});
  final ToolDef t;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Pressable(
    onTap: () => openTool(context, ref, t),
    semanticLabel: '${t.name}. ${t.desc}',
    child: GlassSurface(
      radius: 18,
      padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ToolIcon(t.icon, context.categoryColor(t.cat), size: 40),
          const SizedBox(height: 10),
          Text(
            t.name,
            style: context.tt.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 3),
          Text(t.desc, style: context.tt.bodySmall?.copyWith(height: 1.3)),
        ],
      ),
    ),
  );
}

class _ToolList extends ConsumerWidget {
  const _ToolList({required this.ids});
  final List<String> ids;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final px = context.px;
    return GlassSurface(
      child: Column(
        children: [
          for (final (k, id) in ids.indexed)
            Semantics(
              button: true,
              label: '${tools[id]!.name}. ${tools[id]!.desc}',
              excludeSemantics: true,
              child: InkWell(
                onTap: () => openTool(context, ref, tools[id]!),
                child: Container(
                  constraints: const BoxConstraints(minHeight: 64),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: k < ids.length - 1
                        ? Border(bottom: BorderSide(color: px.hairline))
                        : null,
                  ),
                  child: Row(
                    children: [
                      ToolIcon(
                        tools[id]!.icon,
                        context.categoryColor(tools[id]!.cat),
                        size: 38,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tools[id]!.name,
                              style: context.tt.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(tools[id]!.desc, style: context.tt.bodySmall),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right_rounded, color: px.muted),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SortPill extends StatelessWidget {
  const _SortPill({required this.value, required this.onChanged});
  final _Sort value;
  final ValueChanged<_Sort> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<_Sort>(
    tooltip: 'Sort files',
    initialValue: value,
    onSelected: onChanged,
    itemBuilder: (_) => [
      for (final s in _Sort.values)
        CheckedPopupMenuItem(
          value: s,
          checked: s == value,
          child: Text(s.label),
        ),
    ],
    child: Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: context.px.surfaceStrong,
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: context.px.glassBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sort_rounded, size: 18, color: context.px.muted),
          const SizedBox(width: 6),
          Text(
            value.label,
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          Icon(Icons.expand_more_rounded, size: 18, color: context.px.muted),
        ],
      ),
    ),
  );
}

// ---- files ------------------------------------------------------------------------

class _FileRow extends ConsumerWidget {
  const _FileRow({
    required this.doc,
    required this.divider,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });
  final StoredDoc doc;
  final bool divider, selecting, selected;
  final VoidCallback onTap, onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final px = context.px;
    return Semantics(
      selected: selecting ? selected : null,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          constraints: const BoxConstraints(minHeight: 76),
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          decoration: BoxDecoration(
            color: selected ? context.cs.primary.withValues(alpha: 0.08) : null,
            border: divider
                ? Border(bottom: BorderSide(color: px.hairline))
                : null,
          ),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  DocThumb(doc),
                  if (selecting)
                    Positioned(
                      right: -6,
                      bottom: -6,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: selected
                              ? context.cs.primary
                              : Theme.of(context).scaffoldBackgroundColor,
                          border: Border.all(
                            color: selected ? context.cs.primary : px.muted,
                            width: 2,
                          ),
                        ),
                        child: selected
                            ? Icon(
                                Icons.check_rounded,
                                size: 14,
                                color: context.cs.onPrimary,
                              )
                            : null,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      doc.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: context.tt.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: 6,
                      runSpacing: 2,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: px.pdf.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'PDF',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: px.pdf,
                            ),
                          ),
                        ),
                        Text(
                          '${plural(doc.pageCount, 'page')} · ${fmtSize(doc.sizeBytes)} · ${fmtRelative(doc.updatedAt)}',
                          style: context.tt.bodySmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (!selecting)
                PopupMenuButton<String>(
                  tooltip: 'More for ${doc.name}',
                  icon: Icon(Icons.more_vert_rounded, color: px.muted),
                  onSelected: (v) {
                    switch (v) {
                      case 'share':
                        shareDocs(context, ref, [doc]);
                      case 'rename':
                        renameDoc(context, ref, doc);
                      case 'compress':
                        context.push('/tool/compress?id=${doc.id}');
                      case 'delete':
                        deleteDocs(context, ref, [doc]);
                    }
                  },
                  itemBuilder: (_) => [
                    _item('share', Icons.ios_share_rounded, 'Share'),
                    _item(
                      'rename',
                      Icons.drive_file_rename_outline_rounded,
                      'Rename',
                    ),
                    _item('compress', Icons.compress_rounded, 'Compress'),
                    _item(
                      'delete',
                      Icons.delete_outline_rounded,
                      'Delete',
                      color: px.danger,
                    ),
                  ],
                )
              else
                const SizedBox(width: 12),
            ],
          ),
        ),
      ),
    );
  }

  PopupMenuItem<String> _item(
    String v,
    IconData icon,
    String label, {
    Color? color,
  }) => PopupMenuItem(
    value: v,
    child: Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    ),
  );
}

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.count,
    required this.onClose,
    required this.onShare,
    required this.onMerge,
    required this.onDelete,
  });
  final int count;
  final VoidCallback onClose, onShare, onDelete;
  final VoidCallback? onMerge;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final px = context.px;
    Widget action(
      IconData icon,
      String label,
      VoidCallback? onTap, {
      Color? color,
    }) {
      final c = onTap == null
          ? px.muted.withValues(alpha: 0.5)
          : (color ?? context.cs.onSurface);
      return Semantics(
        button: true,
        enabled: onTap != null,
        label: label,
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: SizedBox(
            width: 64,
            height: 56,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: c, size: 22),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: c,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Material(
      color: dark ? const Color(0xFF161A26) : Colors.white,
      borderRadius: BorderRadius.circular(22),
      child: Container(
        padding: const EdgeInsets.fromLTRB(4, 4, 8, 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: px.glassBorder),
          boxShadow: [
            BoxShadow(
              color: dark ? const Color(0x80000000) : const Color(0x2414183C),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Cancel selection',
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded),
            ),
            Expanded(
              child: Text(
                '$count selected',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
            action(Icons.ios_share_rounded, 'Share', onShare),
            action(Icons.layers_rounded, 'Merge', onMerge),
            action(
              Icons.delete_outline_rounded,
              'Delete',
              onDelete,
              color: px.danger,
            ),
          ],
        ),
      ),
    );
  }
}
