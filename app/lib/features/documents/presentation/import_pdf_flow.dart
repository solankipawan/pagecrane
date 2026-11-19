import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../data/documents_provider.dart';
import '../data/pdf_import.dart';

/// Pick a PDF from Files → (password if needed) → render pages → save to the library → open it.
Future<void> importPdf(BuildContext context, WidgetRef ref) async {
  Haptics.light();
  final picked = await PdfImporter.pick();
  if (picked == null || !context.mounted) return;

  var attempts = 0;
  final PdfDocument doc;
  try {
    doc = await PdfImporter.open(
      picked.path,
      askPassword: () {
        attempts++;
        return context.mounted
            ? _askPassword(context, picked.name, retry: attempts > 1)
            : Future.value();
      },
    );
  } on PdfPasswordException {
    if (context.mounted) {
      showToast(
        context,
        'PDF is password-protected',
        icon: Icons.lock_outline_rounded,
      );
    }
    return;
  } on Object {
    if (context.mounted) {
      showToast(
        context,
        'Couldn’t open this PDF',
        icon: Icons.error_outline_rounded,
      );
    }
    return;
  }
  if (!context.mounted) {
    await doc.dispose();
    return;
  }

  final progress = ValueNotifier<(int, int)>((0, doc.pages.length));
  var cancelled = false;
  final nav = Navigator.of(context, rootNavigator: true);
  showDialog<void>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: ValueListenableBuilder(
          valueListenable: progress,
          builder: (c, p, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p.$2 == 0 ? null : p.$1 / p.$2),
              const SizedBox(height: 16),
              Text(
                'Importing page ${p.$1 < p.$2 ? p.$1 + 1 : p.$2} of ${p.$2}…',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => cancelled = true,
            child: const Text('Cancel'),
          ),
        ],
      ),
    ),
  );

  List<Uint8List>? pages;
  Object? error;
  try {
    pages = await PdfImporter.render(
      doc,
      onProgress: (d, t) => progress.value = (d, t),
      isCancelled: () => cancelled,
    );
  } on PdfImportCancelled {
    pages = null;
  } on Object catch (e) {
    error = e;
  }
  nav.pop(); // progress dialog
  if (!context.mounted) return;
  if (error != null) {
    showToast(
      context,
      'Couldn’t import this PDF',
      icon: Icons.error_outline_rounded,
    );
    return;
  }
  if (pages == null || pages.isEmpty) {
    showToast(context, 'Import cancelled', icon: Icons.close_rounded);
    return;
  }

  final saved = await ref
      .read(documentsProvider.notifier)
      .add(name: picked.name, folder: 'Imported', pages: pages);
  Haptics.success();
  if (!context.mounted) return;
  context.push('/doc/${saved.id}');
  showToast(
    context,
    'Imported ${plural(saved.pageCount, 'page')} · ${fmtSize(saved.sizeBytes)}',
  );
}

Future<String?> _askPassword(
  BuildContext context,
  String name, {
  required bool retry,
}) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    useRootNavigator: true,
    builder: (d) => AlertDialog(
      title: Text(retry ? 'Wrong password' : 'Password required'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '“$name” is protected. The password is only used to open it on this device.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: c,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password'),
            onSubmitted: (v) => Navigator.pop(d, v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, c.text),
          child: const Text('Open'),
        ),
      ],
    ),
  );
}
