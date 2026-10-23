import 'package:flutter_test/flutter_test.dart';
import 'package:toshiba_flashair_wifi_viewer/core/metadata/metadata_format.dart';

void main() {
  test('formats exposure, aperture, compensation and focal length in pt-BR', () {
    expect(formatExposure(0.004), '1/250 s');
    expect(formatExposure(0.5), '1/2 s');
    expect(formatExposure(2), '2 s');
    expect(formatAperture(5.6), 'f/5,6');
    expect(formatExposureBias(0.3), '+0,3 EV');
    expect(formatExposureBias(-1), '−1,0 EV');
    expect(formatExposureBias(0), '0 EV');
    expect(
      formatFocalLength(10, equivalent35mm: 27),
      '10 mm (27 mm equiv.)',
    );
    expect(
      formatFocalLength(10, model: 'NIKON 1 J1'),
      '10 mm (27 mm equiv. aprox.)',
    );
  });

  test('formats dimensions, orientation, GPS and dates', () {
    expect(formatDimensions(3872, 2592), '3872 × 2592 (10,0 MP)');
    expect(
      formatOrientation(6, manualQuarterTurns: 1),
      'Girada 90° à direita · girada no app: 90° à direita',
    );
    expect(formatGps(-23.55052, -46.63331), '-23,5505, -46,6333');
    expect(
      formatDateTime(DateTime(2019, 2, 18, 9, 15, 36)),
      '18/02/2019 09:15:36',
    );
  });

  test('detects an implausible camera clock', () {
    final now = DateTime(2026, 10, 23, 12);
    expect(
      hasSuspiciousCameraClock(DateTime(2010, 12, 31), now: now),
      isTrue,
    );
    expect(
      hasSuspiciousCameraClock(DateTime(2026, 10, 24), now: now),
      isTrue,
    );
    expect(
      hasSuspiciousCameraClock(DateTime(2019, 2, 18), now: now),
      isFalse,
    );
  });
}
