import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../features/settings/settings_provider.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class PdfitApp extends ConsumerWidget {
  const PdfitApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(settingsProvider.select((s) => s.theme));
    return MaterialApp.router(
      title: 'Pagecrane',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: mode,
      routerConfig: router,
    );
  }
}
