import 'package:toshiba_flashair_wifi_viewer/core/exif_orientation.dart';
import 'package:toshiba_flashair_wifi_viewer/core/image_exporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;

void main() {
  test('bakes orientation and preserves other EXIF metadata', () async {
    final source = image.Image(width: 2, height: 3)
      ..exif.imageIfd.model = 'Nikon Test'
      ..exif.imageIfd[0x0132] = image.IfdValueAscii('2026:10:22 12:00:00')
      ..exif.exifIfd[0x829a] = image.IfdValueRational(1, 125);
    final input = image.encodeJpg(source, quality: 100);

    final output = await const IsolateImageExporter().exportJpeg(input, 6);
    final decoded = image.decodeJpg(output)!;

    expect(decoded.width, 3);
    expect(decoded.height, 2);
    expect(readOrientation(output), 1);
    expect(decoded.exif.imageIfd.model, 'Nikon Test');
    expect(decoded.exif.imageIfd[0x0132]?.toString(), '2026:10:22 12:00:00');
    expect(decoded.exif.exifIfd[0x829a]?.toRational().numerator, 1);
    expect(decoded.exif.exifIfd[0x829a]?.toRational().denominator, 125);
  });
}
