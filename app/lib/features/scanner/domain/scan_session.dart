import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'doc_detect.dart' show Pt;
import 'filters.dart';
import 'page_pipeline.dart';

/// A captured page waiting in Review. [source] is the cropped, unfiltered page;
/// [preview] is the filtered + rotated rendering shown on screen (null while rendering).
@immutable
class ScanPage {
  const ScanPage({
    required this.id,
    required this.source,
    required this.filter,
    this.quarterTurns = 0,
    this.preview,
    this.autoCropped = true,
    required this.original,
    this.corners,
  });
  final String id;
  final Uint8List source;
  final ScanFilter filter;
  final int quarterTurns;
  final Uint8List? preview;
  final bool autoCropped;

  /// The whole photo [source] was cut from, and where (normalised TL TR BR BL;
  /// null = the whole photo). Lets the crop be adjusted.
  final Uint8List original;
  final List<Pt>? corners;

  ScanPage copyWith({
    ScanFilter? filter,
    int? quarterTurns,
    Uint8List? preview,
    bool clearPreview = false,
  }) => ScanPage(
    id: id,
    source: source,
    filter: filter ?? this.filter,
    quarterTurns: quarterTurns ?? this.quarterTurns,
    preview: clearPreview ? null : (preview ?? this.preview),
    autoCropped: autoCropped,
    original: original,
    corners: corners,
  );

  ScanPage recropped(Uint8List source, List<Pt>? corners) => ScanPage(
    id: id,
    source: source,
    filter: filter,
    quarterTurns: quarterTurns,
    autoCropped: corners != null,
    original: original,
    corners: corners,
  );
}

class ScanSessionNotifier extends Notifier<List<ScanPage>> {
  var _seq = 0;

  @override
  List<ScanPage> build() => const [];

  void addPages(List<PageCrop> pages, ScanFilter filter) {
    final added = [
      for (final p in pages)
        ScanPage(
          id: 'p${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
          source: p.jpeg,
          filter: filter,
          autoCropped: p.cropped,
          // System-scanner pages come pre-cut: their "original" is the page itself.
          original: p.original ?? p.jpeg,
          corners: p.original == null ? null : p.corners,
        ),
    ];
    state = [...state, ...added];
    for (final p in added) {
      _renderPreview(p.id);
    }
  }

  void setFilter(int index, ScanFilter f, {bool all = false}) {
    state = [
      for (var i = 0; i < state.length; i++)
        if (all || i == index)
          state[i].copyWith(filter: f, clearPreview: true)
        else
          state[i],
    ];
    for (var i = 0; i < state.length; i++) {
      if (all || i == index) _renderPreview(state[i].id);
    }
  }

  void rotate(int index) {
    final p = state[index];
    _replace(
      p.id,
      p.copyWith(quarterTurns: (p.quarterTurns + 1) % 4, clearPreview: true),
    );
    _renderPreview(p.id);
  }

  /// Re-cuts page [index] from its original photo along [corners] (null = whole).
  Future<void> setCorners(int index, List<Pt>? corners) async {
    final p = state[index];
    final src = await compute(cropPage, (
      original: p.original,
      corners: corners,
    ));
    if (!state.any((x) => x.id == p.id)) return;
    _replace(p.id, p.recropped(src, corners));
    _renderPreview(p.id);
  }

  void removeAt(int index) => state = [...state]..removeAt(index);

  /// [to] is the final index (already adjusted for the removed item).
  void reorder(int from, int to) {
    final list = [...state];
    list.insert(to, list.removeAt(from));
    state = list;
  }

  void clear() => state = const [];

  /// Final full-resolution pages for saving.
  Future<List<Uint8List>> renderAll({void Function(double)? onProgress}) async {
    final out = <Uint8List>[];
    final pages = state;
    for (var i = 0; i < pages.length; i++) {
      final p = pages[i];
      out.add(
        await compute(renderPage, (
          src: p.source,
          filter: p.filter,
          quarterTurns: p.quarterTurns,
          maxDim: maxPageDim,
          quality: 85,
        )),
      );
      onProgress?.call((i + 1) / pages.length);
    }
    return out;
  }

  void _replace(String id, ScanPage next) =>
      state = [for (final p in state) p.id == id ? next : p];

  Future<void> _renderPreview(String id) async {
    final p = state.where((x) => x.id == id).firstOrNull;
    if (p == null) return;
    final (filter, turns, src) = (p.filter, p.quarterTurns, p.source);
    final bytes = await compute(renderPage, (
      src: src,
      filter: filter,
      quarterTurns: turns,
      maxDim: 1400,
      quality: 80,
    ));
    final now = state.where((x) => x.id == id).firstOrNull;
    // Drop stale results: the user may have changed filter/rotation meanwhile.
    if (now != null && now.filter == filter && now.quarterTurns == turns) {
      _replace(id, now.copyWith(preview: bytes));
    }
  }
}

final scanSessionProvider =
    NotifierProvider<ScanSessionNotifier, List<ScanPage>>(
      ScanSessionNotifier.new,
    );
