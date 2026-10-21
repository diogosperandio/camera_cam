import 'package:camera_cam/models/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('converts to JSON and back without losing values', () {
    const original = AppConfig(
      ssid: 'flashair',
      baseUrl: 'http://flashair.local',
      outputDir: '/home/user/Pictures',
      disconnectOnClose: false,
      deleteEnabled: true,
      sortBy: SortBy.date,
    );

    final restored = AppConfig.fromJson(original.toJson());

    expect(restored.ssid, original.ssid);
    expect(restored.baseUrl, original.baseUrl);
    expect(restored.outputDir, original.outputDir);
    expect(restored.disconnectOnClose, isFalse);
    expect(restored.deleteEnabled, isTrue);
    expect(restored.sortBy, SortBy.date);
  });

  test('uses the default base URL', () {
    expect(const AppConfig().baseUrl, 'http://flashair');
    expect(AppConfig.fromJson(<String, dynamic>{}).baseUrl, 'http://flashair');
    expect(AppConfig.fromJson(<String, dynamic>{}).deleteEnabled, isFalse);
    expect(AppConfig.fromJson(<String, dynamic>{}).disconnectOnClose, isTrue);
    expect(AppConfig.fromJson(<String, dynamic>{}).sortBy, SortBy.name);
  });

  test('copyWith updates and clears nullable fields', () {
    const original = AppConfig(ssid: 'flashair', outputDir: '/tmp/photos');

    final updated = original.copyWith(ssid: null, outputDir: null);

    expect(updated.ssid, isNull);
    expect(updated.outputDir, isNull);
    expect(updated.baseUrl, original.baseUrl);
    expect(updated.disconnectOnClose, isTrue);
  });
}
