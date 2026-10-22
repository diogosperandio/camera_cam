import 'package:camera_cam/core/exif_orientation.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;

abstract interface class ImageExporter {
  Future<Uint8List> exportJpeg(Uint8List bytes, int orientation);
}

class IsolateImageExporter implements ImageExporter {
  const IsolateImageExporter();

  @override
  Future<Uint8List> exportJpeg(Uint8List bytes, int orientation) {
    return compute(_exportJpeg, (bytes: bytes, orientation: orientation));
  }
}

Uint8List _exportJpeg(({Uint8List bytes, int orientation}) request) {
  var decoded = image.decodeJpg(request.bytes);
  if (decoded == null) {
    throw const ImageExportException(
      'O arquivo JPEG não pôde ser decodificado.',
    );
  }
  final parts = orientationParts(request.orientation);
  if (parts.flipH) {
    decoded = image.copyFlip(
      decoded,
      direction: image.FlipDirection.horizontal,
    );
  }
  if (parts.turns != 0) {
    decoded = image.copyRotate(decoded, angle: parts.turns * 90);
  }
  decoded.exif.imageIfd.orientation = 1;
  return image.encodeJpg(decoded, quality: 95);
}

class ImageExportException implements Exception {
  const ImageExportException(this.message);

  final String message;

  @override
  String toString() => message;
}
