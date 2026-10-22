import 'dart:typed_data';

import 'package:toshiba_flashair_wifi_viewer/core/cache_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/card_client.dart';
import 'package:toshiba_flashair_wifi_viewer/core/config_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/file_saver.dart';
import 'package:toshiba_flashair_wifi_viewer/core/wifi_manager.dart';
import 'package:toshiba_flashair_wifi_viewer/models/app_config.dart';
import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';
import 'package:toshiba_flashair_wifi_viewer/ui/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('does not save an invalid base URL', (tester) async {
    final fixture = _Fixture();
    await _pumpDialog(tester, fixture.state);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'URL base do cartão'),
      'flashair sem esquema',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Salvar'));
    await tester.pump();

    expect(find.textContaining('Informe uma URL HTTP válida'), findsOneWidget);
    expect(fixture.configService.saveCalls, 0);
    expect(fixture.state.config.baseUrl, 'http://flashair');
  });

  testWidgets('saves the settings and keeps deletion disabled by default', (
    tester,
  ) async {
    final fixture = _Fixture();
    await _pumpDialog(tester, fixture.state);

    final deleteSwitch = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Permitir apagar fotos do cartão'),
    );
    expect(deleteSwitch.value, isFalse);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'SSID manual'),
      'flashair-camera',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'URL base do cartão'),
      'http://192.168.0.1',
    );
    await tester.tap(
      find.widgetWithText(SwitchListTile, 'Desconectar ao fechar o app'),
    );
    final sliderFinder = find.byType(Slider);
    await tester.ensureVisible(sliderFinder);
    tester.widget<Slider>(sliderFinder).onChanged?.call(5);
    await tester.pump();
    expect(fixture.state.config.snackBarSeconds, 5);
    await tester.tap(find.widgetWithText(FilledButton, 'Salvar'));
    await tester.pumpAndSettle();

    expect(fixture.configService.saved?.ssid, 'flashair-camera');
    expect(fixture.configService.saved?.baseUrl, 'http://192.168.0.1');
    expect(fixture.configService.saved?.disconnectOnClose, isFalse);
    expect(fixture.configService.saved?.deleteEnabled, isFalse);
    expect(fixture.configService.saved?.snackBarSeconds, 5);
  });

  testWidgets('requires confirmation before enabling deletion', (tester) async {
    final fixture = _Fixture();
    await _pumpDialog(tester, fixture.state);
    final switchFinder = find.widgetWithText(
      SwitchListTile,
      'Permitir apagar fotos do cartão',
    );

    await tester.ensureVisible(switchFinder);
    await tester.pump();
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(find.text('Permitir exclusão?'), findsOneWidget);
    await tester.tap(find.text('Cancelar').last);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

    await tester.ensureVisible(switchFinder);
    await tester.pump();
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Entendo, permitir'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
  });

  testWidgets('searches networks, verifies upload and clears the cache', (
    tester,
  ) async {
    final fixture = _Fixture();
    fixture.state.connection = ConnectionStatus.connected;
    await _pumpDialog(tester, fixture.state);
    await tester.pump();

    expect(find.text('Cache: 2.0 KB'), findsOneWidget);
    await tester.tap(find.text('Buscar redes'));
    await tester.pump();
    expect(fixture.wifi.listCalls, 1);

    final verifyFinder = find.text('Verificar suporte');
    await tester.ensureVisible(verifyFinder);
    await tester.pump();
    await tester.tap(verifyFinder);
    await tester.pump();
    expect(find.text('Disponível'), findsOneWidget);

    final clearFinder = find.text('Limpar cache');
    await tester.ensureVisible(clearFinder);
    await tester.pump();
    await tester.tap(clearFinder);
    await tester.pump();
    expect(fixture.cache.clearCalls, 1);
    expect(find.text('Cache: 0 B'), findsOneWidget);
  });
}

Future<void> _pumpDialog(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: SettingsDialog())),
    ),
  );
  await tester.pump();
}

class _Fixture {
  _Fixture()
    : configService = _FakeConfigService(),
      wifi = _FakeWifiManager(),
      cache = _FakeCacheService() {
    state = AppState(
      configService: configService,
      wifiManager: wifi,
      cardClient: CardClient(
        'http://flashair',
        MockClient((request) async {
          if (request.url.queryParameters['op'] == '118') {
            return http.Response('1', 200);
          }
          return http.Response('', 500);
        }),
      ),
      cacheService: cache,
      fileSaver: _FakeFileSaver(),
    );
  }

  final _FakeConfigService configService;
  final _FakeWifiManager wifi;
  final _FakeCacheService cache;
  late final AppState state;
}

class _FakeConfigService implements ConfigService {
  AppConfig? saved;
  int saveCalls = 0;

  @override
  Duration get timeout => const Duration(seconds: 1);

  @override
  Future<AppConfig> load() async => const AppConfig();

  @override
  Future<void> save(AppConfig config) async {
    saveCalls++;
    saved = config;
  }
}

class _FakeWifiManager implements WifiManager {
  int listCalls = 0;

  @override
  Future<WifiAdapterState> adapterState() async => WifiAdapterState.enabled;

  @override
  Future<void> enableAdapter() async {}

  @override
  Future<void> connect(String ssid) async {}

  @override
  Future<String?> currentSsid() async => null;

  @override
  Future<void> disconnect(String ssid) async {}

  @override
  Future<List<String>> listNetworks() async {
    listCalls++;
    return <String>['FlashAir', 'Camera WiFi'];
  }
}

class _FakeCacheService implements CacheService {
  int clearCalls = 0;
  int size = 2048;

  @override
  int get maxSizeBytes => 500 * 1024 * 1024;

  @override
  Future<void> clear() async {
    clearCalls++;
    size = 0;
  }

  @override
  Future<Uint8List?> get(String cardPath, {int? fileSize}) async => null;

  @override
  Future<Uint8List?> getThumb(String cardPath, {int? fileSize}) async => null;

  @override
  Future<void> put(String cardPath, Uint8List bytes, {int? fileSize}) async {}

  @override
  Future<void> putThumb(
    String cardPath,
    Uint8List bytes, {
    int? fileSize,
  }) async {}

  @override
  Future<void> remove(String cardPath) async {}

  @override
  Future<int> sizeOnDisk() async => size;
}

class _FakeFileSaver implements FileSaver {
  @override
  Future<void> openContainingFolder(String filePath) async {}

  @override
  Future<String?> save({
    required String suggestedName,
    required Uint8List bytes,
    String? initialDirectory,
  }) async => null;

  @override
  Future<int> sizeOf(String filePath) async => 0;
}
