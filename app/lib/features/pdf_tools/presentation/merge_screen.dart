import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/status_cards.dart';
import '../../documents/data/doc_repository.dart';
import '../../documents/data/documents_provider.dart';
import '../../documents/presentation/doc_actions.dart';
import '../../documents/data/pdf_import.dart';
import '../../documents/data/stored_doc.dart';
import '../../documents/presentation/doc_tile.dart';

/// Something to merge: a library document or a PDF picked from Files.
sealed class _Item {
  String get key;
}

class _Lib extends _Item {
  _Lib(this.id);
  final String id;
  @override
  String get key => id;
}

enum _Trouble { locked, broken }

class _Ext extends _Item {
  _Ext(this.path, this.name, this.size);
  final String path, name;
  final int size;
  String? password;
  @override
  String get key => 'file:$path';
}

/// Pick documents (library or Files), drag to set order, merge into a new PDF.
/// Outside PDFs can be locked or damaged: that shows a fix-it card instead of
/// failing silently. Merging shows page-by-page progress and can be cancelled.
class MergeScreen extends ConsumerStatefulWidget {
  const MergeScreen({super.key, this.initialIds = const []});

  /// Library documents to start with (from multi-select in Tools & Files).
  final List<String> initialIds;

  @override
  ConsumerState<MergeScreen> createState() => _MergeScreenState();
}

class _MergeScreenState extends ConsumerState<MergeScreen> {
  final _items = <_Item>[];
  ({_Ext item, _Trouble kind})? _issue;

  /// Null when idle. total == 0 while files are being opened.
  ({int done, int total, String step})? _prog;
  bool _cancel = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _items.addAll([for (final id in widget.initialIds) _Lib(id)]);
  }

  // ---- items ------------------------------------------------------------------

  Future<void> _addFile() async {
    Haptics.light();
    final p = await PdfImporter.pick();
    if (p == null || !mounted) return;
    if (_items.any((i) => i.key == 'file:${p.path}')) return;
    var size = 0;
    try {
      size = await File(p.path).length();
    } catch (_) {}
    setState(() => _items.add(_Ext(p.path, p.name, size)));
  }

  String _nameOf(_Item i, Map<String, StoredDoc> byId) => switch (i) {
    _Lib(:final id) => byId[id]?.name ?? 'Document',
    _Ext(:final name) => name,
  };

  // ---- merge ------------------------------------------------------------------

  Future<void> _merge() async {
    final notifier = ref.read(documentsProvider.notifier);
    final byId = {
      for (final d in ref.read(documentsProvider).value ?? const <StoredDoc>[])
        d.id: d,
    };
    final items = [..._items];
    setState(() {
      _issue = null;
      _cancel = false;
      _saving = false;
      _prog = (done: 0, total: 0, step: 'Opening files…');
    });

    final opened = <_Ext, PdfDocument>{};
    Future<void> closeAll() async {
      for (final d in opened.values) {
        await d.dispose();
      }
      opened.clear();
    }

    void fail(_Ext e, _Trouble kind) {
      Haptics.medium();
      if (mounted) {
        setState(() {
          _prog = null;
          _issue = (item: e, kind: kind);
        });
      }
    }

    void cancelled() {
      if (!mounted) return;
      setState(() => _prog = null);
      showToast(context, 'Merge cancelled', icon: Icons.close_rounded);
    }

    // 1. Open outside PDFs first, so a locked or damaged file is caught before work.
    for (final e in items.whereType<_Ext>()) {
      var asked = 0;
      try {
        opened[e] = await PdfImporter.open(
          e.path,
          // First ask: the password given via "Unlock File" (if any); then give up.
          askPassword: () async => asked++ == 0 ? e.password : null,
        );
      } on PdfPasswordException {
        await closeAll();
        return fail(e, _Trouble.locked);
      } on Object {
        await closeAll();
        return fail(e, _Trouble.broken);
      }
      if (_cancel) {
        await closeAll();
        return cancelled();
      }
    }

    // 2. Collect pages in order.
    final total = items.fold(
      0,
      (a, i) =>
          a +
          switch (i) {
            _Lib(:final id) => byId[id]?.pageCount ?? 0,
            _Ext() => opened[i]?.pages.length ?? 0,
          },
    );
    var done = 0;
    final pages = <Uint8List>[];
    for (final it in items) {
      if (_cancel) {
        await closeAll();
        return cancelled();
      }
      final name = _nameOf(it, byId);
      switch (it) {
        case _Lib(:final id):
          for (final p in await notifier.pagesOf(id)) {
            pages.add(p);
            done++;
            if (mounted) {
              setState(() => _prog = (done: done, total: total, step: name));
            }
          }
        case _Ext():
          final doc = opened.remove(it)!;
          final base = done;
          try {
            final rendered = await PdfImporter.render(
              doc,
              onProgress: (d, _) {
                if (mounted) {
                  setState(
                    () => _prog = (done: base + d, total: total, step: name),
                  );
                }
              },
              isCancelled: () => _cancel,
            );
            pages.addAll(rendered);
            done += rendered.length;
          } on PdfImportCancelled {
            await closeAll();
            return cancelled();
          } on Object {
            await closeAll();
            return fail(it, _Trouble.broken);
          }
      }
    }

    // 3. Save as a new document (not cancellable: it's quick and atomic).
    if (!mounted) return;
    setState(() {
      _saving = true;
      _prog = (done: total, total: total, step: 'Saving…');
    });
    final first = items.first;
    final StoredDoc doc;
    try {
      doc = await notifier.add(
        name: 'Merged — ${_nameOf(first, byId)}',
        folder: first is _Lib ? (byId[first.id]?.folder ?? 'Merged') : 'Merged',
        pages: pages,
      );
    } on StorageException catch (e) {
      if (mounted) {
        setState(() {
          _prog = null;
          _saving = false;
        });
        showSaveError(context, e);
      }
      return;
    }
    Haptics.success();
    if (!mounted) return;
    context.pop();
    context.push('/doc/${doc.id}');
    showToast(
      context,
      'Merged ${plural(items.length, 'file')} · ${plural(doc.pageCount, 'page')}',
    );
  }

  Future<void> _unlock(_Ext e) async {
    final pw = await _askPassword(context, e.name);
    if (pw == null || pw.isEmpty || !mounted) return;
    e.password = pw;
    setState(() => _issue = null);
    _merge();
  }

  void _removeAndRetry(_Ext e) {
    Haptics.select();
    setState(() {
      _items.remove(e);
      _issue = null;
    });
    if (_items.length >= 2) _merge();
  }

  // ---- UI -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).value ?? const <StoredDoc>[];
    final byId = {for (final d in docs) d.id: d};
    _items.removeWhere((i) => i is _Lib && !byId.containsKey(i.id));
    final picked = _items.whereType<_Lib>().map((i) => i.id).toSet();
    final rest = docs.where((d) => !picked.contains(d.id)).toList();
    final busy = _prog != null;
    final issue = _issue;
    final px = context.px;

    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) setState(() => _cancel = true);
      },
      child: Scaffold(
        appBar: AppBar(title: const Text('Merge PDFs')),
        body: CustomScrollView(
          slivers: [
            if (issue != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: IssueCard(
                    title: 'Couldn’t merge selected files',
                    reason: issue.kind == _Trouble.locked
                        ? '“${issue.item.name}.pdf” appears to be password-protected.'
                        : '“${issue.item.name}.pdf” appears to be corrupted or isn’t a valid PDF.',
                    icon: issue.kind == _Trouble.locked
                        ? Icons.lock_outline_rounded
                        : Icons.error_outline_rounded,
                    primaryLabel: issue.kind == _Trouble.locked
                        ? 'Unlock File'
                        : 'Remove & Retry',
                    onPrimary: issue.kind == _Trouble.locked
                        ? () => _unlock(issue.item)
                        : () => _removeAndRetry(issue.item),
                    secondaryLabel: issue.kind == _Trouble.locked
                        ? 'Remove & Retry'
                        : null,
                    onSecondary: () => _removeAndRetry(issue.item),
                    onDismiss: () => setState(() => _issue = null),
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _items.isEmpty
                            ? 'Add documents below, or a PDF from Files.'
                            : 'In this order · drag the handles to reorder',
                        style: context.tt.bodySmall,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: busy ? null : _addFile,
                      icon: const Icon(Icons.upload_file_rounded, size: 20),
                      label: const Text('Add PDF'),
                    ),
                  ],
                ),
              ),
            ),
            SliverReorderableList(
              itemCount: _items.length,
              onReorderItem: (a, b) {
                Haptics.light();
                setState(() => _items.insert(b, _items.removeAt(a)));
              },
              itemBuilder: (context, i) {
                final it = _items[i];
                final trouble = issue != null && identical(issue.item, it)
                    ? issue.kind
                    : null;
                final (Widget thumb, String title, String sub) = switch (it) {
                  _Lib(:final id) => (
                    DocThumb(byId[id]!, width: 34, height: 44),
                    byId[id]!.name,
                    '${plural(byId[id]!.pageCount, 'page')} · ${fmtSize(byId[id]!.sizeBytes)}',
                  ),
                  _Ext() => (
                    _FileThumb(locked: trouble == _Trouble.locked),
                    '${it.name}.pdf',
                    switch (trouble) {
                      _Trouble.locked => 'Password-protected',
                      _Trouble.broken => 'Can’t be read',
                      null =>
                        'From Files · ${fmtSize(it.size)}${it.password != null ? ' · unlocked' : ''}',
                    },
                  ),
                };
                return Padding(
                  key: ValueKey(it.key),
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
                          thumb,
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: context.tt.titleMedium,
                                ),
                                Text(
                                  sub,
                                  style: context.tt.bodySmall?.copyWith(
                                    color: trouble != null ? px.danger : null,
                                    fontWeight: trouble != null
                                        ? FontWeight.w600
                                        : null,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove',
                            icon: const Icon(Icons.close_rounded),
                            onPressed: busy
                                ? null
                                : () => setState(() {
                                    _items.removeAt(i);
                                    if (trouble != null) _issue = null;
                                  }),
                          ),
                          ReorderableDragStartListener(
                            index: i,
                            enabled: !busy,
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
                enabled: !busy,
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
                  setState(() => _items.add(_Lib(rest[i].id)));
                },
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 140)),
          ],
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: busy ? _progressCard() : _mergeButton(byId),
          ),
        ),
      ),
    );
  }

  Widget _progressCard() {
    final p = _prog!;
    return ProgressCard(
      key: const ValueKey('progress'),
      title: p.total == 0
          ? 'Preparing files…'
          : _saving
          ? 'Saving merged PDF…'
          : 'Merging ${p.done} of ${p.total} pages…',
      detail: p.total == 0 || _saving ? null : p.step,
      value: p.total == 0 ? null : p.done / p.total,
      onCancel: _saving || _cancel
          ? null
          : () {
              Haptics.select();
              setState(() => _cancel = true);
            },
    );
  }

  Widget _mergeButton(Map<String, StoredDoc> byId) {
    final n = _items.length;
    final libPages = _items.whereType<_Lib>().fold(
      0,
      (a, i) => a + (byId[i.id]?.pageCount ?? 0),
    );
    final hasExt = _items.any((i) => i is _Ext);
    return SizedBox(
      key: const ValueKey('button'),
      width: double.infinity,
      height: 52,
      child: FilledButton.icon(
        onPressed: n < 2 ? null : _merge,
        icon: const Icon(Icons.layers_rounded),
        label: Text(
          n < 2
              ? 'Pick at least 2'
              : hasExt
              ? 'Merge ${plural(n, 'file')}'
              : 'Merge ${plural(n, 'file')} · $libPages pages',
        ),
      ),
    );
  }
}

class _FileThumb extends StatelessWidget {
  const _FileThumb({required this.locked});
  final bool locked;

  @override
  Widget build(BuildContext context) => Container(
    width: 34,
    height: 44,
    decoration: BoxDecoration(
      color: context.px.pdf.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Icon(
      locked ? Icons.lock_rounded : Icons.picture_as_pdf_rounded,
      size: 20,
      color: context.px.pdf,
    ),
  );
}

Future<String?> _askPassword(BuildContext context, String name) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Unlock file'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Enter the password for “$name.pdf”. It’s only used to open the file on this device.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (v) => Navigator.pop(d, v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, c.text),
          child: const Text('Unlock'),
        ),
      ],
    ),
  );
}
