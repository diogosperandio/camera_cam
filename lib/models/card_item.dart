class CardItem {
  const CardItem({
    required this.name,
    required this.parentPath,
    required this.size,
    required this.isDir,
    this.dateTime,
  });

  static const Set<String> _imageExtensions = <String>{'jpg', 'jpeg', 'png'};
  static const Set<String> _rawExtensions = <String>{
    'cr2',
    'cr3',
    'nef',
    'arw',
    'orf',
    'rw2',
    'dng',
  };

  final String name;
  final String parentPath;
  final int size;
  final bool isDir;
  final DateTime? dateTime;

  String get fullPath {
    final normalizedParent = parentPath.endsWith('/') && parentPath.length > 1
        ? parentPath.substring(0, parentPath.length - 1)
        : parentPath;
    return normalizedParent == '/' ? '/$name' : '$normalizedParent/$name';
  }

  bool get isImage => !isDir && _imageExtensions.contains(_extension);

  bool get isRaw => !isDir && _rawExtensions.contains(_extension);

  String get _extension {
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex < 0 || dotIndex == name.length - 1) {
      return '';
    }
    return name.substring(dotIndex + 1).toLowerCase();
  }
}
