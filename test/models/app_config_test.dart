import 'package:camera_cam/models/app_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('converts to JSON and back without losing values', () {
    final original = AppConfig(
      ssid: 'flashair',
      baseUrl: 'http://flashair.local',
      outputDir: '/home/user/Pictures',
      disconnectOnClose: false,
      deleteEnabled: true,
      sortBy: SortBy.date,
      snackBarSeconds: 42,
      rotateSaveMode: 'pixels',
      autoCheckUpdates: false,
      lastUpdateCheck: DateTime(2026, 10, 22, 12),
      skippedVersion: '1.2.3',
    );

    final restored = AppConfig.fromJson(original.toJson());

    expect(restored.ssid, original.ssid);
    expect(restored.baseUrl, original.baseUrl);
    expect(restored.outputDir, original.outputDir);
    expect(restored.disconnectOnClose, isFalse);
    expect(restored.deleteEnabled, isTrue);
    expect(restored.sortBy, SortBy.date);
    expect(restored.snackBarSeconds, 42);
    expect(restored.rotateSaveMode, 'pixels');
    expect(restored.autoCheckUpdates, isFalse);
    expect(restored.lastUpdateCheck, DateTime(2026, 10, 22, 12));
    expect(restored.skippedVersion, '1.2.3');
  });

  test('uses the default base URL', () {
    expect(const AppConfig().baseUrl, 'http://flashair');
    expect(AppConfig.fromJson(<String, dynamic>{}).baseUrl, 'http://flashair');
    expect(AppConfig.fromJson(<String, dynamic>{}).deleteEnabled, isFalse);
    expect(AppConfig.fromJson(<String, dynamic>{}).disconnectOnClose, isTrue);
    expect(AppConfig.fromJson(<String, dynamic>{}).sortBy, SortBy.name);
    expect(AppConfig.fromJson(<String, dynamic>{}).snackBarSeconds, 15);
    expect(AppConfig.fromJson(<String, dynamic>{}).rotateSaveMode, 'exif');
    expect(AppConfig.fromJson(<String, dynamic>{}).autoCheckUpdates, isTrue);
    expect(AppConfig.fromJson(<String, dynamic>{}).lastUpdateCheck, isNull);
    expect(AppConfig.fromJson(<String, dynamic>{}).skippedVersion, isNull);
    expect(
      AppConfig.fromJson(<String, dynamic>{'rotateSaveMode': 'unknown'})
          .rotateSaveMode,
      'exif',
    );
  });

  test('copyWith updates and clears nullable fields', () {
    const original = AppConfig(ssid: 'flashair', outputDir: '/tmp/photos');

    final updated = original.copyWith(ssid: null, outputDir: null);

    expect(updated.ssid, isNull);
    expect(updated.outputDir, isNull);
    expect(updated.baseUrl, original.baseUrl);
    expect(updated.disconnectOnClose, isTrue);
  });

  test('clamps persisted SnackBar duration to the supported range', () {
    expect(
      AppConfig.fromJson(<String, dynamic>{'snackBarSeconds': 1})
          .snackBarSeconds,
      3,
    );
    expect(
      AppConfig.fromJson(<String, dynamic>{'snackBarSeconds': 90})
          .snackBarSeconds,
      60,
    );
    expect(
      AppConfig.fromJson(<String, dynamic>{'snackBarSeconds': 'invalid'})
          .snackBarSeconds,
      15,
    );
  });
}
