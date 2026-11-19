import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../data/doc_repository.dart';
import '../data/documents_provider.dart';
import '../data/stored_doc.dart';
import 'doc_tile.dart';

/// Document actions shared by lists (row menus and multi-select).

/// A save failed (e.g. storage full). The document is unchanged; say why.
void showSaveError(BuildContext context, StorageException e) {
  if (!context.mounted) return;
  Haptics.medium();
  showToast(
    context,
    e.message,
    icon: Icons.sd_card_alert_rounded,
    iconColor: const Color(0xFFFBBF24),
  );
}

Future<void> shareDocs(
  BuildContext context,
  WidgetRef ref,
  List<StoredDoc> docs,
) async {
  final repo = ref.read(repoSyncProvider);
  if (repo == null || docs.isEmpty) return;
  Haptics.light();
  final box = context.findRenderObject() as RenderBox?;
  await SharePlus.instance.share(
    ShareParams(
      files: [
        for (final d in docs)
          XFile(
            repo.pdfOf(d.id).path,
            mimeType: 'application/pdf',
            name: '${d.name}.pdf',
          ),
      ],
      title: docs.length == 1 ? docs.first.name : '${docs.length} documents',
      sharePositionOrigin: box == null
          ? null
          : box.localToGlobal(Offset.zero) & box.size,
    ),
  );
}

Future<void> renameDoc(
  BuildContext context,
  WidgetRef ref,
  StoredDoc doc,
) async {
  final c = TextEditingController(text: doc.name);
  final name = await showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: const Text('Rename'),
      content: TextField(
        controller: c,
        autofocus: true,
        textInputAction: TextInputAction.done,
        onSubmitted: (v) => Navigator.pop(d, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, c.text),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  if (name != null && name.trim().isNotEmpty && name.trim() != doc.name) {
    try {
      await ref.read(documentsProvider.notifier).rename(doc.id, name.trim());
    } on StorageException catch (e) {
      if (context.mounted) showSaveError(context, e);
    }
  }
}

/// Asks first; returns true if the documents were deleted.
Future<bool> deleteDocs(
  BuildContext context,
  WidgetRef ref,
  List<StoredDoc> docs,
) async {
  if (docs.isEmpty) return false;
  final one = docs.length == 1;
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(
        one ? 'Delete document?' : 'Delete ${docs.length} documents?',
      ),
      content: Text(
        one
            ? '“${docs.first.name}” will be removed from this device. This can’t be undone.'
            : '${plural(docs.length, 'document')} (${fmtSize(docs.fold(0, (a, x) => a + x.sizeBytes))}) will be removed from this device. This can’t be undone.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(d, false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(d, true),
          child: Text('Delete', style: TextStyle(color: context.px.danger)),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  Haptics.medium();
  final n = ref.read(documentsProvider.notifier);
  try {
    for (final x in docs) {
      await n.remove(x.id);
    }
  } on StorageException catch (e) {
    if (context.mounted) showSaveError(context, e);
    return false;
  }
  if (context.mounted) {
    showToast(
      context,
      one ? 'Deleted' : 'Deleted ${plural(docs.length, 'document')}',
      icon: Icons.delete_outline_rounded,
    );
  }
  return true;
}
