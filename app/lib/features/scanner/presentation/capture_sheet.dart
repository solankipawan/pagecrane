import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../documents/presentation/import_pdf_flow.dart';
import '../../settings/settings_provider.dart';
import '../data/scanner_bridge.dart';
import '../domain/scan_session.dart';
import 'camera_scan_screen.dart';

enum _Source { camera, photos, pdf }

/// Entry point for the Scan FAB / quick tool: pick a source, capture, go to Review.
Future<void> startScan(BuildContext context, WidgetRef ref) async {
  Haptics.light();
  final source = await showModalBottomSheet<_Source>(
    context: context,
    useRootNavigator: true, // above the shell's tab bar when opened from a tab
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New scan', style: context.tt.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Pages are cropped and kept on this device.',
              style: context.tt.bodySmall,
            ),
            const SizedBox(height: 16),
            _SourceTile(
              icon: Icons.document_scanner_rounded,
              color: context.px.scan,
              title: 'Camera',
              subtitle: 'Live edge detection · auto-capture · batch pages',
              onTap: () => Navigator.pop(context, _Source.camera),
            ),
            const SizedBox(height: 10),
            _SourceTile(
              icon: Icons.photo_library_rounded,
              color: context.px.image,
              title: 'Import photos',
              subtitle: 'Auto-crop pages from photos you already took',
              onTap: () => Navigator.pop(context, _Source.photos),
            ),
            const SizedBox(height: 10),
            _SourceTile(
              icon: Icons.picture_as_pdf_rounded,
              color: context.px.pdf,
              title: 'Import PDF',
              subtitle: 'Bring a PDF from Files into your library',
              onTap: () => Navigator.pop(context, _Source.pdf),
            ),
          ],
        ),
      ),
    ),
  );
  if (source == null || !context.mounted) return;
  if (source == _Source.pdf) {
    return importPdf(context, ref); // already digital: no crop/filter review
  }

  List<CapturedPage>? pages;
  try {
    if (source == _Source.camera) {
      pages = await _cameraPages(context, ScanMode.batch);
    } else {
      // Spinner only after the user has picked, never on top of the picker.
      final files = await ScannerBridge.pickPhotos();
      if (files == null || !context.mounted) return;
      pages = await _withProgress(
        context,
        'Finding page edges…',
        () => ScannerBridge.processPhotos(files),
      );
    }
  } on ScannerUnavailable {
    if (context.mounted) {
      showToast(
        context,
        'Camera scanner unavailable here. Try Import photos.',
        icon: Icons.no_photography_rounded,
      );
    }
    return;
  }
  if (context.mounted) await _addAndReview(context, ref, pages);
}

/// Opens Pagecrane's camera straight away (Tools: Batch Scan, ID Card Scan).
Future<void> startCameraScan(
  BuildContext context,
  WidgetRef ref, {
  ScanMode mode = ScanMode.batch,
}) async {
  Haptics.light();
  try {
    final pages = await _cameraPages(context, mode);
    if (context.mounted) await _addAndReview(context, ref, pages);
  } on ScannerUnavailable {
    if (context.mounted) {
      showToast(
        context,
        'Camera scanner unavailable here. Try Import photos.',
        icon: Icons.no_photography_rounded,
      );
    }
  }
}

/// Pagecrane's own camera; the system scanner is the fallback where it can't run.
Future<List<CapturedPage>?> _cameraPages(
  BuildContext context,
  ScanMode mode,
) async {
  final result = await openCameraScan(context, mode: mode);
  if (!context.mounted) return null;
  return switch (result) {
    null => null,
    CameraScanPages(:final pages) => pages,
    CameraScanUseSystem() => await ScannerBridge.scanWithCamera(),
    CameraScanImportFiles() =>
      context.mounted ? await _importFiles(context) : null,
  };
}

Future<void> _addAndReview(
  BuildContext context,
  WidgetRef ref,
  List<CapturedPage>? pages,
) async {
  if (pages == null || pages.isEmpty || !context.mounted) return;

  Haptics.medium();
  ref
      .read(scanSessionProvider.notifier)
      .addPages(pages, ref.read(settingsProvider).defaultFilter);
  final uncropped = pages.where((p) => !p.cropped).length;
  if (uncropped > 0) {
    showToast(
      context,
      '$uncropped kept uncropped: no page edges found',
      icon: Icons.crop_free_rounded,
    );
  }
  if (GoRouterState.of(context).uri.path != '/review') context.push('/review');
}

/// Page images picked from the Files app, auto-cropped like imported photos.
Future<List<CapturedPage>?> _importFiles(BuildContext context) async {
  final files = await ScannerBridge.pickImageFiles();
  if (files == null || !context.mounted) return null;
  return _withProgress(
    context,
    'Finding page edges…',
    () => ScannerBridge.processPhotos(files),
  );
}

/// Shows a blocking progress dialog while [task] runs (only if it takes > 150 ms).
Future<T> _withProgress<T>(
  BuildContext context,
  String label,
  Future<T> Function() task,
) async {
  var shown = false, done = false;
  final nav = Navigator.of(context, rootNavigator: true);
  final timer = Future<void>.delayed(const Duration(milliseconds: 150), () {
    if (done || !context.mounted) return;
    shown = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: Center(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(label),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  });
  try {
    return await task();
  } finally {
    done = true;
    await timer;
    if (shown) nav.pop();
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title, subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: onTap,
    semanticLabel: title,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.px.hairline,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          ToolIcon(icon, color),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.tt.titleMedium),
                const SizedBox(height: 2),
                Text(subtitle, style: context.tt.bodySmall),
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, color: context.px.muted),
        ],
      ),
    ),
  );
}
