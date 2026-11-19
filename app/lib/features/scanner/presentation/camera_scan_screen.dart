import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/status_cards.dart';
import '../data/scanner_bridge.dart';
import '../domain/doc_detect.dart' show Pt;
import '../domain/live_detect.dart';
import '../domain/page_pipeline.dart';
import 'crop_screen.dart';

/// What the camera screen hands back to the scan flow.
sealed class CameraScanResult {
  const CameraScanResult();
}

class CameraScanPages extends CameraScanResult {
  const CameraScanPages(this.pages);
  final List<CapturedPage> pages;
}

/// The camera couldn't run here (no camera, init failed) or the user asked for the
/// system scanner: the caller falls back to VisionKit / ML Kit.
class CameraScanUseSystem extends CameraScanResult {
  const CameraScanUseSystem();
}

/// No camera (access refused or unavailable): import page images from Files instead.
class CameraScanImportFiles extends CameraScanResult {
  const CameraScanImportFiles();
}

/// Opens Pagecrane's page in system Settings (where camera access is switched on).
Future<void> openAppSettings() async {
  if (Platform.isIOS) {
    await launchUrl(Uri.parse('app-settings:'));
  } else {
    await const MethodChannel('pagecrane/system')
        .invokeMethod('openAppSettings');
  }
}

/// Opens the Pagecrane camera full screen. Null when the user closed it.
Future<CameraScanResult?> openCameraScan(
  BuildContext context, {
  ScanMode mode = ScanMode.batch,
}) => Navigator.of(context, rootNavigator: true).push<CameraScanResult>(
  MaterialPageRoute(
    fullscreenDialog: true,
    builder: (_) => CameraScanScreen(initialMode: mode),
  ),
);

enum ScanMode {
  batch('Batch'),
  single('Single'),
  idCard('ID Card');

  const ScanMode(this.label);
  final String label;
}

enum _PreviewAction { delete, crop }

enum _Flash {
  auto('Auto', FlashMode.auto),
  on('On', FlashMode.always),
  off('Off', FlashMode.off);

  const _Flash(this.label, this.mode);
  final String label;
  final FlashMode mode;
}

// Design tokens from the Batch Scan mockup.
const _indigo = Color(0xFF5B3DF5);
const _violet = Color(0xFF7C3AED);
const _pill = Color(0x8C0D0F17); // rgba(13,15,23,0.55)

class _Shot {
  _Shot(this.id);
  final int id;
  CapturedPage? page;
  late final Future<void> done;
}

typedef _Live = ({List<Pt>? quad, double progress});

class CameraScanScreen extends StatefulWidget {
  const CameraScanScreen({super.key, this.initialMode = ScanMode.batch});
  final ScanMode initialMode;

  @override
  State<CameraScanScreen> createState() => _CameraScanScreenState();
}

class _CameraScanScreenState extends State<CameraScanScreen>
    with WidgetsBindingObserver {
  CameraController? _cam;
  bool _starting = false;
  String? _problem; // shown instead of the viewfinder
  bool _accessDenied = false;

  /// Set when "Open Settings" was tapped: on return, try the camera again.
  bool _sentToSettings = false;

  late var _mode = widget.initialMode;
  var _flash = _Flash.auto;
  var _auto = true;
  final _shots = <_Shot>[];
  var _seq = 0;
  int? _sel;
  bool _capturing = false;
  bool _flashFx = false;

  final _tracker = QuadTracker();
  final _live = ValueNotifier<_Live>((quad: null, progress: 0));
  Uint8List? _lastFrame;
  double _frameAspect = 9 / 16;
  int _rotation = 90;
  bool _frameBusy = false;
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);

  int get _maxPages => switch (_mode) {
    ScanMode.batch => 50,
    ScanMode.single => 1,
    ScanMode.idCard => 2,
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    _start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setPreferredOrientations(const []);
    _stop(rebuild: false);
    _live.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stop();
    } else if (state == AppLifecycleState.resumed &&
        _cam == null &&
        // Don't re-prompt right after "Don't allow" (the dialog itself pauses us);
        // only restart if the camera was running or the user went to Settings.
        (_problem == null || _sentToSettings)) {
      _sentToSettings = false;
      _start();
    }
  }

  Future<void> _start() async {
    if (_starting) return;
    _starting = true;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _fallBack();
        return;
      }
      final back = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final cam = CameraController(
        back,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await cam.initialize();
      if (!mounted) {
        await cam.dispose();
        return;
      }
      _rotation = back.sensorOrientation;
      await _try(
        () => cam.lockCaptureOrientation(DeviceOrientation.portraitUp),
      );
      await _try(() => cam.setFlashMode(_flash.mode));
      await _try(() => cam.setFocusMode(FocusMode.auto));
      if (cam.supportsImageStreaming()) {
        await cam.startImageStream(_onFrame);
      }
      _tracker.reset();
      setState(() {
        _cam = cam;
        _problem = null;
      });
    } on CameraException catch (e) {
      debugPrint('Pagecrane camera: ${e.code} ${e.description}');
      if (!mounted) return;
      final denied =
          e.code.contains('AccessDenied') ||
          e.code.contains('AccessRestricted') ||
          e.code.contains('Permission');
      setState(() {
        _accessDenied = denied;
        _problem = denied
            ? 'Pagecrane needs camera access to scan pages.'
            : 'The camera could not start.';
      });
    } catch (e, st) {
      debugPrint('Pagecrane camera failed to start: $e\n$st');
      if (mounted) setState(() => _problem = 'The camera could not start.');
    } finally {
      _starting = false;
    }
  }

  Future<void> _try(Future<void> Function() f) async {
    try {
      await f();
    } catch (_) {}
  }

  /// Releases the camera. [rebuild] is false from [dispose], where setState is illegal.
  void _stop({bool rebuild = true}) {
    final cam = _cam;
    _cam = null;
    if (cam == null) return;
    if (cam.value.isStreamingImages) {
      cam.stopImageStream().catchError((_) {}).whenComplete(cam.dispose);
    } else {
      cam.dispose();
    }
    if (rebuild && mounted) setState(() {});
  }

  void _fallBack() {
    if (mounted) Navigator.pop(context, const CameraScanUseSystem());
  }

  // ---- live detection -------------------------------------------------------

  void _onFrame(CameraImage f) {
    final now = DateTime.now();
    if (_frameBusy || now.difference(_lastFrameAt).inMilliseconds < 80) return;
    _frameBusy = true;
    _lastFrameAt = now;
    try {
      final p = f.planes.first;
      final luma = uprightLuma(
        p.bytes,
        f.width,
        f.height,
        p.bytesPerRow,
        // iOS already rotates frames to the locked portrait orientation; Android
        // delivers them in sensor orientation. Go by the frame's own shape.
        f.width < f.height ? 0 : _rotation,
      );
      _lastFrame = luma.g;
      _frameAspect = luma.w / luma.h;
      _tracker.aspect = _frameAspect;
      _tracker.update(detectNormalized(luma), luma.g, now);
      _live.value = (quad: _tracker.quad, progress: _tracker.progress(now));
      if (_auto &&
          !_capturing &&
          _shots.length < _maxPages &&
          _tracker.shouldCapture(now)) {
        _capture();
      }
    } catch (_) {
      // A malformed frame is skipped; the next one comes in ~33 ms.
    } finally {
      _frameBusy = false;
    }
  }

  // ---- capture ----------------------------------------------------------------

  Future<void> _capture() async {
    final cam = _cam;
    if (cam == null || _capturing || _shots.length >= _maxPages) return;
    _capturing = true;
    Haptics.medium();
    setState(() => _flashFx = true);
    Future.delayed(const Duration(milliseconds: 140), () {
      if (mounted) setState(() => _flashFx = false);
    });
    final hint = _tracker.quad;
    final aspect = _frameAspect;
    if (_lastFrame != null) _tracker.captured(_lastFrame!);
    try {
      XFile file;
      try {
        file = await cam.takePicture();
      } on CameraException {
        // Some devices can't take a photo while frames stream: pause the stream.
        if (cam.value.isStreamingImages) await cam.stopImageStream();
        file = await cam.takePicture();
        if (cam.supportsImageStreaming()) await cam.startImageStream(_onFrame);
      }
      final bytes = await file.readAsBytes();
      unawaited(File(file.path).delete().catchError((_) => File(file.path)));
      final shot = _Shot(_seq++);
      shot.done =
          compute(prepareCameraPhoto, (
            bytes: bytes,
            hint: hint,
            hintAspect: aspect,
          )).then((p) {
            shot.page = p;
            if (mounted) setState(() {});
          });
      if (!mounted) return;
      setState(() {
        _shots.add(shot);
        _sel = null;
      });
      if (_shots.length >= _maxPages && _mode != ScanMode.batch) {
        await _finish();
      }
    } on CameraException catch (e) {
      if (mounted) {
        showToast(
          context,
          'Capture failed: ${e.description ?? e.code}',
          icon: Icons.error_outline_rounded,
        );
      }
    } finally {
      _capturing = false;
    }
  }

  Future<void> _finish() async {
    if (_shots.isEmpty) return;
    await Future.wait([for (final s in _shots) s.done]);
    if (!mounted) return;
    Haptics.success();
    Navigator.pop(
      context,
      CameraScanPages([
        for (final s in _shots)
          if (s.page != null) s.page!,
      ]),
    );
  }

  Future<void> _close() async {
    if (_shots.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final n = _shots.length;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Discard $n ${n == 1 ? 'page' : 'pages'}?'),
        content: const Text('Pages scanned so far will not be saved.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep scanning'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.pop(context);
  }

  void _setMode(ScanMode m) {
    if (m == _mode) return;
    Haptics.select();
    setState(() {
      _mode = m;
      // Single / ID Card keep at most their own page count.
      if (_shots.length > _maxPages) {
        _shots.removeRange(_maxPages, _shots.length);
      }
      _sel = null;
    });
  }

  void _cycleFlash() {
    Haptics.select();
    setState(() => _flash = _Flash.values[(_flash.index + 1) % 3]);
    final cam = _cam;
    if (cam != null) _try(() => cam.setFlashMode(_flash.mode));
  }

  void _toggleAuto() {
    Haptics.select();
    setState(() => _auto = !_auto);
  }

  void _move(int d) {
    final i = _sel;
    if (i == null) return;
    final j = i + d;
    if (j < 0 || j >= _shots.length) return;
    Haptics.select();
    setState(() {
      final s = _shots.removeAt(i);
      _shots.insert(j, s);
      _sel = j;
    });
  }

  void _delete(int i) {
    if (i < 0 || i >= _shots.length) return;
    Haptics.light();
    setState(() {
      _shots.removeAt(i);
      _sel = null;
    });
    _tracker.reset(); // allow re-shooting the page that was just removed
  }

  Future<void> _previewLast() async {
    if (_shots.isEmpty) return;
    final shot = _shots[_sel ?? _shots.length - 1];
    await shot.done;
    final page = shot.page;
    if (page == null || !mounted) return;
    final action = await showDialog<_PreviewAction>(
      context: context,
      builder: (context) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: InteractiveViewer(
                child: Image.memory(page.jpeg, fit: BoxFit.contain),
              ),
            ),
            if (!page.cropped)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('No page edges found: kept the whole photo.'),
              ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  TextButton.icon(
                    onPressed: () =>
                        Navigator.pop(context, _PreviewAction.delete),
                    icon: const Icon(Icons.delete_outline_rounded),
                    label: const Text('Delete'),
                  ),
                  const Spacer(),
                  if (page.original != null)
                    TextButton.icon(
                      onPressed: () =>
                          Navigator.pop(context, _PreviewAction.crop),
                      icon: const Icon(Icons.crop_rounded),
                      label: const Text('Adjust crop'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Keep'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case _PreviewAction.delete:
        _delete(_shots.indexOf(shot));
      case _PreviewAction.crop:
        await _adjustCrop(shot);
      case null:
        break;
    }
  }

  Future<void> _adjustCrop(_Shot shot) async {
    final page = shot.page;
    final original = page?.original;
    if (page == null || original == null) return;
    final result = await openCropEditor(
      context,
      original: original,
      corners: page.corners,
    );
    if (result == null || !mounted) return;
    final jpeg = await compute(cropPage, (
      original: original,
      corners: result.corners,
    ));
    if (!mounted) return;
    setState(
      () => shot.page = (
        jpeg: jpeg,
        cropped: result.corners != null,
        original: original,
        corners: result.corners,
      ),
    );
  }

  // ---- UI ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: PopScope(
        canPop: _shots.isEmpty,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              if (cam != null && cam.value.isInitialized)
                _Viewfinder(cam: cam, live: _live)
              else if (_problem != null)
                _Problem(
                  denied: _accessDenied,
                  onSystem: _fallBack,
                  onSettings: () {
                    _sentToSettings = true;
                    openAppSettings();
                  },
                  onImport: () =>
                      Navigator.pop(context, const CameraScanImportFiles()),
                  onRetry: () {
                    setState(() => _problem = null);
                    _start();
                  },
                )
              else
                const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              IgnorePointer(
                child: AnimatedOpacity(
                  opacity: _flashFx ? 0.55 : 0,
                  duration: const Duration(milliseconds: 90),
                  child: const ColoredBox(color: Colors.white),
                ),
              ),
              Positioned(
                left: 16,
                right: 16,
                top: MediaQuery.paddingOf(context).top + 8,
                child: _problem != null
                    ? Align(
                        alignment: Alignment.centerLeft,
                        child: _RoundPill(
                          label: 'Close scanner',
                          onTap: _close,
                          child: const Icon(
                            Icons.close_rounded,
                            color: Colors.white,
                            size: 22,
                          ),
                        ),
                      )
                    : _TopBar(
                        mode: _mode,
                        flash: _flash.label,
                        flashOn: _flash != _Flash.off,
                        auto: _auto,
                        onClose: _close,
                        onMode: _setMode,
                        onFlash: _cycleFlash,
                        onAuto: _toggleAuto,
                      ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: _problem != null
                    ? const SizedBox.shrink()
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (cam != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: ValueListenableBuilder(
                                valueListenable: _live,
                                builder: (context, live, _) => _StatusChip(
                                  text: _statusText(live),
                                  progress: _auto ? live.progress : null,
                                  busy: _capturing,
                                ),
                              ),
                            ),
                          _Dock(
                            shots: _shots,
                            selected: _sel,
                            mode: _mode,
                            canShoot: cam != null && _shots.length < _maxPages,
                            capturing: _capturing,
                            onSelect: (i) =>
                                setState(() => _sel = _sel == i ? null : i),
                            onMoveLeft: () => _move(-1),
                            onMoveRight: () => _move(1),
                            onDelete: () {
                              if (_sel != null) _delete(_sel!);
                            },
                            onCrop: () async {
                              final i = _sel;
                              if (i == null) return;
                              final shot = _shots[i];
                              await shot.done;
                              if (mounted) await _adjustCrop(shot);
                            },
                            onShutter: _capture,
                            onPreview: _previewLast,
                            onDone: _finish,
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _statusText(_Live live) {
    if (_capturing) return 'Capturing…';
    if (_shots.length >= _maxPages) {
      return _mode == ScanMode.batch ? 'Page limit reached' : 'Tap Done';
    }
    final side = _mode == ScanMode.idCard
        ? (_shots.isEmpty ? 'Front of card · ' : 'Back of card · ')
        : '';
    if (live.quad == null) return '${side}Point at a document';
    return _auto
        ? '${side}Document found · hold steady'
        : '${side}Document found · tap to capture';
  }
}

// ---- viewfinder ---------------------------------------------------------------

class _Viewfinder extends StatelessWidget {
  const _Viewfinder({required this.cam, required this.live});
  final CameraController cam;
  final ValueNotifier<_Live> live;

  @override
  Widget build(BuildContext context) {
    final ps = cam.value.previewSize;
    // previewSize is landscape (sensor); the UI is portrait.
    final w = ps == null ? 9.0 : math.min(ps.width, ps.height);
    final h = ps == null ? 16.0 : math.max(ps.width, ps.height);
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              CameraPreview(cam),
              RepaintBoundary(
                child: CustomPaint(
                  painter: _QuadPainter(
                    live,
                    // Preview px per screen px, so strokes look the same everywhere.
                    scale: w / MediaQuery.sizeOf(context).width,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Glowing indigo-violet outline + corner knobs around the detected sheet.
class _QuadPainter extends CustomPainter {
  _QuadPainter(this.live, {required this.scale}) : super(repaint: live);
  final ValueNotifier<_Live> live;
  final double scale;

  @override
  void paint(Canvas canvas, Size size) {
    final q = live.value.quad;
    if (q == null) return;
    final pts = [
      for (final (x, y) in q) Offset(x * size.width, y * size.height),
    ];
    final path = Path()..addPolygon(pts, true);
    final gradient = const LinearGradient(colors: [_indigo, _violet])
        .createShader(path.getBounds());

    canvas.drawPath(path, Paint()..color = _indigo.withValues(alpha: 0.10));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7 * scale
        ..strokeJoin = StrokeJoin.round
        ..color = _violet.withValues(alpha: 0.55)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 7 * scale),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3 * scale
        ..strokeJoin = StrokeJoin.round
        ..shader = gradient,
    );
    for (final p in pts) {
      canvas.drawCircle(
        p,
        13 * scale,
        Paint()..color = _violet.withValues(alpha: 0.28),
      );
      canvas.drawCircle(p, 9 * scale, Paint()..color = Colors.white);
      canvas.drawCircle(
        p,
        7.5 * scale,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3 * scale
          ..color = const Color(0xFF6A3CF2),
      );
    }
  }

  @override
  bool shouldRepaint(_QuadPainter old) =>
      old.live != live || old.scale != scale;
}

class _Problem extends StatelessWidget {
  const _Problem({
    required this.denied,
    required this.onSettings,
    required this.onSystem,
    required this.onImport,
    required this.onRetry,
  });
  final bool denied;
  final VoidCallback onSystem, onImport, onRetry, onSettings;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 80, 20, 32),
      child: denied
          ? PermissionCard(
              icon: Icons.photo_camera_rounded,
              title: 'Camera access is needed to scan',
              body:
                  'Allow camera permission so Pagecrane can auto-detect edges '
                  'and create PDFs on your device.',
              primaryLabel: 'Open Settings',
              onPrimary: onSettings,
              secondaryLabel: 'Import from Files',
              onSecondary: onImport,
            )
          : PermissionCard(
              icon: Icons.no_photography_rounded,
              title: 'The camera couldn’t start',
              body:
                  'Another app may be using it. Try again, or bring in pages '
                  'you already have.',
              primaryLabel: 'Try again',
              primaryIcon: Icons.refresh_rounded,
              onPrimary: onRetry,
              secondaryLabel: 'Import from Files',
              onSecondary: onImport,
              tertiaryLabel: 'Use system scanner',
              onTertiary: onSystem,
            ),
    ),
  );
}

// ---- top bar -------------------------------------------------------------------

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.mode,
    required this.flash,
    required this.flashOn,
    required this.auto,
    required this.onClose,
    required this.onMode,
    required this.onFlash,
    required this.onAuto,
  });
  final ScanMode mode;
  final String flash;
  final bool flashOn, auto;
  final VoidCallback onClose, onFlash, onAuto;
  final ValueChanged<ScanMode> onMode;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      _RoundPill(
        label: 'Close scanner',
        onTap: onClose,
        child: const Icon(Icons.close_rounded, color: Colors.white, size: 22),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: _Glass(
              radius: 22,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final m in ScanMode.values)
                      Semantics(
                        selected: m == mode,
                        button: true,
                        label: '${m.label} mode',
                        excludeSemantics: true,
                        child: GestureDetector(
                          onTap: () => onMode(m),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: m == mode
                                  ? Colors.white
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Text(
                              m.label,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: m == mode
                                    ? const Color(0xFF141726)
                                    : Colors.white,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      _RoundPill(
        label: 'Flash: $flash',
        onTap: onFlash,
        child: _IconLabel(
          icon: flashOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
          text: flash,
          color: flashOn ? const Color(0xFFFFD54A) : const Color(0xB3FFFFFF),
        ),
      ),
      const SizedBox(width: 6),
      _RoundPill(
        label: 'Auto-capture',
        toggled: auto,
        onTap: onAuto,
        child: _IconLabel(
          icon: Icons.center_focus_strong_rounded,
          text: auto ? 'On' : 'Off',
          color: auto ? const Color(0xFFC4B5FD) : const Color(0xB3FFFFFF),
        ),
      ),
    ],
  );
}

class _Glass extends StatelessWidget {
  const _Glass({required this.child, required this.radius});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: _pill,
      borderRadius: BorderRadius.circular(radius),
    ),
    child: child,
  );
}

class _RoundPill extends StatelessWidget {
  const _RoundPill({
    required this.label,
    required this.onTap,
    required this.child,
    this.toggled,
  });
  final String label;
  final VoidCallback onTap;
  final Widget child;
  final bool? toggled;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    toggled: toggled,
    excludeSemantics: true,
    child: GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 44,
        height: 44,
        child: _Glass(radius: 22, child: Center(child: child)),
      ),
    ),
  );
}

class _IconLabel extends StatelessWidget {
  const _IconLabel({
    required this.icon,
    required this.text,
    required this.color,
  });
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, color: color, size: 18),
      Text(
        text.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
      ),
    ],
  );
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.text, this.progress, this.busy = false});
  final String text;
  final double? progress;
  final bool busy;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: _Glass(
      radius: 17,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 8, 14, 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                value: busy ? null : (progress ?? 0),
                strokeWidth: 2.5,
                color: const Color(0xFFA78BFA),
                backgroundColor: const Color(0x40FFFFFF),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

// ---- bottom dock ----------------------------------------------------------------

class _Dock extends StatelessWidget {
  const _Dock({
    required this.shots,
    required this.selected,
    required this.mode,
    required this.canShoot,
    required this.capturing,
    required this.onSelect,
    required this.onMoveLeft,
    required this.onMoveRight,
    required this.onDelete,
    required this.onCrop,
    required this.onShutter,
    required this.onPreview,
    required this.onDone,
  });
  final List<_Shot> shots;
  final int? selected;
  final ScanMode mode;
  final bool canShoot, capturing;
  final ValueChanged<int> onSelect;
  final VoidCallback onMoveLeft, onMoveRight, onDelete, onCrop;
  final VoidCallback onShutter, onPreview;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final dock = dark ? const Color(0xFF161A26) : Colors.white;
    final ink = dark ? const Color(0xFFF2F3F8) : const Color(0xFF141726);
    final muted = dark ? const Color(0xFFA3A9BC) : const Color(0xFF5A6072);
    final line = dark ? const Color(0x1FFFFFFF) : const Color(0x1F141726);
    final chip = dark ? const Color(0x12FFFFFF) : const Color(0x0D141726);
    final ring = dark ? const Color(0x3DFFFFFF) : const Color(0x29141726);
    final n = shots.length;
    final pending = shots.any((s) => s.page == null);

    Widget square(
      String label,
      IconData icon,
      VoidCallback onTap, {
      Color? fg,
      Color? bg,
    }) => Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: Material(
        color: bg ?? chip,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox.square(
            dimension: 44,
            child: Icon(icon, size: 21, color: fg ?? ink),
          ),
        ),
      ),
    );

    return Container(
      decoration: BoxDecoration(
        color: dock,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x47000000),
            blurRadius: 32,
            offset: Offset(0, -12),
          ),
        ],
      ),
      padding: EdgeInsets.fromLTRB(
        16,
        10,
        16,
        math.max(MediaQuery.paddingOf(context).bottom, 16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: ring,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 44,
            child: Row(
              children: [
                Text(
                  n == 1 ? '1 page' : '$n pages',
                  style: TextStyle(
                    color: ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 12),
                if (selected == null)
                  Expanded(
                    child: Text(
                      n == 0
                          ? switch (mode) {
                              ScanMode.batch => 'Pages appear here as you scan',
                              ScanMode.single => 'One page, then done',
                              ScanMode.idCard => 'Front, then back',
                            }
                          : 'Tap a page to crop, move or delete',
                      textAlign: TextAlign.right,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: muted, fontSize: 13),
                    ),
                  )
                else ...[
                  const Spacer(),
                  square(
                    'Move page earlier',
                    Icons.chevron_left_rounded,
                    onMoveLeft,
                  ),
                  const SizedBox(width: 4),
                  square(
                    'Move page later',
                    Icons.chevron_right_rounded,
                    onMoveRight,
                  ),
                  const SizedBox(width: 4),
                  square('Adjust crop', Icons.crop_rounded, onCrop),
                  const SizedBox(width: 4),
                  square(
                    'Delete page',
                    Icons.delete_outline_rounded,
                    onDelete,
                    fg: dark
                        ? const Color(0xFFFF8A8A)
                        : const Color(0xFFC42B2B),
                    bg: dark
                        ? const Color(0x24FF6B6B)
                        : const Color(0x14C42B2B),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 72,
            child: n == 0
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 52,
                      height: 68,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: line, width: 1.5),
                      ),
                      child: Icon(Icons.add_rounded, color: muted),
                    ),
                  )
                : ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.all(2),
                    itemCount: n,
                    separatorBuilder: (_, _) => const SizedBox(width: 10),
                    itemBuilder: (context, i) => _Thumb(
                      shot: shots[i],
                      index: i,
                      selected: selected == i,
                      line: line,
                      onTap: () => onSelect(i),
                    ),
                  ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 84,
            child: Row(
              children: [
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _PreviewButton(
                      shot: shots.isEmpty ? null : shots.last,
                      chip: chip,
                      line: line,
                      muted: muted,
                      dock: dock,
                      onTap: onPreview,
                    ),
                  ),
                ),
                _Shutter(
                  enabled: canShoot && !capturing,
                  ring: ring,
                  dock: dock,
                  onTap: onShutter,
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _DoneButton(
                      count: n,
                      busy: pending,
                      onTap: n == 0 ? null : onDone,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Thumb extends StatelessWidget {
  const _Thumb({
    required this.shot,
    required this.index,
    required this.selected,
    required this.line,
    required this.onTap,
  });
  final _Shot shot;
  final int index;
  final bool selected;
  final Color line;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final page = shot.page;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      button: true,
      selected: selected,
      label: 'Page ${index + 1}',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: 52,
          height: 68,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? _indigo : line,
              width: selected ? 2 : 1,
            ),
            boxShadow: [
              selected
                  ? const BoxShadow(color: Color(0x405B3DF5), spreadRadius: 3)
                  : const BoxShadow(color: Color(0x1F000000), blurRadius: 3),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (page == null)
                const Center(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: _indigo,
                    ),
                  ),
                )
              else
                Image.memory(
                  page.jpeg,
                  fit: BoxFit.cover,
                  cacheWidth: (52 * dpr).ceil(),
                  gaplessPlayback: true,
                ),
              Positioned(
                left: 4,
                bottom: 4,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xC70D0F17),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'p.${index + 1}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewButton extends StatelessWidget {
  const _PreviewButton({
    required this.shot,
    required this.chip,
    required this.line,
    required this.muted,
    required this.dock,
    required this.onTap,
  });
  final _Shot? shot;
  final Color chip, line, muted, dock;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final page = shot?.page;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return Semantics(
      button: true,
      enabled: shot != null,
      label: 'Preview last page',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: shot == null ? null : onTap,
        child: SizedBox.square(
          dimension: 62,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: chip,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: line),
                ),
                alignment: Alignment.center,
                child: page == null
                    ? Icon(Icons.description_outlined, color: muted)
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: Image.memory(
                          page.jpeg,
                          width: 34,
                          height: 44,
                          fit: BoxFit.cover,
                          cacheWidth: (34 * dpr).ceil(),
                          gaplessPlayback: true,
                        ),
                      ),
              ),
              if (page != null)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: _indigo,
                      shape: BoxShape.circle,
                      border: Border.all(color: dock, width: 2),
                    ),
                    child: const Icon(
                      Icons.crop_rounded,
                      size: 12,
                      color: Colors.white,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Shutter extends StatefulWidget {
  const _Shutter({
    required this.enabled,
    required this.ring,
    required this.dock,
    required this.onTap,
  });
  final bool enabled;
  final Color ring, dock;
  final VoidCallback onTap;

  @override
  State<_Shutter> createState() => _ShutterState();
}

class _ShutterState extends State<_Shutter> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: widget.enabled,
    label: 'Capture page',
    excludeSemantics: true,
    child: GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) => setState(() => _down = false),
      onTap: widget.enabled ? widget.onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: widget.enabled ? 1 : 0.45,
        child: AnimatedScale(
          scale: _down ? 0.92 : 1,
          duration: const Duration(milliseconds: 120),
          child: Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: widget.ring, width: 3),
            ),
            alignment: Alignment.center,
            child: Container(
              width: 64,
              height: 64,
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [_indigo, _violet],
                ),
              ),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.dock,
                ),
                child: const DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFF6B4DF7), Color(0xFF8B4CF0)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _DoneButton extends StatelessWidget {
  const _DoneButton({
    required this.count,
    required this.busy,
    required this.onTap,
  });
  final int count;
  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onTap != null,
    label: 'Done, $count ${count == 1 ? 'page' : 'pages'}',
    excludeSemantics: true,
    child: AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: onTap == null ? 0.45 : 1,
      child: Material(
        color: _indigo,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: onTap,
          child: Container(
            height: 48,
            padding: const EdgeInsets.fromLTRB(14, 0, 18, 0),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy && onTap != null)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                else
                  const Icon(
                    Icons.check_rounded,
                    color: Colors.white,
                    size: 19,
                  ),
                const SizedBox(width: 6),
                Text(
                  'Done ($count)',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
