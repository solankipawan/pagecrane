import 'dart:ui' show Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfit/app/app.dart';
import 'package:pdfit/features/documents/data/documents_provider.dart';
import 'package:pdfit/features/documents/data/stored_doc.dart';
import 'package:pdfit/features/settings/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeDocs extends DocumentsNotifier {
  @override
  Future<List<StoredDoc>> build() async => [
    StoredDoc(
      id: 'd1',
      name: 'Invoice INV-2026-114',
      folder: 'Bills',
      createdAt: DateTime(2026, 11, 1),
      updatedAt: DateTime(2026, 11, 1),
      pageCount: 2,
      sizeBytes: 212000,
    ),
  ];
}

void main() {
  testWidgets('dashboard renders tools and recents', (tester) async {
    tester.view
      ..physicalSize =
          const Size(1170, 3600) // tall phone so the Recent list is built
      ..devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          documentsProvider.overrideWith(_FakeDocs.new),
        ],
        child: const PdfitApp(),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Pagecrane'), findsOneWidget);
    expect(find.text('QUICK TOOLS'), findsOneWidget);
    expect(find.text('Merge'), findsOneWidget);
    expect(find.text('Invoice INV-2026-114'), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    // Maker credit footer (same as TrainPulse), opens Instagram.
    expect(
      find.bySemanticsLabel(
        'Built with love by theairsolanki. Opens Instagram.',
      ),
      findsOneWidget,
    );
  });
}
