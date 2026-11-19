// Page-range helpers for Split. User-facing numbers are 1-based; indices are 0-based.

/// Parses "1-3, 7, 9-" into sorted, de-duplicated 0-based indices.
/// Open ends are allowed ("-3" = 1–3, "9-" = 9–last). Throws [FormatException].
List<int> parsePageRanges(String input, int pageCount) {
  final out = <int>{};
  for (final raw in input.split(',')) {
    final part = raw.trim();
    if (part.isEmpty) continue;
    final m = RegExp(r'^(\d*)\s*[-–]\s*(\d*)$').firstMatch(part);
    final int a, b;
    if (m != null) {
      a = m[1]!.isEmpty ? 1 : int.parse(m[1]!);
      b = m[2]!.isEmpty ? pageCount : int.parse(m[2]!);
    } else {
      final n = int.tryParse(part);
      if (n == null) throw FormatException('“$part” isn’t a page number');
      a = n;
      b = n;
    }
    if (a < 1 || b > pageCount || a > b) {
      throw FormatException('“$part” is outside 1–$pageCount');
    }
    for (var i = a; i <= b; i++) {
      out.add(i - 1);
    }
  }
  return out.toList()..sort();
}

/// Formats 0-based indices as compact 1-based ranges: [0,1,2,6] → "1-3, 7".
String formatPageRanges(List<int> indices) {
  final s = [
    ...{...indices},
  ]..sort();
  final parts = <String>[];
  for (var i = 0; i < s.length; i++) {
    final start = s[i];
    while (i + 1 < s.length && s[i + 1] == s[i] + 1) {
      i++;
    }
    parts.add(start == s[i] ? '${start + 1}' : '${start + 1}-${s[i] + 1}');
  }
  return parts.join(', ');
}

/// Splits [count] pages into consecutive parts of [every] pages.
List<List<int>> chunkPages(int count, int every) => [
  for (var start = 0; start < count; start += every)
    [for (var i = start; i < start + every && i < count; i++) i],
];
