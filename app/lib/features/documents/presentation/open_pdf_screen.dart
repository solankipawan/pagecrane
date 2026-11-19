import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:share_plus/share_plus.dart';

import '../../../app/theme/tokens.dart';
import '../../../core/haptics.dart';
import '../../../core/widgets/common.dart';
import '../../../core/widgets/status_cards.dart';
import 'import_pdf_flow.dart';
import 'pdf_reader.dart';

/// A PDF opened from another app ("Open with Pagecrane"). Read-only: scroll it,
/// share it, or save a copy into the library. The file is a private copy in the
/// app cache; the original is never modified.
class OpenPdfScreen extends ConsumerStatefulWidget {
  const OpenPdfScreen({super.key, required this.path, required this.name});
  final String path;
  final String name;

  @override
  ConsumerState<OpenPdfScreen> createState() => _OpenPdfScreenState();
}

class _OpenPdfScreenState extends ConsumerState<OpenPdfScreen> {
  int _page = 0;
  int? _pages;
  int _passwordTries = 0;

  Future<String?> _askPassword() async {
    _passwordTries++;
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(
          _passwordTries > 1 ? 'Wrong password' : 'Password required',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '“${widget.name}.pdf” is protected. The password is only used to open it on this device.',
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

  Future<void> _share() async {
    Haptics.light();
    final box = context.findRenderObject() as RenderBox?;
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile(
            widget.path,
            mimeType: 'application/pdf',
            name: '${widget.name}.pdf',
          ),
        ],
        sharePositionOrigin: box == null
            ? null
            : box.localToGlobal(Offset.zero) & box.size,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final vertical = ref.watch(readerVerticalProvider);
    final exists = File(widget.path).existsSync();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.name, overflow: TextOverflow.ellipsis),
        actions: [
          const ScrollDirectionButton(),
          IconButton(
            tooltip: 'Share',
            icon: const Icon(Icons.ios_share_rounded),
            onPressed: exists ? _share : null,
          ),
        ],
      ),
      body: !exists
          ? const EmptyState(
              icon: Icons.description_outlined,
              title: 'This file is no longer available',
              body: 'Open it again from the app you came from.',
            )
          : Column(
              children: [
                Expanded(
                  child: PdfReader(
                    path: widget.path,
                    vertical: vertical,
                    passwordProvider: _askPassword,
                    onPage: (p) => setState(() => _page = p),
                    onPageCount: (n) => setState(() => _pages = n),
                    onError: (context, error) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: IssueCard(
                          title: 'Couldn’t open this PDF',
                          reason: 'It may be damaged, or protected with a password you didn’t enter.',
                          icon: Icons.error_outline_rounded,
                          primaryLabel: 'Try again',
                          onPrimary: () {
                            _passwordTries = 0;
                            setState(() {});
                          },
                        ),
                      ),
                    ),
                  ),
                ),
                if (_pages != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, bottom: 4),
                    child: Text(
                      'Page ${_page + 1} of $_pages',
                      style: context.tt.bodySmall?.copyWith(
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: FilledButton.icon(
                      onPressed: () => importPdfFile(context, ref, (
                        path: widget.path,
                        name: widget.name,
                      )),
                      icon: const Icon(Icons.library_add_rounded),
                      label: const Text('Save to Pagecrane'),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
