import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/incoming_pdf.dart';
import 'core/widgets/common.dart';
import 'features/documents/data/doc_repository.dart';
import 'features/settings/settings_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Safety net: a save that fails (e.g. storage full) anywhere the screen didn't
  // handle it still gets a clear message instead of a silent, stuck screen.
  PlatformDispatcher.instance.onError = (error, stack) {
    if (error is StorageException) {
      rootMessengerKey.currentState?.showSnackBar(
        SnackBar(content: Text(error.message)),
      );
      return true;
    }
    return false;
  };
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs)],
      child: const PdfitApp(),
    ),
  );
  IncomingPdf.init(); // "Open with Pagecrane" on Android
}
