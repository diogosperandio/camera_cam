import 'package:camera_cam/core/config_service.dart';
import 'package:camera_cam/models/app_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('returns default configuration when none is saved', () async {
    final config = await ConfigService().load();

    expect(config.ssid, isNull);
    expect(config.baseUrl, 'http://flashair');
    expect(config.outputDir, isNull);
    expect(config.disconnectOnClose, isTrue);
    expect(config.deleteEnabled, isFalse);
  });

  test('saves and loads configuration', () async {
    final service = ConfigService();
    const original = AppConfig(
      ssid: 'flashair',
      baseUrl: 'http://192.168.0.1',
      outputDir: '/tmp/photos',
    );

    await service.save(original);
    final restored = await service.load();

    expect(restored.toJson(), original.toJson());
  });
}
