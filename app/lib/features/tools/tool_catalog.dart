import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../app/theme/tokens.dart';
import '../../core/format.dart';
import '../../core/haptics.dart';
import '../../core/widgets/common.dart';
import '../documents/data/documents_provider.dart';
import '../documents/data/stored_doc.dart';
import '../documents/presentation/doc_tile.dart';
import '../documents/presentation/import_pdf_flow.dart';
import '../scanner/presentation/capture_sheet.dart';

/// Every tool in the app. No [route], [docRoute] or [scan] = not built yet.
class ToolDef {
  const ToolDef(
    this.id,
    this.label,
    this.name,
    this.desc,
    this.icon,
    this.cat, {
    this.route,
    this.docRoute,
    this.scan = false,
    this.importsPdf = false,
  });
  final String id, label, name, desc;
  final IconData icon;
  final ToolCategory cat;
  final String? route;

  /// Route that needs a document first; `{id}` is replaced after the user picks one.
  final String? docRoute;
  final bool scan;
  final bool importsPdf;

  bool get available => route != null || docRoute != null || scan || importsPdf;
}

const tools = <String, ToolDef>{
  'scan': ToolDef(
    'scan',
    'Scan',
    'Document scanner',
    'Camera to PDF with auto-crop',
    Icons.document_scanner_rounded,
    ToolCategory.scan,
    scan: true,
  ),
  'merge': ToolDef(
    'merge',
    'Merge',
    'Merge PDFs',
    'Combine documents, drag to reorder',
    Icons.layers_rounded,
    ToolCategory.pdf,
    route: '/tool/merge',
  ),
  'split': ToolDef(
    'split',
    'Split',
    'Split PDF',
    'Extract pages or split every N pages',
    Icons.content_cut_rounded,
    ToolCategory.pdf,
    route: '/tool/split',
  ),
  'compress': ToolDef(
    'compress',
    'Compress',
    'Compress PDF',
    'Low · Medium · High with size preview',
    Icons.compress_rounded,
    ToolCategory.pdf,
    route: '/tool/compress',
  ),
  'sign': ToolDef(
    'sign',
    'Sign',
    'Sign & annotate',
    'Signature, pen, highlight, text',
    Icons.draw_rounded,
    ToolCategory.pdf,
    docRoute: '/doc/{id}/annotate',
  ),
  'target': ToolDef(
    'target',
    'Under KB',
    'Compress to size',
    'Hit limits like “under 100 KB”',
    Icons.speed_rounded,
    ToolCategory.image,
    route: '/tool/target-size',
  ),
  'resize': ToolDef(
    'resize',
    'Resize',
    'Resize image',
    'Scale by %, JPEG quality',
    Icons.photo_size_select_large_rounded,
    ToolCategory.image,
    route: '/tool/target-size?mode=scale',
  ),
  'convert': ToolDef(
    'convert',
    'To PDF',
    'Images to PDF',
    'Import photos → auto-cropped PDF',
    Icons.picture_as_pdf_rounded,
    ToolCategory.convert,
    scan: true,
  ),
  'pdf2img': ToolDef(
    'pdf2img',
    'PDF → JPG',
    'PDF to images',
    'Export pages as JPG or PNG',
    Icons.image_rounded,
    ToolCategory.convert,
    route: '/tool/export-images',
  ),
  'importpdf': ToolDef(
    'importpdf',
    'Import PDF',
    'Import PDF',
    'Add a PDF from Files to your library',
    Icons.file_open_rounded,
    ToolCategory.convert,
    importsPdf: true,
  ),
};

const quickTools = [
  'scan',
  'merge',
  'split',
  'compress',
  'resize',
  'target',
  'convert',
  'sign',
];

void openTool(BuildContext context, WidgetRef ref, ToolDef t) {
  Haptics.select();
  if (t.scan) {
    startScan(context, ref);
  } else if (t.importsPdf) {
    importPdf(context, ref);
  } else if (t.route != null) {
    context.push(t.route!);
  } else if (t.docRoute != null) {
    _pickDocThen(context, ref, t);
  } else {
    showToast(
      context,
      '${t.name} is coming in a later build',
      icon: Icons.schedule_rounded,
    );
  }
}

Future<void> _pickDocThen(
  BuildContext context,
  WidgetRef ref,
  ToolDef t,
) async {
  final docs = ref.read(documentsProvider).value ?? const <StoredDoc>[];
  if (docs.isEmpty) {
    showToast(
      context,
      'Scan or import a document first',
      icon: Icons.info_outline_rounded,
    );
    return;
  }
  final id = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true, // above the shell's tab bar
    isScrollControlled: true,
    builder: (c) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('${t.name}: choose a document', style: c.tt.titleLarge),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.only(
                bottom: MediaQuery.paddingOf(c).bottom + 12,
              ),
              children: [
                for (final d in docs)
                  ListTile(
                    leading: DocThumb(d, width: 34, height: 44),
                    title: Text(
                      d.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${plural(d.pageCount, 'page')} · ${fmtSize(d.sizeBytes)}',
                    ),
                    onTap: () => Navigator.pop(c, d.id),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  if (id != null && context.mounted) {
    context.push(t.docRoute!.replaceFirst('{id}', id));
  }
}
