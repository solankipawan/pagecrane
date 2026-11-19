import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfit/app/theme/app_theme.dart';
import 'package:pdfit/core/widgets/empty_states.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'first-run and no-results states fit a 320 pt phone (${brightness.name})',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var scans = 0, clears = 0;

        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(brightness),
            home: Scaffold(
              body: ListView(
                children: [
                  IllustratedEmptyState(
                    art: const ScanEmptyArt(),
                    title: 'No documents scanned yet',
                    body: 'Scan receipts, notes, or IDs into crisp PDFs right on your device.',
                    primaryLabel: 'Scan First Document',
                    onPrimary: () => scans++,
                  ),
                  IllustratedEmptyState(
                    art: const SearchEmptyArt(),
                    title: 'No matches for “tax_2025”',
                    body: 'Check spelling or clear search to view all 4 on-device documents.',
                    extra: Wrap(
                      children: [
                        for (final l in [
                          'All',
                          'PDF',
                          'Scanned Today',
                          'Under 1 MB',
                        ])
                          ChoiceChip(label: Text(l), selected: l == 'All'),
                      ],
                    ),
                    secondaryLabel: 'Clear Search',
                    onSecondary: () => clears++,
                  ),
                ],
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Scan First Document'));
        await tester.ensureVisible(find.text('Clear Search'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Clear Search'));
        expect((scans, clears), (1, 1));
        expect(tester.takeException(), isNull);
      },
    );
  }
}
