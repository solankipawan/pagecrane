import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/format.dart';
import '../data/doc_repository.dart';
import '../data/documents_provider.dart';
import '../data/stored_doc.dart';

/// The repository once opened (null during the first frame).
final repoSyncProvider = Provider<DocRepository?>(
  (ref) => switch (ref.watch(repoProvider)) {
    AsyncData(:final value) => value,
    _ => null,
  },
);

class DocThumb extends ConsumerWidget {
  const DocThumb(this.doc, {super.key, this.width = 42, this.height = 54});
  final StoredDoc doc;
  final double width, height;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repoSyncProvider);
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F000000),
            blurRadius: 8,
            offset: Offset(0, 2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: repo == null
          ? null
          : Image.file(
              repo.thumbOf(doc.id),
              key: ValueKey(doc.updatedAt),
              // Thumbs are 240 px; decode at display size × device pixel ratio.
              cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                  .ceil(),
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) =>
                  const Icon(Icons.description_rounded, color: Colors.black26),
            ),
    );
  }
}

class DocTile extends StatelessWidget {
  const DocTile(this.doc, {super.key, this.showDivider = true});
  final StoredDoc doc;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final px = context.px;
    return InkWell(
      onTap: () => context.push('/doc/${doc.id}'),
      child: Container(
        constraints: const BoxConstraints(minHeight: 72),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: showDivider
              ? Border(bottom: BorderSide(color: px.hairline))
              : null,
        ),
        child: Row(
          children: [
            DocThumb(doc),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    doc.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.tt.titleMedium,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: px.pdf.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          'PDF',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            color: px.pdf,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          '${plural(doc.pageCount, 'page')} · ${fmtSize(doc.sizeBytes)} · ${fmtRelative(doc.updatedAt)}',
                          style: context.tt.bodySmall?.copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (doc.starred)
              const Padding(
                padding: EdgeInsets.only(left: 6),
                child: Icon(
                  Icons.star_rounded,
                  size: 18,
                  color: Color(0xFFF5B301),
                ),
              ),
            Icon(Icons.chevron_right_rounded, color: px.muted),
          ],
        ),
      ),
    );
  }
}
