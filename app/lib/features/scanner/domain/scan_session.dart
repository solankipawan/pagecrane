import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  });
  final String id;
  final Uint8List source;
  final ScanFilter filter;
  final int quarterTurns;
  final Uint8List? preview;
  final bool autoCropped;

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
  );
}

class ScanSessionNotifier extends Notifier<List<ScanPage>> {
  var _seq = 0;

  @override
  List<ScanPage> build() => const [];

  void addPages(
    List<({Uint8List jpeg, bool cropped})> pages,
    ScanFilter filter,
  ) {
    final added = [
      for (final p in pages)
        ScanPage(
          id: 'p${DateTime.now().microsecondsSinceEpoch}_${_seq++}',
          source: p.jpeg,
          filter: filter,
          autoCropped: p.cropped,
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
