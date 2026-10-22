import 'dart:typed_data';

int? readOrientation(Uint8List jpeg) {
  try {
    return _findExif(jpeg).orientation;
  } catch (_) {
    return null;
  }
}

Uint8List? writeOrientation(Uint8List jpeg, int value) {
  if (value < 1 || value > 8) {
    return null;
  }
  try {
    final result = _findExif(jpeg);
    final valueOffset = result.valueOffset;
    if (valueOffset != null) {
      final copy = Uint8List.fromList(jpeg);
      final data = ByteData.sublistView(copy);
      data.setUint16(valueOffset, value, result.endian!);
      return copy;
    }
    if (result.hasExif) {
      return null;
    }
    if (jpeg.length < 2 || jpeg[0] != 0xff || jpeg[1] != 0xd8) {
      return null;
    }
    final app1 = _minimalExifApp1(value);
    return Uint8List(jpeg.length + app1.length)
      ..setRange(0, 2, jpeg)
      ..setRange(2, 2 + app1.length, app1)
      ..setRange(2 + app1.length, jpeg.length + app1.length, jpeg, 2);
  } catch (_) {
    return null;
  }
}

int composeOrientation(int orientation, int quarterTurnsCW) {
  if (orientation < 1 || orientation > 8) {
    orientation = 1;
  }
  const clockwise = <int, int>{1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2};
  final turns = ((quarterTurnsCW % 4) + 4) % 4;
  var result = orientation;
  for (var i = 0; i < turns; i++) {
    result = clockwise[result]!;
  }
  return result;
}

({int turns, bool flipH}) orientationParts(int orientation) {
  return switch (orientation) {
    2 => (turns: 0, flipH: true),
    3 => (turns: 2, flipH: false),
    4 => (turns: 2, flipH: true),
    5 => (turns: 3, flipH: true),
    6 => (turns: 1, flipH: false),
    7 => (turns: 1, flipH: true),
    8 => (turns: 3, flipH: false),
    _ => (turns: 0, flipH: false),
  };
}

({bool hasExif, int? orientation, int? valueOffset, Endian? endian}) _findExif(
  Uint8List jpeg,
) {
  if (jpeg.length < 2 || jpeg[0] != 0xff || jpeg[1] != 0xd8) {
    return (hasExif: false, orientation: null, valueOffset: null, endian: null);
  }
  var offset = 2;
  while (offset + 4 <= jpeg.length) {
    if (jpeg[offset] != 0xff) {
      break;
    }
    while (offset < jpeg.length && jpeg[offset] == 0xff) {
      offset++;
    }
    if (offset >= jpeg.length) {
      break;
    }
    final marker = jpeg[offset++];
    if (marker == 0xd9 || marker == 0xda) {
      break;
    }
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      continue;
    }
    if (offset + 2 > jpeg.length) {
      break;
    }
    final length = (jpeg[offset] << 8) | jpeg[offset + 1];
    if (length < 2 || offset + length > jpeg.length) {
      break;
    }
    final payload = offset + 2;
    if (marker == 0xe1 &&
        length >= 8 &&
        _matches(jpeg, payload, const <int>[0x45, 0x78, 0x69, 0x66, 0, 0])) {
      final parsed = _parseTiff(jpeg, payload + 6, offset + length);
      return (
        hasExif: true,
        orientation: parsed.orientation,
        valueOffset: parsed.valueOffset,
        endian: parsed.endian,
      );
    }
    offset += length;
  }
  return (hasExif: false, orientation: null, valueOffset: null, endian: null);
}

({int? orientation, int? valueOffset, Endian? endian}) _parseTiff(
  Uint8List bytes,
  int tiff,
  int end,
) {
  if (tiff + 8 > end) {
    return (orientation: null, valueOffset: null, endian: null);
  }
  final byteOrder = (bytes[tiff] << 8) | bytes[tiff + 1];
  final endian = switch (byteOrder) {
    0x4949 => Endian.little,
    0x4d4d => Endian.big,
    _ => null,
  };
  if (endian == null) {
    return (orientation: null, valueOffset: null, endian: null);
  }
  final data = ByteData.sublistView(bytes);
  if (data.getUint16(tiff + 2, endian) != 42) {
    return (orientation: null, valueOffset: null, endian: endian);
  }
  final ifdOffset = data.getUint32(tiff + 4, endian);
  final ifd = tiff + ifdOffset;
  if (ifd < tiff || ifd + 2 > end) {
    return (orientation: null, valueOffset: null, endian: endian);
  }
  final count = data.getUint16(ifd, endian);
  if (ifd + 2 + count * 12 + 4 > end) {
    return (orientation: null, valueOffset: null, endian: endian);
  }
  for (var index = 0; index < count; index++) {
    final entry = ifd + 2 + index * 12;
    if (data.getUint16(entry, endian) != 0x0112 ||
        data.getUint16(entry + 2, endian) != 3 ||
        data.getUint32(entry + 4, endian) < 1) {
      continue;
    }
    final valueOffset = entry + 8;
    final value = data.getUint16(valueOffset, endian);
    if (value < 1 || value > 8) {
      return (orientation: null, valueOffset: null, endian: endian);
    }
    return (orientation: value, valueOffset: valueOffset, endian: endian);
  }
  return (orientation: null, valueOffset: null, endian: endian);
}

bool _matches(Uint8List bytes, int offset, List<int> expected) {
  if (offset + expected.length > bytes.length) {
    return false;
  }
  for (var index = 0; index < expected.length; index++) {
    if (bytes[offset + index] != expected[index]) {
      return false;
    }
  }
  return true;
}

Uint8List _minimalExifApp1(int orientation) {
  final bytes = Uint8List(36);
  final data = ByteData.sublistView(bytes);
  bytes.setRange(0, 10, const <int>[
    0xff,
    0xe1,
    0x00,
    0x22,
    0x45,
    0x78,
    0x69,
    0x66,
    0x00,
    0x00,
  ]);
  const tiff = 10;
  data
    ..setUint16(tiff, 0x4d4d, Endian.big)
    ..setUint16(tiff + 2, 42, Endian.big)
    ..setUint32(tiff + 4, 8, Endian.big)
    ..setUint16(tiff + 8, 1, Endian.big)
    ..setUint16(tiff + 10, 0x0112, Endian.big)
    ..setUint16(tiff + 12, 3, Endian.big)
    ..setUint32(tiff + 14, 1, Endian.big)
    ..setUint16(tiff + 18, orientation, Endian.big)
    ..setUint32(tiff + 22, 0, Endian.big);
  return bytes;
}
