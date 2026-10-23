import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:toshiba_flashair_wifi_viewer/core/metadata/metadata_reader.dart';

void main() {
  for (final endian in <Endian>[Endian.little, Endian.big]) {
    test('parses the required EXIF fields in $endian byte order', () async {
      final metadata = await parseMetadata(_metadataJpeg(endian));

      expect(metadata, isNotNull);
      expect(metadata!.make, 'NIKON CORPORATION');
      expect(metadata.model, 'NIKON 1 J1');
      expect(metadata.orientation, 6);
      expect(metadata.exposureTime, closeTo(1 / 250, 0.000001));
      expect(metadata.aperture, 5.6);
      expect(metadata.iso, 200);
      expect(metadata.focalLength, 10);
      expect(metadata.dateOriginal, DateTime(2019, 2, 18, 9, 15, 36));
      expect(metadata.width, 3872);
      expect(metadata.height, 2592);
      expect(metadata.lensModel, '1 NIKKOR VR 10-30mm');
      final rawNames = metadata.rawTags.map((tag) => tag.name.toLowerCase());
      expect(rawNames.any((name) => name.contains('serial')), isFalse);
      expect(
        metadata.rawTags.any(
          (tag) => tag.name.toLowerCase().contains('makernote'),
        ),
        isFalse,
      );
    });
  }

  test('returns null without EXIF and partial data without throwing', () async {
    expect(
      await parseMetadata(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9])),
      isNull,
    );
    final full = _metadataJpeg(Endian.little);
    final truncated = Uint8List.sublistView(full, 0, full.length - 20);
    final metadata = await parseMetadata(truncated);
    expect(metadata?.model, 'NIKON 1 J1');
    expect(metadata?.orientation, 6);
  });
}

Uint8List _metadataJpeg(Endian endian) {
  const ifd0Entries = 4;
  const exifEntries = 10;
  const ifd0Offset = 8;
  const exifOffset = ifd0Offset + 2 + ifd0Entries * 12 + 4;
  const valuesOffset = exifOffset + 2 + exifEntries * 12 + 4;
  final values = BytesBuilder(copy: false);
  final offsets = <String, int>{};

  int addAscii(String key, String value) {
    final offset = valuesOffset + values.length;
    offsets[key] = offset;
    values.add(<int>[...ascii.encode(value), 0]);
    return offset;
  }

  int addRatio(String key, int numerator, int denominator) {
    final offset = valuesOffset + values.length;
    offsets[key] = offset;
    final bytes = Uint8List(8);
    ByteData.sublistView(bytes)
      ..setUint32(0, numerator, endian)
      ..setUint32(4, denominator, endian);
    values.add(bytes);
    return offset;
  }

  addAscii('make', 'NIKON CORPORATION');
  addAscii('model', 'NIKON 1 J1');
  addAscii('date', '2019:02:18 09:15:36');
  addRatio('exposure', 1, 250);
  addRatio('aperture', 56, 10);
  addRatio('focal', 10, 1);
  addAscii('lens', '1 NIKKOR VR 10-30mm');
  addAscii('bodySerial', 'PRIVATE-BODY');
  addAscii('lensSerial', 'PRIVATE-LENS');

  final tiffLength = valuesOffset + values.length;
  final payloadLength = 6 + tiffLength;
  final bytes = Uint8List(2 + 2 + 2 + payloadLength + 2);
  final data = ByteData.sublistView(bytes);
  bytes
    ..[0] = 0xFF
    ..[1] = 0xD8
    ..[2] = 0xFF
    ..[3] = 0xE1;
  data.setUint16(4, payloadLength + 2, Endian.big);
  bytes.setRange(6, 12, const <int>[0x45, 0x78, 0x69, 0x66, 0, 0]);
  const tiff = 12;
  data
    ..setUint16(tiff, endian == Endian.little ? 0x4949 : 0x4D4D, Endian.big)
    ..setUint16(tiff + 2, 42, endian)
    ..setUint32(tiff + 4, ifd0Offset, endian)
    ..setUint16(tiff + ifd0Offset, ifd0Entries, endian);

  var entry = tiff + ifd0Offset + 2;
  void writeEntry(int tag, int type, int count, int value) {
    data
      ..setUint16(entry, tag, endian)
      ..setUint16(entry + 2, type, endian)
      ..setUint32(entry + 4, count, endian);
    if (type == 3 && count == 1) {
      data.setUint16(entry + 8, value, endian);
    } else {
      data.setUint32(entry + 8, value, endian);
    }
    entry += 12;
  }

  writeEntry(0x010F, 2, 'NIKON CORPORATION'.length + 1, offsets['make']!);
  writeEntry(0x0110, 2, 'NIKON 1 J1'.length + 1, offsets['model']!);
  writeEntry(0x0112, 3, 1, 6);
  writeEntry(0x8769, 4, 1, exifOffset);
  data.setUint32(entry, 0, endian);

  entry = tiff + exifOffset;
  data.setUint16(entry, exifEntries, endian);
  entry += 2;
  writeEntry(0x829A, 5, 1, offsets['exposure']!);
  writeEntry(0x829D, 5, 1, offsets['aperture']!);
  writeEntry(0x8827, 3, 1, 200);
  writeEntry(0x9003, 2, '2019:02:18 09:15:36'.length + 1, offsets['date']!);
  writeEntry(0x920A, 5, 1, offsets['focal']!);
  writeEntry(0xA002, 4, 1, 3872);
  writeEntry(0xA003, 4, 1, 2592);
  writeEntry(0xA431, 2, 'PRIVATE-BODY'.length + 1, offsets['bodySerial']!);
  writeEntry(0xA434, 2, '1 NIKKOR VR 10-30mm'.length + 1, offsets['lens']!);
  writeEntry(0xA435, 2, 'PRIVATE-LENS'.length + 1, offsets['lensSerial']!);
  data.setUint32(entry, 0, endian);
  bytes.setRange(tiff + valuesOffset, tiff + tiffLength, values.takeBytes());
  bytes
    ..[bytes.length - 2] = 0xFF
    ..[bytes.length - 1] = 0xD9;
  return bytes;
}
