import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as path;

abstract interface class FileSaver {
  Future<String?> save({
    required String suggestedName,
    required Uint8List bytes,
    String? initialDirectory,
  });

  Future<int> sizeOf(String filePath);

  Future<void> openContainingFolder(String filePath);
}

class FileSelectorFileSaver implements FileSaver {
  static const Duration _writeTimeout = Duration(seconds: 60);
  static const Duration _metadataTimeout = Duration(seconds: 10);

  @override
  Future<String?> save({
    required String suggestedName,
    required Uint8List bytes,
    String? initialDirectory,
  }) async {
    try {
      final location = await getSaveLocation(
        suggestedName: suggestedName,
        initialDirectory: initialDirectory,
      );
      if (location == null) {
        return null;
      }
      await XFile.fromData(
        bytes,
        name: suggestedName,
      ).saveTo(location.path).timeout(_writeTimeout);
      return location.path;
    } catch (error) {
      throw FileSaveException('Não foi possível salvar o arquivo.', error);
    }
  }

  @override
  Future<int> sizeOf(String filePath) async {
    try {
      return await File(filePath).length().timeout(_metadataTimeout);
    } catch (error) {
      throw FileSaveException(
        'Não foi possível verificar o arquivo salvo.',
        error,
      );
    }
  }

  @override
  Future<void> openContainingFolder(String filePath) async {
    try {
      if (Platform.isWindows) {
        await Process.start('explorer.exe', <String>[
          '/select,',
          filePath,
        ], mode: ProcessStartMode.detached).timeout(_metadataTimeout);
        return;
      }
      if (Platform.isLinux) {
        await Process.start('xdg-open', <String>[
          path.dirname(filePath),
        ], mode: ProcessStartMode.detached).timeout(_metadataTimeout);
        return;
      }
      throw UnsupportedError('Sistema operacional não suportado.');
    } catch (error) {
      throw FileSaveException('Não foi possível abrir a pasta.', error);
    }
  }
}

class FileSaveException implements Exception {
  const FileSaveException(this.message, this.cause);

  final String message;
  final Object cause;

  @override
  String toString() => 'FileSaveException: $message ($cause)';
}
