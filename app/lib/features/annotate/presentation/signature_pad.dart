import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/haptics.dart';
import '../../settings/settings_provider.dart';

/// A signature normalized to its own tight box: points in 0..1, [aspect] = height / width.
@immutable
class SignatureData {
  const SignatureData(this.strokes, this.aspect);
  final List<List<Offset>> strokes;
  final double aspect;

  Map<String, Object> toJson() => {
    'aspect': aspect,
    'strokes': [
      for (final s in strokes)
        [
          for (final p in s) [p.dx, p.dy],
        ],
    ],
  };

  static SignatureData? fromJson(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, Object?>;
      final strokes = [
        for (final s in j['strokes']! as List)
          [
            for (final p in s as List)
              Offset(
                ((p as List)[0] as num).toDouble(),
                (p[1] as num).toDouble(),
              ),
          ],
      ];
      return SignatureData(strokes, (j['aspect']! as num).toDouble());
    } on Object {
      return null; // corrupt → treat as no saved signature
    }
  }

  /// Normalizes raw pad strokes to their bounding box (+4 % padding).
  static SignatureData? fromRaw(List<List<Offset>> raw) {
    final pts = raw.expand((s) => s).toList();
    if (pts.length < 2) return null;
    var l = pts.first.dx, t = pts.first.dy, r = l, b = t;
    for (final p in pts) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    final pad = math.max(r - l, b - t) * 0.04 + 2;
    l -= pad;
    t -= pad;
    r += pad;
    b += pad;
    final w = r - l, h = b - t;
    return SignatureData([
      for (final s in raw)
        [for (final p in s) Offset((p.dx - l) / w, (p.dy - t) / h)],
    ], h / w);
  }
}

const _prefsKey = 'signature.v1';

/// Opens the pad. Returns the signature to place, or null if cancelled.
/// The saved signature (if any) lives only in this app's preferences on the device.
Future<SignatureData?> showSignaturePad(BuildContext context, WidgetRef ref) {
  final prefs = ref.read(prefsProvider);
  final saved = SignatureData.fromJson(prefs.getString(_prefsKey));
  return showModalBottomSheet<SignatureData>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SignaturePad(
      saved: saved,
      onRemember: (s) => prefs.setString(_prefsKey, jsonEncode(s.toJson())),
    ),
  );
}

class _SignaturePad extends StatefulWidget {
  const _SignaturePad({required this.saved, required this.onRemember});
  final SignatureData? saved;
  final void Function(SignatureData) onRemember;

  @override
  State<_SignaturePad> createState() => _SignaturePadState();
}

class _SignaturePadState extends State<_SignaturePad> {
  final _strokes = <List<Offset>>[];
  bool _remember = true;

  @override
  Widget build(BuildContext context) {
    final saved = widget.saved;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.paddingOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Signature', style: context.tt.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Sign inside the box with your finger.',
            style: context.tt.bodySmall,
          ),
          const SizedBox(height: 14),
          if (saved != null) ...[
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(context, saved),
              icon: const Icon(Icons.history_edu_rounded),
              label: const Text('Use saved signature'),
            ),
            const SizedBox(height: 10),
          ],
          ClipRRect(
            borderRadius: BorderRadius.circular(18),
            child: Container(
              height: 200,
              color: Colors.white,
              child: GestureDetector(
                onPanStart: (d) =>
                    setState(() => _strokes.add([d.localPosition])),
                onPanUpdate: (d) =>
                    setState(() => _strokes.last.add(d.localPosition)),
                child: CustomPaint(
                  painter: _PadPainter(_strokes),
                  child: Stack(
                    children: [
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: 46,
                        child: Container(
                          height: 1,
                          color: const Color(0x33000000),
                        ),
                      ),
                      const Positioned(
                        left: 20,
                        bottom: 52,
                        child: Text(
                          '×',
                          style: TextStyle(
                            color: Color(0x66000000),
                            fontSize: 20,
                          ),
                        ),
                      ),
                      if (_strokes.isEmpty)
                        const Center(
                          child: Text(
                            'Sign here',
                            style: TextStyle(
                              color: Color(0x55000000),
                              fontSize: 18,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            value: _remember,
            onChanged: (v) => setState(() => _remember = v),
            title: const Text('Remember on this device'),
          ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: _strokes.isEmpty
                      ? null
                      : () => setState(_strokes.clear),
                  child: const Text('Clear'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: _strokes.isEmpty
                      ? null
                      : () {
                          final sig = SignatureData.fromRaw(_strokes);
                          if (sig == null) return;
                          Haptics.success();
                          if (_remember) widget.onRemember(sig);
                          Navigator.pop(context, sig);
                        },
                  child: const Text('Place signature'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _PadPainter extends CustomPainter {
  _PadPainter(this.strokes);
  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = const Color(0xFF111827)
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    for (final s in strokes) {
      if (s.length < 2) continue;
      final path = Path()..moveTo(s.first.dx, s.first.dy);
      for (final q in s.skip(1)) {
        path.lineTo(q.dx, q.dy);
      }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(_PadPainter old) => true;
}
