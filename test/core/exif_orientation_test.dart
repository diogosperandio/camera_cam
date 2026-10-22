import 'dart:typed_data';

import 'package:toshiba_flashair_wifi_viewer/core/exif_orientation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  group('composeOrientation', () {
    test('uses the specified clockwise table', () {
      const expected = <int, int>{
        1: 6,
        6: 3,
        3: 8,
        8: 1,
        2: 7,
        7: 4,
        4: 5,
        5: 2,
      };
      for (final entry in expected.entries) {
        expect(composeOrientation(entry.key, 1), entry.value);
      }
    });

    test('four clockwise turns and CW followed by CCW are identities', () {
      for (var orientation = 1; orientation <= 8; orientation++) {
        expect(composeOrientation(orientation, 4), orientation);
        expect(
          composeOrientation(composeOrientation(orientation, 1), -1),
          orientation,
        );
      }
    });
  });

  test('orientationParts describes all EXIF orientations', () {
    expect(orientationParts(1), (turns: 0, flipH: false));
    expect(orientationParts(2), (turns: 0, flipH: true));
    expect(orientationParts(3), (turns: 2, flipH: false));
    expect(orientationParts(4), (turns: 2, flipH: true));
    expect(orientationParts(5), (turns: 3, flipH: true));
    expect(orientationParts(6), (turns: 1, flipH: false));
    expect(orientationParts(7), (turns: 1, flipH: true));
    expect(orientationParts(8), (turns: 3, flipH: false));
  });

  group('readOrientation', () {
    test('reads little and big endian orientation', () {
      expect(readOrientation(_jpegWithExif(Endian.little, 6)), 6);
      expect(readOrientation(_jpegWithExif(Endian.big, 6)), 6);
    });

    test('returns null for missing EXIF, missing tag and truncation', () {
      expect(
        readOrientation(Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xd9])),
        isNull,
      );
      expect(
        readOrientation(_jpegWithExif(Endian.big, 6, includeTag: false)),
        isNull,
      );
      expect(
        readOrientation(
          Uint8List.fromList(<int>[0xff, 0xd8, 0xff, 0xe1, 0, 40]),
        ),
        isNull,
      );
    });
  });

  group('writeOrientation', () {
    for (final endian in <Endian>[Endian.little, Endian.big]) {
      test('changes only the two value bytes for $endian', () {
        final original = _jpegWithExif(endian, 6);
        final changed = writeOrientation(original, 3)!;
        expect(changed.length, original.length);
        final differences = <int>[
          for (var index = 0; index < original.length; index++)
            if (original[index] != changed[index]) index,
        ];
        expect(
          differences.every((index) => index == 30 || index == 31),
          isTrue,
        );
        expect(readOrientation(changed), 3);
      });
    }

    test('inserts decodable EXIF when none exists', () {
      final original = image.encodeJpg(image.Image(width: 2, height: 1));
      final changed = writeOrientation(original, 8)!;
      expect(readOrientation(changed), 8);
      expect(image.decodeJpg(changed), isNotNull);
    });

    test('does not rewrite an existing EXIF block without the tag', () {
      expect(
        writeOrientation(_jpegWithExif(Endian.big, 6, includeTag: false), 3),
        isNull,
      );
    });
  });
}

Uint8List _jpegWithExif(
  Endian endian,
  int orientation, {
  bool includeTag = true,
}) {
  final entryCount = includeTag ? 1 : 0;
  final tiffLength = 8 + 2 + entryCount * 12 + 4;
  final payloadLength = 6 + tiffLength;
  final bytes = Uint8List(2 + 2 + 2 + payloadLength + 2);
  final data = ByteData.sublistView(bytes);
  bytes
    ..[0] = 0xff
    ..[1] = 0xd8
    ..[2] = 0xff
    ..[3] = 0xe1;
  data.setUint16(4, payloadLength + 2, Endian.big);
  bytes.setRange(6, 12, const <int>[0x45, 0x78, 0x69, 0x66, 0, 0]);
  const tiff = 12;
  data
    ..setUint16(tiff, endian == Endian.little ? 0x4949 : 0x4d4d, Endian.big)
    ..setUint16(tiff + 2, 42, endian)
    ..setUint32(tiff + 4, 8, endian)
    ..setUint16(tiff + 8, entryCount, endian);
  if (includeTag) {
    data
      ..setUint16(tiff + 10, 0x0112, endian)
      ..setUint16(tiff + 12, 3, endian)
      ..setUint32(tiff + 14, 1, endian)
      ..setUint16(tiff + 18, orientation, endian);
  }
  data.setUint32(tiff + 10 + entryCount * 12, 0, endian);
  bytes
    ..[bytes.length - 2] = 0xff
    ..[bytes.length - 1] = 0xd9;
  return bytes;
}
