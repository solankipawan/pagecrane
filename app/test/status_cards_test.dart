import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfit/app/theme/app_theme.dart';
import 'package:pdfit/core/widgets/status_cards.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets('status cards fit 320 pt and their actions fire '
        '(${brightness.name})', (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final taps = <String>[];

      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(brightness),
          home: Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                PermissionCard(
                  icon: Icons.photo_camera_rounded,
                  title: 'Camera access is needed to scan',
                  body:
                      'Allow camera permission so Pagecrane can auto-detect '
                      'edges and create PDFs on your device.',
                  primaryLabel: 'Open Settings',
                  onPrimary: () => taps.add('settings'),
                  secondaryLabel: 'Import from Files',
                  onSecondary: () => taps.add('import'),
                ),
                const SizedBox(height: 16),
                IssueCard(
                  title: 'Couldn’t merge selected files',
                  reason: 'One file appears password-protected or corrupted',
                  primaryLabel: 'Unlock File',
                  onPrimary: () => taps.add('unlock'),
                  secondaryLabel: 'Remove & Retry',
                  onSecondary: () => taps.add('retry'),
                  onDismiss: () {},
                ),
                const SizedBox(height: 16),
                ProgressCard(
                  title: 'Merging 3 of 5 pages…',
                  detail: 'Scan_18_Nov_2026',
                  value: 0.64,
                  onCancel: () => taps.add('cancel'),
                ),
                const SizedBox(height: 16),
                const ProgressCard(title: 'Preparing files…', value: null),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.text('64%'), findsOneWidget);
      for (final label in [
        'Open Settings',
        'Import from Files',
        'Unlock File',
        'Remove & Retry',
        'Cancel',
      ]) {
        await tester.tap(find.text(label));
      }
      expect(taps, ['settings', 'import', 'unlock', 'retry', 'cancel']);
    });
  }
}
