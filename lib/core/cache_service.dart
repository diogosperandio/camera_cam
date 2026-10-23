import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:toshiba_flashair_wifi_viewer/core/metadata/photo_metadata.dart';

class CacheService {
  CacheService({
    Directory? cacheDirectory,
    this.maxSizeBytes = 500 * 1024 * 1024,
  }) : _cacheDirectoryOverride = cacheDirectory {
    if (maxSizeBytes < 0) {
      throw ArgumentError.value(
        maxSizeBytes,
        'maxSizeBytes',
        'Não pode ser negativo.',
      );
    }
  }

  static const Duration _ioTimeout = Duration(seconds: 10);

  final Directory? _cacheDirectoryOverride;
  final int maxSizeBytes;

  Future<Uint8List?> get(String cardPath, {int? fileSize}) {
    return _guard(
      CacheOperation.read,
      () => _get(_photosDirectory, cardPath, fileSize),
    );
  }

  Future<void> put(String cardPath, Uint8List bytes, {int? fileSize}) {
    return _guard(
      CacheOperation.write,
      () => _put(_photosDirectory, cardPath, bytes, fileSize ?? bytes.length),
    );
  }

  Future<Uint8List?> getThumb(String cardPath, {int? fileSize}) {
    return _guard(
      CacheOperation.read,
      () => _get(_thumbsDirectory, cardPath, fileSize),
    );
  }

  Future<void> putThumb(String cardPath, Uint8List bytes, {int? fileSize}) {
    return _guard(
      CacheOperation.write,
      () => _put(_thumbsDirectory, cardPath, bytes, fileSize ?? bytes.length),
    );
  }

  Future<PhotoMetadata?> getMetadata(String cardPath, {required int fileSize}) {
    return _guard(CacheOperation.read, () async {
      final bytes = await _get(_metadataDirectory, cardPath, fileSize);
      if (bytes == null) return null;
      final decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map<String, dynamic>
          ? PhotoMetadata.fromJson(decoded)
          : null;
    });
  }

  Future<void> putMetadata(
    String cardPath,
    PhotoMetadata metadata, {
    required int fileSize,
  }) {
    return _guard(
      CacheOperation.write,
      () => _put(
        _metadataDirectory,
        cardPath,
        Uint8List.fromList(utf8.encode(jsonEncode(metadata.toJson()))),
        fileSize,
      ),
    );
  }

  Future<void> remove(String cardPath) {
    return _guard(CacheOperation.remove, () async {
      await _removeVariants(await _photosDirectory(), cardPath);
      await _removeVariants(await _thumbsDirectory(), cardPath);
      await _removeVariants(await _metadataDirectory(), cardPath);
    });
  }

  Future<void> clear() {
    return _guard(CacheOperation.clear, () async {
      final root = await _cacheRoot();
      final photos = Directory(path.join(root.path, 'photos'));
      final thumbs = Directory(path.join(root.path, 'thumbs'));
      final metadata = Directory(path.join(root.path, 'metadata'));
      if (await photos.exists()) {
        await photos.delete(recursive: true);
      }
      if (await thumbs.exists()) {
        await thumbs.delete(recursive: true);
      }
      if (await metadata.exists()) {
        await metadata.delete(recursive: true);
      }
      await photos.create(recursive: true);
      await thumbs.create(recursive: true);
      await metadata.create(recursive: true);
    });
  }

  Future<int> sizeOnDisk() {
    return _guard(CacheOperation.measure, () async {
      final files = await _allCacheFiles();
      var total = 0;
      for (final file in files) {
        total += await file.length();
      }
      return total;
    });
  }

  Future<Uint8List?> _get(
    Future<Directory> Function() directoryProvider,
    String cardPath,
    int? fileSize,
  ) async {
    _validateCardPath(cardPath);
    final directory = await directoryProvider();
    final variants = await _variants(directory, cardPath);

    File? cachedFile;
    if (fileSize != null) {
      if (fileSize < 0) {
        throw ArgumentError.value(
          fileSize,
          'fileSize',
          'Não pode ser negativo.',
        );
      }
      final expectedName = _cacheFileName(cardPath, fileSize);
      for (final variant in variants) {
        if (path.basename(variant.path) == expectedName) {
          cachedFile = variant;
        } else {
          await variant.delete();
        }
      }
    } else if (variants.isNotEmpty) {
      final datedFiles = <({File file, DateTime modified})>[];
      for (final variant in variants) {
        datedFiles.add((file: variant, modified: await variant.lastModified()));
      }
      datedFiles.sort(
        (first, second) => second.modified.compareTo(first.modified),
      );
      cachedFile = datedFiles.first.file;
    }

    if (cachedFile == null || !await cachedFile.exists()) {
      return null;
    }
    final bytes = await cachedFile.readAsBytes();
    await cachedFile.setLastModified(DateTime.now());
    return bytes;
  }

  Future<void> _put(
    Future<Directory> Function() directoryProvider,
    String cardPath,
    Uint8List bytes,
    int fileSize,
  ) async {
    _validateCardPath(cardPath);
    if (fileSize < 0) {
      throw ArgumentError.value(fileSize, 'fileSize', 'Não pode ser negativo.');
    }

    final directory = await directoryProvider();
    await _removeVariants(directory, cardPath);
    final file = File(
      path.join(directory.path, _cacheFileName(cardPath, fileSize)),
    );
    await file.writeAsBytes(bytes, flush: true);
    await _enforceSizeLimit();
  }

  Future<void> _enforceSizeLimit() async {
    final files = await _allCacheFiles();
    final datedFiles = <({File file, int size, DateTime modified})>[];
    var total = 0;
    for (final file in files) {
      final stat = await file.stat();
      total += stat.size;
      datedFiles.add((file: file, size: stat.size, modified: stat.modified));
    }
    datedFiles.sort(
      (first, second) => first.modified.compareTo(second.modified),
    );

    for (final entry in datedFiles) {
      if (total <= maxSizeBytes) {
        break;
      }
      await entry.file.delete();
      total -= entry.size;
    }
  }

  Future<List<File>> _allCacheFiles() async {
    final photos = await _photosDirectory();
    final thumbs = await _thumbsDirectory();
    final metadata = await _metadataDirectory();
    return <File>[
      ...await _files(photos),
      ...await _files(thumbs),
      ...await _files(metadata),
    ];
  }

  Future<List<File>> _variants(Directory directory, String cardPath) async {
    final prefix = '${_hashCardPath(cardPath)}-';
    return (await _files(directory))
        .where((file) => path.basename(file.path).startsWith(prefix))
        .toList();
  }

  Future<void> _removeVariants(Directory directory, String cardPath) async {
    for (final file in await _variants(directory, cardPath)) {
      await file.delete();
    }
  }

  Future<List<File>> _files(Directory directory) async {
    final entities = await directory.list().toList();
    return entities.whereType<File>().toList();
  }

  Future<Directory> _photosDirectory() => _subdirectory('photos');

  Future<Directory> _thumbsDirectory() => _subdirectory('thumbs');

  Future<Directory> _metadataDirectory() => _subdirectory('metadata');

  Future<Directory> _subdirectory(String name) async {
    final root = await _cacheRoot();
    return Directory(path.join(root.path, name)).create(recursive: true);
  }

  Future<Directory> _cacheRoot() async {
    return _cacheDirectoryOverride ?? await getApplicationCacheDirectory();
  }

  Future<T> _guard<T>(
    CacheOperation operation,
    Future<T> Function() action,
  ) async {
    try {
      return await action().timeout(_ioTimeout);
    } on CacheException {
      rethrow;
    } catch (error) {
      throw CacheException(operation: operation, cause: error);
    }
  }
}

enum CacheOperation { read, write, remove, clear, measure }

class CacheException implements Exception {
  const CacheException({required this.operation, required this.cause});

  final CacheOperation operation;
  final Object cause;

  @override
  String toString() => 'CacheException($operation): $cause';
}

String _cacheFileName(String cardPath, int fileSize) {
  return '${_hashCardPath(cardPath)}-$fileSize.cache';
}

String _hashCardPath(String cardPath) {
  var hash = 0xcbf29ce484222325;
  for (final byte in utf8.encode(cardPath)) {
    hash ^= byte;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

void _validateCardPath(String cardPath) {
  if (cardPath.trim().isEmpty) {
    throw ArgumentError.value(cardPath, 'cardPath', 'Não pode estar vazio.');
  }
}
