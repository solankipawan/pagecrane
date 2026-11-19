import 'package:go_router/go_router.dart';

import '../core/widgets/app_shell.dart';
import '../features/annotate/presentation/annotate_screen.dart';
import '../features/pdf_tools/presentation/export_images_screen.dart';
import '../features/pdf_tools/presentation/split_screen.dart';
import '../features/dashboard/home_screen.dart';
import '../features/documents/presentation/doc_detail_screen.dart';
import '../features/documents/presentation/open_pdf_screen.dart';
import '../features/files/files_screen.dart';
import '../features/image_tools/presentation/target_size_screen.dart';
import '../features/pdf_tools/presentation/compress_screen.dart';
import '../features/pdf_tools/presentation/merge_screen.dart';
import '../features/pdf_tools/presentation/reorder_screen.dart';
import '../features/pdf_tools/presentation/resize_pages_screen.dart';
import '../features/scanner/presentation/review_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/tools/tools_screen.dart';

/// Shell route with four tabs (state kept per tab) + full-screen flows on top.
final router = GoRouter(
  // Never treat an outside address (e.g. an opened file's content:// URI) as a page.
  redirect: (_, s) => s.uri.hasScheme ? '/' : null,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, shell) => AppShell(shell: shell),
      branches: [
        StatefulShellBranch(
          routes: [GoRoute(path: '/', builder: (_, _) => const HomeScreen())],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/files', builder: (_, _) => const FilesScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(path: '/tools', builder: (_, _) => const ToolsScreen()),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (_, _) => const SettingsScreen(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(path: '/review', builder: (_, _) => const ReviewScreen()),
    GoRoute(
      path: '/open',
      builder: (_, s) {
        final f = s.extra as ({String path, String name})?;
        return OpenPdfScreen(path: f?.path ?? '', name: f?.name ?? 'Document');
      },
    ),
    GoRoute(
      path: '/doc/:id',
      builder: (_, s) => DocDetailScreen(id: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/doc/:id/resize',
      builder: (_, s) => ResizePagesScreen(id: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/doc/:id/reorder',
      builder: (_, s) => ReorderScreen(id: s.pathParameters['id']!),
    ),
    GoRoute(
      path: '/doc/:id/annotate',
      builder: (_, s) => AnnotateScreen(
        id: s.pathParameters['id']!,
        initialPage: int.tryParse(s.uri.queryParameters['page'] ?? '') ?? 0,
      ),
    ),
    GoRoute(
      path: '/tool/split',
      builder: (_, s) => SplitScreen(initialId: s.uri.queryParameters['id']),
    ),
    GoRoute(
      path: '/tool/export-images',
      builder: (_, s) =>
          ExportImagesScreen(initialId: s.uri.queryParameters['id']),
    ),
    GoRoute(
      path: '/tool/merge',
      builder: (_, s) => MergeScreen(
        initialIds: [
          for (final id in (s.uri.queryParameters['ids'] ?? '').split(','))
            if (id.isNotEmpty) id,
        ],
      ),
    ),
    GoRoute(
      path: '/tool/compress',
      builder: (_, s) => CompressScreen(
        initialId: s.uri.queryParameters['id'],
        startInTarget: s.uri.queryParameters['mode'] == 'target',
      ),
    ),
    GoRoute(
      path: '/tool/target-size',
      builder: (_, s) =>
          TargetSizeScreen(scaleMode: s.uri.queryParameters['mode'] == 'scale'),
    ),
  ],
);
