import 'package:exif/exif.dart';
import 'package:flutter/foundation.dart';
import 'package:toshiba_flashair_wifi_viewer/core/exif_orientation.dart';
import 'package:toshiba_flashair_wifi_viewer/core/metadata/photo_metadata.dart';

Future<PhotoMetadata?> parseMetadata(Uint8List bytes) async {
  try {
    final json = await compute(_parseMetadataInIsolate, bytes);
    return json == null ? null : PhotoMetadata.fromJson(json);
  } catch (_) {
    return null;
  }
}

Future<Map<String, dynamic>?> _parseMetadataInIsolate(Uint8List bytes) async {
  try {
    final tags = await readExifFromBytes(
      bytes,
      details: false,
      strict: false,
      truncateTags: true,
    );
    final fallbackOrientation = readOrientation(bytes);
    if (tags.isEmpty && fallbackOrientation == null) {
      return null;
    }

    final rawTags = <RawMetadataTag>[];
    for (final entry in tags.entries) {
      if (_privateTag(entry.key) ||
          entry.key == 'JPEGThumbnail' ||
          entry.key == 'TIFFThumbnail') {
        continue;
      }
      final separator = entry.key.indexOf(' ');
      rawTags.add(
        RawMetadataTag(
          group: separator < 0 ? 'Outros' : entry.key.substring(0, separator),
          name: separator < 0 ? entry.key : entry.key.substring(separator + 1),
          value: entry.value.printable.trim(),
        ),
      );
    }
    rawTags.sort((first, second) {
      final group = first.group.compareTo(second.group);
      return group != 0 ? group : first.name.compareTo(second.name);
    });

    final latitude = _coordinate(
      tags['GPS GPSLatitude'],
      tags['GPS GPSLatitudeRef']?.printable,
    );
    final longitude = _coordinate(
      tags['GPS GPSLongitude'],
      tags['GPS GPSLongitudeRef']?.printable,
    );
    var altitude = _number(tags['GPS GPSAltitude']);
    if (_integer(tags['GPS GPSAltitudeRef']) == 1 && altitude != null) {
      altitude = -altitude;
    }

    return PhotoMetadata(
      make: _text(tags['Image Make']),
      model: _text(tags['Image Model']),
      software: _text(tags['Image Software']),
      dateOriginal: _dateOriginal(tags),
      width:
          _integer(tags['EXIF ExifImageWidth']) ??
          _integer(tags['Image ImageWidth']),
      height:
          _integer(tags['EXIF ExifImageLength']) ??
          _integer(tags['Image ImageLength']),
      orientation:
          _validOrientation(_integer(tags['Image Orientation'])) ??
          fallbackOrientation,
      exposureTime: _number(tags['EXIF ExposureTime']),
      aperture: _number(tags['EXIF FNumber']),
      iso:
          _integer(tags['EXIF ISOSpeedRatings']) ??
          _integer(tags['EXIF PhotographicSensitivity']),
      focalLength: _number(tags['EXIF FocalLength']),
      focalLength35mm: _integer(tags['EXIF FocalLengthIn35mmFilm']),
      exposureProgram: _integer(tags['EXIF ExposureProgram']),
      meteringMode: _integer(tags['EXIF MeteringMode']),
      exposureBias: _number(tags['EXIF ExposureBiasValue']),
      whiteBalance: _integer(tags['EXIF WhiteBalance']),
      flash: _integer(tags['EXIF Flash']),
      colorSpace: _integer(tags['EXIF ColorSpace']),
      lensModel: _text(tags['EXIF LensModel']),
      latitude: latitude,
      longitude: longitude,
      altitude: altitude,
      rawTags: rawTags,
    ).toJson();
  } catch (_) {
    final orientation = readOrientation(bytes);
    return orientation == null
        ? null
        : PhotoMetadata(orientation: orientation).toJson();
  }
}

bool _privateTag(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  return normalized.contains('makernote') ||
      normalized.endsWith('bodyserialnumber') ||
      normalized.endsWith('lensserialnumber') ||
      normalized.endsWith('serialnumber');
}

String? _text(IfdTag? tag) {
  final value = tag?.printable.trim();
  return value == null || value.isEmpty ? null : value;
}

int? _integer(IfdTag? tag) {
  if (tag == null || tag.values.length == 0) return null;
  final value = tag.values.toList().firstOrNull;
  return switch (value) {
    int number => number,
    Ratio ratio when ratio.denominator != 0 => ratio.toInt(),
    _ => int.tryParse(tag.printable.trim()),
  };
}

double? _number(IfdTag? tag) {
  if (tag == null || tag.values.length == 0) return null;
  final value = tag.values.toList().firstOrNull;
  return switch (value) {
    int number => number.toDouble(),
    Ratio ratio when ratio.denominator != 0 => ratio.toDouble(),
    _ => double.tryParse(tag.printable.trim()),
  };
}

int? _validOrientation(int? value) =>
    value != null && value >= 1 && value <= 8 ? value : null;

DateTime? _dateOriginal(Map<String, IfdTag> tags) {
  final raw = _text(tags['EXIF DateTimeOriginal']);
  if (raw == null) return null;
  final match = RegExp(r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})$')
      .firstMatch(raw);
  if (match == null) return null;
  final iso =
      '${match[1]}-${match[2]}-${match[3]}T${match[4]}:${match[5]}:${match[6]}';
  final offset = _text(tags['EXIF OffsetTimeOriginal']);
  return DateTime.tryParse(offset == null ? iso : '$iso$offset');
}

double? _coordinate(IfdTag? tag, String? reference) {
  final values = tag?.values.toList();
  if (values == null || values.length < 3) return null;
  double? decimal(Object value) => switch (value) {
    int number => number.toDouble(),
    Ratio ratio when ratio.denominator != 0 => ratio.toDouble(),
    _ => null,
  };
  final degrees = decimal(values[0]);
  final minutes = decimal(values[1]);
  final seconds = decimal(values[2]);
  if (degrees == null || minutes == null || seconds == null) return null;
  final sign =
      reference?.trim().toUpperCase() == 'S' ||
          reference?.trim().toUpperCase() == 'W'
      ? -1
      : 1;
  return sign * (degrees + minutes / 60 + seconds / 3600);
}
