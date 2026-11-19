import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/haptics.dart';
import '../../settings/settings_provider.dart';

/// Reading direction, remembered across launches. Vertical (continuous scroll) is
/// the default; horizontal turns one page per swipe, as before.
class ReaderVerticalNotifier extends Notifier<bool> {
  static const _key = 'reader_vertical';

  @override
  bool build() => ref.read(prefsProvider).getBool(_key) ?? true;

  void toggle() {
    state = !state;
    ref.read(prefsProvider).setBool(_key, state);
  }
}

final readerVerticalProvider = NotifierProvider<ReaderVerticalNotifier, bool>(
  ReaderVerticalNotifier.new,
);

/// AppBar button that switches vertical ↔ horizontal page scrolling.
class ScrollDirectionButton extends ConsumerWidget {
  const ScrollDirectionButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vertical = ref.watch(readerVerticalProvider);
    return IconButton(
      tooltip: vertical
          ? 'Swipe pages horizontally'
          : 'Scroll pages vertically',
      icon: Icon(
        vertical ? Icons.view_carousel_outlined : Icons.view_day_outlined,
      ),
      onPressed: () {
        Haptics.select();
        ref.read(readerVerticalProvider.notifier).toggle();
      },
    );
  }
}

/// Renders a PDF file with pinch-zoom: continuous vertical scroll (pages fill the
/// width) or horizontal page-by-page swiping. [onPage] gets the 0-based page.
class PdfReader extends StatelessWidget {
  const PdfReader({
    super.key,
    required this.path,
    required this.vertical,
    this.onPage,
    this.initialPage = 0,
    this.onPageCount,
    this.passwordProvider,
    this.onError,
  });

  final String path;
  final bool vertical;
  final ValueChanged<int>? onPage;

  /// 0-based page to open at.
  final int initialPage;
  final ValueChanged<int>? onPageCount;
  final FutureOr<String?> Function()? passwordProvider;
  final Widget Function(BuildContext, Object)? onError;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PdfViewer.file(
      path,
      // A fresh layout per direction (callers add the file version to [key]).
      key: ValueKey('$path|$vertical|$key'),
      passwordProvider: passwordProvider,
      initialPageNumber: initialPage + 1,
      params: PdfViewerParams(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        layoutStrategy: SequentialPagesLayout(
          scrollDirection: vertical ? Axis.vertical : Axis.horizontal,
          spacing: vertical ? 12 : 24,
          margin: vertical ? 12 : 16,
          fitMode: vertical ? PdfFitMode.fill : PdfFitMode.fit,
        ),
        paging: vertical ? null : const PdfPaging(),
        pageDropShadow: BoxShadow(
          color: dark ? const Color(0x99000000) : const Color(0x2E14183C),
          blurRadius: 18,
          offset: const Offset(0, 6),
        ),
        onPageChanged: (n) {
          if (n != null) onPage?.call(n - 1);
        },
        onDocumentChanged: (doc) {
          if (doc != null) onPageCount?.call(doc.pages.length);
        },
        errorBannerBuilder: onError == null
            ? null
            : (context, error, stack, ref) => onError!(context, error),
      ),
    );
  }
}
