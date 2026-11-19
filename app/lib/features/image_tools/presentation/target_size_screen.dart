import 'package:flutter/foundation.dart' show compute;

import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../scanner/domain/page_pipeline.dart';

typedef _Result = ({Uint8List bytes, int width, int height, int quality});

/// Image → under N KB (binary search on quality, then downscale) or → scale by %.
class TargetSizeScreen extends StatefulWidget {
  const TargetSizeScreen({super.key, this.scaleMode = false});
  final bool scaleMode;

  @override
  State<TargetSizeScreen> createState() => _TargetSizeScreenState();
}

class _TargetSizeScreenState extends State<TargetSizeScreen> {
  static const _presets = [20, 50, 100, 200, 500];
  late bool _scale = widget.scaleMode;
  int _targetKb = 100;
  double _pct = 60;
  double _quality = 85;
  Uint8List? _src;
  String _name = 'image';
  (int, int)? _dims;
  _Result? _result;
  bool _busy = false, _failed = false;
  final _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final f = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    );
    if (f == null) return;
    final bytes = await f.readAsBytes();
    final dims = await compute(imageDims, bytes);
    if (!mounted) return;
    if (dims == null) {
      showToast(
        context,
        'Could not read that image',
        icon: Icons.error_outline_rounded,
      );
      return;
    }
    setState(() {
      _src = bytes;
      _dims = dims;
      _name = f.name.replaceAll(RegExp(r'\.[^.]+$'), '');
      _result = null;
      _failed = false;
    });
  }

  Future<void> _run() async {
    final src = _src;
    if (src == null) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    _Result? r;
    if (_scale) {
      final scale = _pct / 100, q = _quality.round();
      final bytes = await compute(reencode, (
        src: src,
        scale: scale,
        quality: q,
      ));
      final d = _dims!;
      r = (
        bytes: bytes,
        width: (d.$1 * scale).round(),
        height: (d.$2 * scale).round(),
        quality: q,
      );
    } else {
      final target = _targetKb * 1000;
      r = await compute(compressToTarget, (src: src, targetBytes: target));
    }
    if (!mounted) return;
    Haptics.success();
    setState(() {
      _busy = false;
      _result = r;
      _failed = r == null;
    });
  }

  Future<void> _share() async {
    final r = _result!;
    final name = _scale
        ? '$_name-${r.width}x${r.height}.jpg'
        : '$_name-${_targetKb}KB.jpg';
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile.fromData(r.bytes, mimeType: 'image/jpeg', name: name)],
        fileNameOverrides: [name],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final px = context.px;
    final r = _result;
    final src = _src;
    return Scaffold(
      appBar: AppBar(title: Text(_scale ? 'Resize image' : 'Compress to size')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        children: [
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('Target size')),
              ButtonSegment(value: true, label: Text('Scale')),
            ],
            selected: {_scale},
            onSelectionChanged: (v) => setState(() {
              _scale = v.first;
              _result = null;
              _failed = false;
            }),
          ),
          const SizedBox(height: 16),
          if (src == null)
            Pressable(
              onTap: _pick,
              semanticLabel: 'Choose an image',
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 28),
                decoration: BoxDecoration(
                  color: context.cs.primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: context.cs.primary.withValues(alpha: 0.45),
                    width: 2,
                  ),
                ),
                child: Column(
                  children: [
                    Icon(
                      Icons.add_photo_alternate_rounded,
                      size: 32,
                      color: context.cs.primary,
                    ),
                    const SizedBox(height: 8),
                    Text('Choose an image', style: context.tt.titleMedium),
                    Text(
                      'JPG, PNG, HEIC from Photos',
                      style: context.tt.bodySmall,
                    ),
                  ],
                ),
              ),
            )
          else
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: px.surfaceStrong,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: px.hairline),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      src,
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                      cacheWidth: 180,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _name,
                          style: context.tt.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${_dims!.$1} × ${_dims!.$2} px · ${fmtSize(src.length)}',
                          style: context.tt.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Choose another',
                    icon: const Icon(Icons.refresh_rounded),
                    onPressed: _pick,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 18),
          if (!_scale) ...[
            Text('TARGET SIZE', style: context.tt.labelSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final k in _presets)
                  ChoiceChip(
                    label: Text('$k KB'),
                    selected: _targetKb == k,
                    onSelected: (_) => setState(() {
                      _targetKb = k;
                      _custom.clear();
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _custom,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Custom (KB)',
                hintText: 'e.g. 150',
              ),
              onChanged: (v) {
                final n = int.tryParse(v);
                if (n != null && n >= 5) setState(() => _targetKb = n);
              },
            ),
          ] else ...[
            Text(
              'SCALE ${_pct.round()}%${_dims == null ? '' : ' · ${(_dims!.$1 * _pct / 100).round()} × ${(_dims!.$2 * _pct / 100).round()} PX'}',
              style: context.tt.labelSmall,
            ),
            Slider(
              value: _pct,
              min: 5,
              max: 100,
              divisions: 19,
              label: '${_pct.round()}%',
              onChanged: (v) => setState(() => _pct = v),
            ),
            Text(
              'JPEG QUALITY ${_quality.round()}%',
              style: context.tt.labelSmall,
            ),
            Slider(
              value: _quality,
              min: 30,
              max: 100,
              divisions: 14,
              label: '${_quality.round()}%',
              onChanged: (v) => setState(() => _quality = v),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: src == null || _busy ? null : _run,
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.auto_awesome_rounded),
            label: Text(_scale ? 'Resize' : 'Compress under $_targetKb KB'),
          ),
          if (_failed)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                'Can’t reach $_targetKb KB even at a very small size. Try a larger target.',
                style: TextStyle(color: px.danger),
              ),
            ),
          if (r != null && src != null) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: px.success.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: px.success.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('New size', style: context.tt.bodySmall),
                            Text(
                              fmtSize(r.bytes.length),
                              style: context.tt.headlineLarge?.copyWith(
                                fontSize: 24,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (r.bytes.length < src.length)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: px.success,
                            borderRadius: BorderRadius.circular(99),
                          ),
                          child: Text(
                            '−${(100 * (1 - r.bytes.length / src.length)).round()}%',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${r.width} × ${r.height} px · JPEG quality ${r.quality}%',
                    style: context.tt.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _share,
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('Save / share'),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Runs on your device. 1 KB = 1,000 bytes, which is safe for strict upload limits.',
            style: context.tt.bodySmall,
          ),
        ],
      ),
    );
  }
}
