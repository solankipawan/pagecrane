import 'package:flutter/foundation.dart';

/// One document in the on-device library. Pages live as JPEGs next to a built PDF:
/// `<root>/<id>/page_000.jpg …, thumb.jpg, document.pdf`.
@immutable
class StoredDoc {
  const StoredDoc({
    required this.id,
    required this.name,
    required this.folder,
    required this.createdAt,
    required this.updatedAt,
    required this.pageCount,
    required this.sizeBytes,
    this.starred = false,
  });

  final String id;
  final String name;
  final String folder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int pageCount;

  /// Size of the built PDF on disk.
  final int sizeBytes;
  final bool starred;

  StoredDoc copyWith({
    String? name,
    String? folder,
    DateTime? updatedAt,
    int? pageCount,
    int? sizeBytes,
    bool? starred,
  }) => StoredDoc(
    id: id,
    name: name ?? this.name,
    folder: folder ?? this.folder,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    pageCount: pageCount ?? this.pageCount,
    sizeBytes: sizeBytes ?? this.sizeBytes,
    starred: starred ?? this.starred,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'folder': folder,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'pageCount': pageCount,
    'sizeBytes': sizeBytes,
    'starred': starred,
  };

  factory StoredDoc.fromJson(Map<String, Object?> j) => StoredDoc(
    id: j['id']! as String,
    name: j['name']! as String,
    folder: j['folder'] as String? ?? 'Scans',
    createdAt: DateTime.parse(j['createdAt']! as String),
    updatedAt: DateTime.parse((j['updatedAt'] ?? j['createdAt'])! as String),
    pageCount: j['pageCount']! as int,
    sizeBytes: j['sizeBytes']! as int,
    starred: j['starred'] as bool? ?? false,
  );
}
