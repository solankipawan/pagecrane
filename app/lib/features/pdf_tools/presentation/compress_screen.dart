import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../documents/data/documents_provider.dart';
import '../../documents/data/stored_doc.dart';
import '../domain/compression.dart';

/// Pick a document and a level; estimates come from re-encoding page 1.
class CompressScreen extends ConsumerStatefulWidget {
  const CompressScreen({super.key, this.initialId});
  final String? initialId;

  @override
  ConsumerState<CompressScreen> createState() => _CompressScreenState();
}

class _CompressScreenState extends ConsumerState<CompressScreen> {
  String? _id;
  var _level = CompressLevel.medium;
  Map<CompressLevel, int>? _est;
  int _estSeq = 0;
  double? _progress;

  @override
  void initState() {
    super.initState();
    _id = widget.initialId;
  }

  Future<void> _estimate(String id) async {
    final seq = ++_estSeq;
    setState(() => _est = null);
    final n = ref.read(documentsProvider.notifier);
    final out = {
      for (final l in CompressLevel.values) l: await n.estimate(id, l),
    };
    if (mounted && seq == _estSeq) {
      setState(() => _est = out); // ignore stale results
    }
  }

  Future<void> _run(StoredDoc d) async {
    setState(() => _progress = 0);
    final r = await ref
        .read(documentsProvider.notifier)
        .compress(
          d.id,
          _level,
          onProgress: (v) {
            if (mounted) setState(() => _progress = v);
          },
        );
    Haptics.success();
    if (!mounted) return;
    final saved = r.before - r.after;
    context.pop();
    showToast(
      context,
      saved > 0
          ? 'Saved ${fmtSize(saved)} · now ${fmtSize(r.after)}'
          : 'Already as small as this level allows',
    );
  }

  @override
  Widget build(BuildContext context) {
    final docs = ref.watch(documentsProvider).value ?? const <StoredDoc>[];
    if (docs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Compress PDF')),
        body: const EmptyState(
          icon: Icons.compress_rounded,
          title: 'No documents yet',
        ),
      );
    }
    if (_id == null || !docs.any((d) => d.id == _id)) {
      _id = ([
        ...docs,
      ]..sort((a, b) => b.sizeBytes.compareTo(a.sizeBytes))).first.id;
    }
    final doc = docs.firstWhere((d) => d.id == _id);
    if (_est == null && _estSeq == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _estimate(doc.id));
    }
    final px = context.px;

    return Scaffold(
      appBar: AppBar(title: const Text('Compress PDF')),
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
                      onSelected: _progress != null
                          ? null
                          : (_) {
                              Haptics.select();
                              setState(() => _id = d.id);
                              _estimate(d.id);
                            },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(
            'Original ${fmtSize(doc.sizeBytes)} · ${plural(doc.pageCount, 'page')}',
            style: context.tt.bodySmall,
          ),
          const SizedBox(height: 10),
          RadioGroup<CompressLevel>(
            groupValue: _level,
            onChanged: (l) {
              if (l == null) return;
              Haptics.select();
              setState(() => _level = l);
            },
            child: Column(
              children: [
                for (final l in CompressLevel.values)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Material(
                      color: l == _level
                          ? context.cs.primary.withValues(alpha: 0.08)
                          : px.surfaceStrong,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                        side: BorderSide(
                          color: l == _level ? context.cs.primary : px.hairline,
                          width: 2,
                        ),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () {
                          Haptics.select();
                          setState(() => _level = l);
                        },
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(4, 10, 14, 10),
                          child: Row(
                            children: [
                              Radio<CompressLevel>(value: l),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l.label,
                                      style: context.tt.titleMedium,
                                    ),
                                    Text(
                                      l.subtitle,
                                      style: context.tt.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              if (_est == null)
                                const Skeleton(width: 64, height: 28)
                              else
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      '~${fmtSize(_est![l]!)}',
                                      style: context.tt.titleMedium,
                                    ),
                                    Text(
                                      '−${(100 * (1 - _est![l]! / doc.sizeBytes)).round().clamp(0, 100)}%',
                                      style: TextStyle(
                                        color: px.success,
                                        fontWeight: FontWeight.w700,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Text(
            'Estimate: page 1 is re-encoded at each level and scaled by page count. The original is kept if the result isn’t smaller.',
            style: context.tt.bodySmall,
          ),
          if (_progress != null) ...[
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
          onPressed: _progress != null ? null : () => _run(doc),
          icon: const Icon(Icons.compress_rounded),
          label: Text(
            _est == null
                ? 'Compress'
                : 'Compress to ~${fmtSize(_est![_level]!)}',
          ),
        ),
      ),
    );
  }
}
