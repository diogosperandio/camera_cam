import 'package:toshiba_flashair_wifi_viewer/core/cache_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/card_client.dart';
import 'package:toshiba_flashair_wifi_viewer/core/config_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/file_saver.dart';
import 'package:toshiba_flashair_wifi_viewer/core/metadata/photo_metadata.dart';
import 'package:toshiba_flashair_wifi_viewer/core/wifi_manager.dart';
import 'package:toshiba_flashair_wifi_viewer/main.dart';
import 'package:toshiba_flashair_wifi_viewer/models/app_config.dart';
import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';
import 'package:toshiba_flashair_wifi_viewer/ui/app_snackbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  testWidgets('shows the configuration empty state without an SSID', (
    tester,
  ) async {
    final state = _createState();

    await tester.pumpWidget(CameraCamApp(appState: state));

    expect(find.text('Selecione uma rede em Configurações'), findsOneWidget);
    expect(find.byTooltip('Configurações'), findsOneWidget);
  });

  testWidgets('toolbar buttons and deletion chip reflect AppState', (
    tester,
  ) async {
    final state = _createState()
      ..config = const AppConfig(ssid: 'FlashAir', deleteEnabled: true)
      ..connection = ConnectionStatus.connected
      ..uploadEnabled = true;

    await tester.pumpWidget(CameraCamApp(appState: state));

    final connectButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Conectar'),
    );
    final disconnectButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Desconectar'),
    );
    final refreshButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Atualizar'),
    );
    expect(connectButton.onPressed, isNull);
    expect(disconnectButton.onPressed, isNotNull);
    expect(refreshButton.onPressed, isNotNull);
    expect(find.text('FlashAir · Conectado'), findsOneWidget);
    expect(find.text('Apagar: liberado'), findsOneWidget);

    state.uploadEnabled = false;
    state.notifyListeners();
    await tester.pump();

    expect(find.text('Apagar: indisponível'), findsOneWidget);
  });

  testWidgets('does not overflow at a narrow desktop size', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = _createState()
      ..config = const AppConfig(ssid: 'FlashAir', deleteEnabled: true)
      ..connection = ConnectionStatus.connected
      ..uploadEnabled = false;

    await tester.pumpWidget(CameraCamApp(appState: state));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Ordenar por:'), findsOneWidget);
    expect(find.text('Selecione um arquivo para visualizar'), findsOneWidget);
  });

  testWidgets('shows state errors in a retryable SnackBar', (tester) async {
    final state = _createState()..config = const AppConfig(snackBarSeconds: 5);
    await tester.pumpWidget(CameraCamApp(appState: state));

    state.errorMessage = 'Falha simulada';
    state.notifyListeners();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Falha simulada'), findsOneWidget);
    expect(find.text('Tentar novamente'), findsOneWidget);
    final snackBar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(snackBar.duration, const Duration(seconds: 5));
    expect(snackBar.persist, isFalse);
    expect(snackBar.showCloseIcon, isTrue);
    expect(snackBar.backgroundColor, appSnackBarBackgroundColor);
    expect(snackBar.closeIconColor, Colors.white);
    expect(snackBar.action?.textColor, Colors.white);
  });

  testWidgets('Ctrl+, opens settings from the main window', (tester) async {
    final state = _createState();
    await tester.pumpWidget(CameraCamApp(appState: state));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('Configurações'), findsOneWidget);
  });

  testWidgets('F5 refreshes the card root while connected', (tester) async {
    var requestCount = 0;
    final state =
        _createState(
            client: MockClient((_) async {
              requestCount++;
              return http.Response('WLANSD_FILELIST\n', 200);
            }),
          )
          ..config = const AppConfig(ssid: 'FlashAir')
          ..connection = ConnectionStatus.connected;
    await tester.pumpWidget(CameraCamApp(appState: state));

    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pump();
    await tester.pump();

    expect(requestCount, 1);
  });
}

AppState _createState({http.Client? client}) {
  return AppState(
    configService: ConfigService(),
    wifiManager: WifiManager(),
    cardClient: CardClient(
      'http://flashair',
      client ?? MockClient((_) async => http.Response('', 500)),
    ),
    cacheService: _TestCacheService(),
    fileSaver: _TestFileSaver(),
  );
}

class _TestFileSaver implements FileSaver {
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

class _TestCacheService implements CacheService {
  @override
  int get maxSizeBytes => 500 * 1024 * 1024;

  @override
  Future<void> clear() async {}

  @override
  Future<Uint8List?> get(String cardPath, {int? fileSize}) async => null;

  @override
  Future<Uint8List?> getThumb(String cardPath, {int? fileSize}) async => null;

  @override
  Future<PhotoMetadata?> getMetadata(
    String cardPath, {
    required int fileSize,
  }) async => null;

  @override
  Future<void> put(String cardPath, Uint8List bytes, {int? fileSize}) async {}

  @override
  Future<void> putThumb(
    String cardPath,
    Uint8List bytes, {
    int? fileSize,
  }) async {}

  @override
  Future<void> putMetadata(
    String cardPath,
    PhotoMetadata metadata, {
    required int fileSize,
  }) async {}

  @override
  Future<void> remove(String cardPath) async {}

  @override
  Future<int> sizeOnDisk() async => 0;
}
