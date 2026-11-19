import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../documents/data/doc_repository.dart';
import '../../documents/data/documents_provider.dart';
import '../../documents/data/stored_doc.dart';
import '../../documents/presentation/doc_actions.dart';
import '../../documents/presentation/doc_tile.dart';
import '../domain/compression.dart';

const _indigo = Color(0xFF5B3DF5);

enum _Mode {
  balanced('Balanced'),
  high('High Compression'),
  target('Target Size (KB)');

  const _Mode(this.label);
  final String label;
}

typedef _Plan = ({int quality, double scale, int estimate, bool fits});

/// Compress a PDF with a preset, or to fit under a size limit for upload portals
/// and email. Estimates re-encode page 1; everything runs on the device.
class CompressScreen extends ConsumerStatefulWidget {
  const CompressScreen({super.key, this.initialId, this.startInTarget = false});
  final String? initialId;

  /// Opened as "Target KB": start in Target Size mode.
  final bool startInTarget;

  @override
  ConsumerState<CompressScreen> createState() => _CompressScreenState();
}

class _CompressScreenState extends ConsumerState<CompressScreen> {
  static const _defaultKb = 500;
  static const _minKb = 50;

  String? _id;
  String? _targetFor; // doc the KB target was suggested for
  late var _mode = widget.startInTarget ? _Mode.target : _Mode.balanced;
  var _targetKb = _defaultKb;
  final _kbField = TextEditingController(text: '$_defaultKb');
  final _kbFocus = FocusNode();

  Map<CompressLevel, int>? _est;
  _Plan? _plan;
  var _seq = 0;
  Timer? _debounce;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _id = widget.initialId;
    _kbFocus.addListener(() {
      if (!_kbFocus.hasFocus) _commitField();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _kbField.dispose();
    _kbFocus.dispose();
    super.dispose();
  }

  // ---- estimates --------------------------------------------------------------

  Future<void> _estimatePresets(String id) async {
    final seq = ++_seq;
    setState(() => _est = null);
    final n = ref.read(documentsProvider.notifier);
    final out = {
      for (final l in [CompressLevel.medium, CompressLevel.high])
        l: await n.estimate(id, l),
    };
    if (mounted && seq == _seq) setState(() => _est = out);
  }

  void _planSoon(String id) {
    _debounce?.cancel();
    setState(() => _plan = null);
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final seq = ++_seq;
      final p = await ref
          .read(documentsProvider.notifier)
          .planTarget(id, _targetKb * 1000);
      if (mounted && seq == _seq) setState(() => _plan = p);
    });
  }

  void _refresh(StoredDoc d) {
    if (_mode == _Mode.target) {
      if (d.sizeBytes > _targetKb * 1000) _planSoon(d.id);
    } else {
      _estimatePresets(d.id);
    }
  }

  // ---- target KB input --------------------------------------------------------

  int _maxKb(StoredDoc d) => math.max(_minKb * 2, (d.sizeBytes / 1000).ceil());

  /// Slider position (0..1) ↔ KB on a log scale, so small limits are easy to set.
  double _toSlider(int kb, int max) =>
      math.log(kb / _minKb) / math.log(max / _minKb);

  int _fromSlider(double v, int max) {
    final raw = _minKb * math.pow(max / _minKb, v);
    final step = raw < 200 ? 10 : (raw < 1000 ? 25 : 100);
    return ((raw / step).round() * step).clamp(_minKb, max).toInt();
  }

  void _setTarget(int kb, StoredDoc d) {
    final v = kb.clamp(_minKb, _maxKb(d));
    setState(() => _targetKb = v);
    _kbField.text = '$v';
    _refresh(d);
  }

  void _commitField() {
    final d = _doc;
    if (d == null) return;
    final kb = int.tryParse(_kbField.text) ?? _targetKb;
    final v = kb.clamp(_minKb, _maxKb(d));
    _kbField.text = '$v';
    if (v != _targetKb) {
      setState(() => _targetKb = v);
      _refresh(d);
    }
  }

  StoredDoc? get _doc {
    final docs = ref.read(documentsProvider).value ?? const <StoredDoc>[];
    return docs.where((d) => d.id == _id).firstOrNull;
  }

  /// A sensible first limit for [d]: 500 KB for big files, else a round number
  /// about 30 % below its current size, so the target always means "smaller".
  int _suggestKb(StoredDoc d) {
    final kb = d.sizeBytes / 1000;
    if (kb > 700) return _defaultKb;
    for (final c in const [400, 300, 250, 200, 150, 100, 75]) {
      if (c <= kb * 0.7) return c;
    }
    return _minKb;
  }

  void _suggestFor(StoredDoc d) {
    _targetFor = d.id;
    _targetKb = _suggestKb(d);
    _kbField.text = '$_targetKb';
  }

  // ---- actions ------------------------------------------------------------------

  void _reset(StoredDoc d) {
    Haptics.select();
    setState(() {
      _mode = _Mode.balanced;
      _suggestFor(d);
    });
    _estimatePresets(d.id);
  }

  Future<void> _change(List<StoredDoc> docs) async {
    Haptics.light();
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8),
                child: Text('Choose a PDF', style: context.tt.titleLarge),
              ),
              for (final d in docs)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  leading: DocThumb(d, width: 36, height: 46),
                  title: Text(
                    d.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${fmtSize(d.sizeBytes)} · ${plural(d.pageCount, 'page')}',
                  ),
                  trailing: d.id == _id
                      ? const Icon(Icons.check_rounded, color: _indigo)
                      : null,
                  onTap: () => Navigator.pop(context, d.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || picked == _id || !mounted) return;
    final d = docs.firstWhere((x) => x.id == picked);
    setState(() {
      _id = picked;
      _est = null;
      _plan = null;
      _suggestFor(d);
    });
    _refresh(d);
  }

  Future<void> _run(StoredDoc d) async {
    FocusScope.of(context).unfocus();
    setState(() => _progress = 0);
    final n = ref.read(documentsProvider.notifier);
    void onProgress(double v) {
      if (mounted) setState(() => _progress = v);
    }

    String msg;
    try {
      if (_mode == _Mode.target) {
        final r = await n.compressToTarget(
          d.id,
          _targetKb * 1000,
          onProgress: onProgress,
        );
        msg = r.reached
            ? 'Now ${fmtSize(r.after)} · under $_targetKb KB'
            : r.after < r.before
            ? 'Now ${fmtSize(r.after)}: as small as it can go and stay readable'
            : 'Couldn’t make this PDF smaller';
      } else {
        final r = await n.compress(
          d.id,
          _mode == _Mode.high ? CompressLevel.high : CompressLevel.medium,
          onProgress: onProgress,
        );
        final saved = r.before - r.after;
        msg = saved > 0
            ? 'Saved ${fmtSize(saved)} · now ${fmtSize(r.after)}'
            : 'Already as small as this level allows';
      }
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
    showToast(context, msg);
  }

  // ---- UI -------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).value ?? const <StoredDoc>[];
    final dark = Theme.of(context).brightness == Brightness.dark;
    final bg = dark
        ? const BoxDecoration(color: Color(0xFF0D0F17))
        : const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFFF4F2FF), Color(0xFFFFFFFF), Color(0xFFEFFAF6)],
              stops: [0, 0.5, 1],
            ),
          );

    if (docs.isEmpty) {
      return DecoratedBox(
        decoration: bg,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            title: const Text('Compress PDF'),
          ),
          body: const EmptyState(
            icon: Icons.compress_rounded,
            title: 'No documents yet',
            body: 'Scan or import a PDF first.',
          ),
        ),
      );
    }
    if (_id == null || !docs.any((d) => d.id == _id)) {
      _id = ([
        ...docs,
      ]..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes))).first.id;
    }
    final doc = docs.firstWhere((d) => d.id == _id);
    if (_targetFor != doc.id) _suggestFor(doc);
    if (_est == null && _seq == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _refresh(doc));
    }
    final busy = _progress != null;
    final card = dark ? const Color(0xFF161A26) : Colors.white;

    return DecoratedBox(
      decoration: bg,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          title: const Text('Compress PDF'),
          actions: [
            TextButton(
              onPressed: busy ? null : () => _reset(doc),
              child: const Text('Reset'),
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
            children: [
              _FileCard(
                doc: doc,
                color: card,
                onChange: busy || docs.length < 2 ? null : () => _change(docs),
              ),
              const SizedBox(height: 22),
              const _Label('Compression'),
              const SizedBox(height: 10),
              _Segmented(
                value: _mode,
                onChanged: busy
                    ? null
                    : (m) {
                        Haptics.select();
                        setState(() => _mode = m);
                        _refresh(doc);
                      },
              ),
              const SizedBox(height: 14),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _mode == _Mode.target
                    ? _targetPanel(doc, card, busy)
                    : _presetPanel(doc, card),
              ),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
          minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Cta(
                progress: _progress,
                // Nothing to do when the file already fits the limit.
                onTap:
                    busy ||
                        (_mode == _Mode.target &&
                            doc.sizeBytes <= _targetKb * 1000)
                    ? null
                    : () => _run(doc),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_rounded, size: 14, color: context.px.muted),
                  const SizedBox(width: 6),
                  Text(
                    'Processed locally on device',
                    style: TextStyle(
                      color: context.px.muted,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _presetPanel(StoredDoc doc, Color card) {
    final level = _mode == _Mode.high
        ? CompressLevel.high
        : CompressLevel.medium;
    final est = _est?[level];
    return Container(
      key: ValueKey(_mode),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: _cardDeco(context, card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _mode == _Mode.high
                ? 'Smallest file · ~110 DPI. Fine for reading on screen.'
                : 'Recommended · ~150 DPI. Sharp text, much smaller.',
            style: context.tt.bodyMedium,
          ),
          const SizedBox(height: 14),
          est == null
              ? const _EstimatePending()
              : _EstimateBadge(estimate: est, original: doc.sizeBytes),
        ],
      ),
    );
  }

  Widget _targetPanel(StoredDoc doc, Color card, bool busy) {
    final max = _maxKb(doc);
    final already = doc.sizeBytes <= _targetKb * 1000;
    final plan = _plan;
    final presets = [100, 200, 300, 500, 1000]
        .where((k) => k < max * 0.9) // only limits that actually shrink it
        .toList();
    return Container(
      key: const ValueKey(_Mode.target),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      decoration: _cardDeco(context, card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('Keep it under', style: context.tt.titleMedium),
              ),
              SizedBox(
                width: 132,
                child: TextField(
                  controller: _kbField,
                  focusNode: _kbFocus,
                  enabled: !busy,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  textAlign: TextAlign.right,
                  onSubmitted: (_) => _commitField(),
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: 'e.g. 500',
                    suffixText: 'KB',
                    suffixStyle: TextStyle(
                      color: context.px.muted,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: _indigo, width: 2),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: _indigo,
              thumbColor: _indigo,
              overlayColor: _indigo.withValues(alpha: 0.12),
              inactiveTrackColor: _indigo.withValues(alpha: 0.15),
              trackHeight: 6,
            ),
            child: Slider(
              value: _toSlider(_targetKb, max).clamp(0.0, 1.0),
              semanticFormatterCallback: (v) => '${_fromSlider(v, max)} KB',
              onChanged: busy
                  ? null
                  : (v) {
                      final kb = _fromSlider(v, max);
                      if (kb != _targetKb) {
                        Haptics.select();
                        _setTarget(kb, doc);
                      }
                    },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _Tabular('$_minKb KB', context.px.muted),
                _Tabular('${fmtSize(doc.sizeBytes)} (now)', context.px.muted),
              ],
            ),
          ),
          if (presets.isNotEmpty) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in presets)
                  ChoiceChip(
                    label: Text(
                      k >= 1000 ? '${k ~/ 1000} MB' : '$k KB',
                      style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    selected: _targetKb == k,
                    onSelected: busy
                        ? null
                        : (_) {
                            Haptics.select();
                            _setTarget(k, doc);
                          },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          if (already)
            _EstimateBadge.message(
              'Already under $_targetKb KB',
              Icons.check_circle_rounded,
            )
          else if (plan == null)
            const _EstimatePending()
          else if (plan.fits) ...[
            _EstimateBadge(estimate: plan.estimate, original: doc.sizeBytes),
            const SizedBox(height: 8),
            Text(
              plan.scale >= 0.72
                  ? 'Text stays sharp.'
                  : plan.scale >= 0.42
                  ? 'Good for reading on screen.'
                  : 'Very small: fine print may blur.',
              style: context.tt.bodySmall,
            ),
          ] else
            _EstimateBadge.warning(
              'Can’t reach $_targetKb KB · smallest ~${fmtSize(plan.estimate)}',
            ),
        ],
      ),
    );
  }
}

BoxDecoration _cardDeco(BuildContext context, Color color) => BoxDecoration(
  color: color,
  borderRadius: BorderRadius.circular(20),
  border: Border.all(color: context.px.hairline),
  boxShadow: const [
    BoxShadow(color: Color(0x0F14183C), blurRadius: 18, offset: Offset(0, 6)),
  ],
);

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: TextStyle(
      color: context.px.muted,
      fontSize: 12,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.8,
    ),
  );
}

class _Tabular extends StatelessWidget {
  const _Tabular(this.text, this.color);
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: TextStyle(
      color: color,
      fontSize: 12,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
  );
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.doc,
    required this.color,
    required this.onChange,
  });
  final StoredDoc doc;
  final Color color;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
    decoration: _cardDeco(context, color),
    child: Row(
      children: [
        DocThumb(doc, width: 44, height: 56),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                doc.name.toLowerCase().endsWith('.pdf')
                    ? doc.name
                    : '${doc.name}.pdf',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: context.tt.titleMedium,
              ),
              const SizedBox(height: 3),
              Text(
                '${fmtSize(doc.sizeBytes)} · ${plural(doc.pageCount, 'page')}',
                style: context.tt.bodySmall?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        if (onChange != null)
          TextButton(
            onPressed: onChange,
            style: TextButton.styleFrom(
              // Lighter violet on the dark card keeps the link readable (≥ 4.5:1).
              foregroundColor: Theme.of(context).brightness == Brightness.dark
                  ? const Color(0xFFB4A3FF)
                  : _indigo,
              minimumSize: const Size(48, 44),
            ),
            child: const Text('Change'),
          ),
      ],
    ),
  );
}

class _Segmented extends StatelessWidget {
  const _Segmented({required this.value, required this.onChanged});
  final _Mode value;
  final ValueChanged<_Mode>? onChanged;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF161A26) : const Color(0xFFECEAF8),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          for (final m in _Mode.values)
            Expanded(
              child: Semantics(
                button: true,
                selected: m == value,
                label: m.label,
                excludeSemantics: true,
                child: GestureDetector(
                  onTap: onChanged == null ? null : () => onChanged!(m),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    height: 44,
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: m == value
                          ? (dark ? const Color(0xFF2A2F45) : Colors.white)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: m == value
                          ? const [
                              BoxShadow(
                                color: Color(0x1A14183C),
                                blurRadius: 6,
                                offset: Offset(0, 2),
                              ),
                            ]
                          : null,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        m.label,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: m == value
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: m == value
                              ? (dark ? Colors.white : _indigo)
                              : context.px.muted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EstimatePending extends StatelessWidget {
  const _EstimatePending();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const SizedBox.square(
        dimension: 16,
        child: CircularProgressIndicator(strokeWidth: 2, color: _indigo),
      ),
      const SizedBox(width: 10),
      Text('Estimating…', style: context.tt.bodyMedium),
    ],
  );
}

/// High-contrast estimate pill: white on deep green (≈ 6:1), amber for warnings.
class _EstimateBadge extends StatelessWidget {
  _EstimateBadge({required int estimate, required int original})
    : _text =
          'Est. ~${fmtSize(estimate)} · ~${_pct(estimate, original)}% smaller',
      _icon = Icons.trending_down_rounded,
      _warn = false;

  const _EstimateBadge.message(this._text, [this._icon = Icons.info_rounded])
    : _warn = false;

  const _EstimateBadge.warning(this._text)
    : _icon = Icons.warning_amber_rounded,
      _warn = true;

  final String _text;
  final IconData _icon;
  final bool _warn;

  static int _pct(int est, int orig) =>
      orig <= 0 ? 0 : (100 * (1 - est / orig)).round().clamp(0, 99);

  @override
  Widget build(BuildContext context) {
    final bg = _warn ? const Color(0xFFFFE8B3) : const Color(0xFF0E6B49);
    final fg = _warn ? const Color(0xFF5A3A00) : Colors.white;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: 18, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _text,
                style: TextStyle(
                  color: fg,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Cta extends StatelessWidget {
  const _Cta({required this.progress, required this.onTap});
  final double? progress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: onTap == null && p == null ? 0.45 : 1,
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: Material(
          color: _indigo,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (p != null)
                  FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: p.clamp(0.0, 1.0),
                    child: const ColoredBox(color: Color(0xFF7C3AED)),
                  ),
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        p == null
                            ? Icons.compress_rounded
                            : Icons.hourglass_top_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        p == null
                            ? 'Compress PDF'
                            : 'Compressing… ${(p * 100).round()}%',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
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
