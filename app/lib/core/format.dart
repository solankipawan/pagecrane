/// Decimal units (1 KB = 1,000 B) with floor rounding, so "99.9 KB" really is
/// under a strict 100 KB upload limit. Same rules as the web prototype.
String fmtSize(int b) {
  if (b < 1000) return '$b B';
  if (b < 1000000) {
    final k = b / 1000;
    return k < 100 ? '${(k * 10).floor() / 10} KB' : '${k.floor()} KB';
  }
  return '${((b / 100000).floor() / 10).toStringAsFixed(1)} MB';
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String fmtDay(DateTime d) => '${d.day} ${_months[d.month - 1]} ${d.year}';

String fmtRelative(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  if (!t.isBefore(today)) {
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  }
  if (!t.isBefore(today.subtract(const Duration(days: 1)))) return 'Yesterday';
  return '${t.day} ${_months[t.month - 1]}';
}

String plural(int n, String word) => '$n $word${n == 1 ? '' : 's'}';

String greetingFor(DateTime t) => switch (t.hour) {
  < 5 => 'Working late',
  < 12 => 'Good morning',
  < 18 => 'Good afternoon',
  _ => 'Good evening',
};
