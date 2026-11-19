/// Compression levels (docs/ARCHITECTURE.md §5): JPEG quality + resolution scale.
enum CompressLevel {
  low('Low', 'Best quality · ~200 DPI', quality: 82, scale: 1.0),
  medium('Medium', 'Recommended · ~150 DPI', quality: 62, scale: 0.75),
  high('High', 'Smallest · ~110 DPI', quality: 42, scale: 0.55);

  const CompressLevel(
    this.label,
    this.subtitle, {
    required this.quality,
    required this.scale,
  });
  final String label;
  final String subtitle;
  final int quality;
  final double scale;
}
