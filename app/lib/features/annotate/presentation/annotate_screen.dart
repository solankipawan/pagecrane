import 'dart:typed_data';
import 'dart:ui' as ui;

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
import '../domain/flatten.dart';
import '../domain/marks.dart';
import 'signature_pad.dart';

enum _Tool { pen, highlight, text, sign, move }

const _inkColors = [Color(0xFF111111), Color(0xFF1F3FBF), Color(0xFFD92D20)];
const _hlColors = [Color(0xFFFFD60A), Color(0xFF34C759), Color(0xFFFF5FA2)];

/// Pen, highlighter, text and signature on top of a document's pages.
/// Marks stay editable (move / resize / undo) until Save, which flattens them into the pages.
class AnnotateScreen extends ConsumerStatefulWidget {
  const AnnotateScreen({super.key, required this.id, this.initialPage = 0});
  final String id;
  final int initialPage;

  @override
  ConsumerState<AnnotateScreen> createState() => _AnnotateScreenState();
}

class _AnnotateScreenState extends ConsumerState<AnnotateScreen> {
  late int _page = widget.initialPage;
  var _tool = _Tool.pen;
  Color _ink = _inkColors.first;
  Color _hl = _hlColors.first;
  final _marks = <int, List<Mark>>{};
  final _history = <Map<int, List<Mark>>>[];
  final _sizes = <int, Size>{};
  InkMark? _active;
  int? _selected;
  Mark? _dragStart;
  Offset? _focalStart;

  /// Where the finger went down (the scale recognizer only reports after touch slop).
  Offset? _downAt;
  bool _saving = false;

  List<Mark> get _cur => _marks[_page] ?? const [];
  bool get _dirty => _marks.values.any((m) => m.isNotEmpty);

  void _snapshot() => _history.add({
    for (final e in _marks.entries) e.key: [...e.value],
  });

  void _undo() {
    if (_history.isEmpty) return;
    Haptics.select();
    setState(() {
      _marks
        ..clear()
        ..addAll(_history.removeLast());
      _selected = null;
    });
  }

  void _setCur(List<Mark> next) => _marks[_page] = next;

  Future<Size> _pageSize(int i) async {
    final cached = _sizes[i];
    if (cached != null) return cached;
    final repo = ref.read(repoSyncProvider)!;
    final buf = await ui.ImmutableBuffer.fromUint8List(
      await repo.pageOf(widget.id, i).readAsBytes(),
    );
    final desc = await ui.ImageDescriptor.encoded(buf);
    final s = Size(desc.width.toDouble(), desc.height.toDouble());
    desc.dispose();
    buf.dispose();
    return _sizes[i] = s;
  }

  int? _hit(Offset px, Size size) {
    for (var i = _cur.length - 1; i >= 0; i--) {
      if (_cur[i].bounds(size).inflate(14).contains(px)) return i;
    }
    return null;
  }

  Offset _norm(Offset p, Size s) => Offset(p.dx / s.width, p.dy / s.height);

  void _onScaleStart(ScaleStartDetails d, Size size) {
    final n = _norm(d.localFocalPoint, size);
    if (_tool == _Tool.pen || _tool == _Tool.highlight) {
      final hl = _tool == _Tool.highlight;
      final down = _downAt == null ? null : _norm(_downAt!, size);
      setState(
        () => _active = InkMark(
          points: [?down, n],
          color: hl ? _hl : _ink,
          width: hl ? 0.026 : 0.0045,
          highlighter: hl,
        ),
      );
      return;
    }
    final hit = _hit(d.localFocalPoint, size);
    setState(() => _selected = hit);
    if (hit != null) {
      _snapshot();
      _dragStart = _cur[hit];
      _focalStart = n;
    }
  }

  void _onScaleUpdate(ScaleUpdateDetails d, Size size) {
    final n = _norm(d.localFocalPoint, size);
    final a = _active;
    if (a != null) {
      if ((n - a.points.last).distance * size.width > 1.5) {
        setState(() => _active = a.adding(n));
      }
      return;
    }
    final s = _selected, start = _dragStart, f0 = _focalStart;
    if (s == null || start == null || f0 == null) return;
    setState(() {
      final next = [..._cur];
      next[s] = start.scaled(d.scale).moved(n - f0);
      _setCur(next);
    });
  }

  void _onScaleEnd() {
    final a = _active;
    if (a != null) {
      _snapshot();
      setState(() {
        _setCur([..._cur, a]);
        _active = null;
      });
    }
    _dragStart = null;
    _focalStart = null;
  }

  Future<void> _onTap(TapUpDetails d, Size size) async {
    if (_tool == _Tool.move) {
      setState(() => _selected = _hit(d.localPosition, size));
      return;
    }
    if (_tool != _Tool.text) return;
    final hit = _hit(d.localPosition, size);
    if (hit != null && _cur[hit] is TextMark) {
      setState(() => _selected = hit);
      return;
    }
    final text = await _askText();
    if (text == null || text.trim().isEmpty) return;
    _snapshot();
    setState(() {
      _setCur([
        ..._cur,
        TextMark(
          pos: _norm(d.localPosition, size),
          text: text.trim(),
          color: _ink,
          size: 0.032,
        ),
      ]);
      _selected = _cur.length - 1;
      _tool = _Tool.move;
    });
  }

  Future<String?> _askText() {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Add text'),
        content: TextField(
          controller: c,
          autofocus: true,
          maxLines: 3,
          minLines: 1,
          onSubmitted: (v) => Navigator.pop(d, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, c.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  Future<void> _addSignature() async {
    final sig = await showSignaturePad(context, ref);
    if (sig == null || !mounted) return;
    final size = await _pageSize(_page);
    // 40 % of page width, centred in the lower third; keep the drawn aspect ratio on the page.
    const w = 0.4;
    final h = w * sig.aspect * size.width / size.height;
    _snapshot();
    setState(() {
      _setCur([
        ..._cur,
        SignatureMark(
          strokes: sig.strokes,
          box: Rect.fromLTWH(0.5 - w / 2, 0.72 - h / 2, w, h),
          color: _ink,
        ),
      ]);
      _selected = _cur.length - 1;
      _tool = _Tool.move;
    });
  }

  void _deleteSelected() {
    final s = _selected;
    if (s == null) return;
    Haptics.medium();
    _snapshot();
    setState(() {
      _setCur([..._cur]..removeAt(s));
      _selected = null;
    });
  }

  Future<void> _save() async {
    final repo = ref.read(repoSyncProvider)!;
    setState(() {
      _saving = true;
      _selected = null;
    });
    final changed = <int, Uint8List>{};
    for (final e in _marks.entries.where((e) => e.value.isNotEmpty)) {
      final src = await repo.pageOf(widget.id, e.key).readAsBytes();
      changed[e.key] = await flattenPage(src, e.value);
    }
    if (changed.isNotEmpty) {
      try {
        await ref
            .read(documentsProvider.notifier)
            .updatePages(widget.id, changed);
      } on StorageException catch (e) {
        if (mounted) {
          setState(() => _saving = false);
          showSaveError(context, e);
        }
        return;
      }
    }
    Haptics.success();
    if (!mounted) return;
    context.pop();
    showToast(
      context,
      changed.isEmpty
          ? 'No changes'
          : 'Annotations saved to ${changed.length == 1 ? 'page' : '${changed.length} pages'}',
    );
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Discard annotations?'),
        content: const Text('Your marks haven’t been saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Keep editing'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final doc = ref
        .watch(documentsProvider)
        .value
        ?.where((d) => d.id == widget.id)
        .firstOrNull;
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
    final px = context.px;
    final palette = _tool == _Tool.highlight ? _hlColors : _inkColors;
    final current = _tool == _Tool.highlight ? _hl : _ink;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && await _confirmDiscard() && context.mounted) {
          context.pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close_rounded),
            onPressed: () async {
              if (await _confirmDiscard() && context.mounted) context.pop();
            },
          ),
          title: Text(
            doc.pageCount > 1
                ? 'Page ${_page + 1} of ${doc.pageCount}'
                : 'Annotate',
          ),
          actions: [
            IconButton(
              tooltip: 'Undo',
              onPressed: _history.isEmpty || _saving ? null : _undo,
              icon: const Icon(Icons.undo_rounded),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                ),
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Save'),
              ),
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: FutureBuilder<Size>(
                future: _pageSize(_page),
                initialData:
                    _sizes[_page], // cached: no spinner flash on rebuilds
                builder: (context, snap) {
                  final img = snap.data;
                  if (img == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Center(
                      child: AspectRatio(
                        aspectRatio: img.width / img.height,
                        child: LayoutBuilder(
                          builder: (context, c) {
                            final size = c.biggest;
                            return Listener(
                              onPointerDown: (e) => _downAt = e.localPosition,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onScaleStart: (d) => _onScaleStart(d, size),
                                onScaleUpdate: (d) => _onScaleUpdate(d, size),
                                onScaleEnd: (_) => _onScaleEnd(),
                                onTapUp: (d) => _onTap(d, size),
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
                                  child: ClipRect(
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        Image.file(
                                          repo.pageOf(doc.id, _page),
                                          key: ValueKey(
                                            '${doc.updatedAt}$_page',
                                          ),
                                          fit: BoxFit.fill,
                                          gaplessPlayback: true,
                                        ),
                                        CustomPaint(
                                          painter: MarksPainter(
                                            marks: _cur,
                                            active: _active,
                                            selected: _selected,
                                            selectionColor: context.cs.primary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (doc.pageCount > 1)
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Previous page',
                    onPressed: _page == 0
                        ? null
                        : () => setState(() {
                            _page--;
                            _selected = null;
                          }),
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Text(
                    '${_page + 1} / ${doc.pageCount}',
                    style: context.tt.bodySmall,
                  ),
                  IconButton(
                    tooltip: 'Next page',
                    onPressed: _page >= doc.pageCount - 1
                        ? null
                        : () => setState(() {
                            _page++;
                            _selected = null;
                          }),
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              ),
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: px.hairline)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 48,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_tool != _Tool.move && _tool != _Tool.sign)
                            for (final c in palette)
                              Semantics(
                                button: true,
                                selected: c == current,
                                label: 'Colour',
                                child: GestureDetector(
                                  onTap: () {
                                    Haptics.select();
                                    setState(
                                      () => _tool == _Tool.highlight
                                          ? _hl = c
                                          : _ink = c,
                                    );
                                  },
                                  child: Container(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                    ),
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: c,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: c == current
                                            ? context.cs.primary
                                            : px.hairline,
                                        width: c == current ? 3 : 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          if (_selected != null &&
                              (_tool == _Tool.move || _tool == _Tool.text))
                            TextButton.icon(
                              onPressed: _deleteSelected,
                              icon: Icon(
                                Icons.delete_outline_rounded,
                                color: px.danger,
                              ),
                              label: Text(
                                'Delete',
                                style: TextStyle(color: px.danger),
                              ),
                            ),
                          if (_tool == _Tool.move && _selected == null)
                            Text(
                              'Tap a mark to select · drag to move · pinch to resize',
                              style: context.tt.bodySmall,
                            ),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        _ToolButton(
                          icon: Icons.edit_rounded,
                          label: 'Pen',
                          on: _tool == _Tool.pen,
                          onTap: () => _pick(_Tool.pen),
                        ),
                        _ToolButton(
                          icon: Icons.border_color_rounded,
                          label: 'Highlight',
                          on: _tool == _Tool.highlight,
                          onTap: () => _pick(_Tool.highlight),
                        ),
                        _ToolButton(
                          icon: Icons.text_fields_rounded,
                          label: 'Text',
                          on: _tool == _Tool.text,
                          onTap: () => _pick(_Tool.text),
                        ),
                        _ToolButton(
                          icon: Icons.draw_rounded,
                          label: 'Sign',
                          on: _tool == _Tool.sign,
                          onTap: _addSignature,
                        ),
                        _ToolButton(
                          icon: Icons.open_with_rounded,
                          label: 'Move',
                          on: _tool == _Tool.move,
                          onTap: () => _pick(_Tool.move),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _pick(_Tool t) {
    Haptics.select();
    setState(() {
      _tool = t;
      if (t == _Tool.pen || t == _Tool.highlight) _selected = null;
    });
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = on ? context.cs.primary : context.cs.onSurface;
    return Expanded(
      child: Semantics(
        selected: on,
        button: true,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: c),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: on ? c : context.px.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
