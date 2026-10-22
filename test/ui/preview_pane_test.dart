import 'dart:convert';

import 'package:toshiba_flashair_wifi_viewer/core/cache_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/card_client.dart';
import 'package:toshiba_flashair_wifi_viewer/core/config_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/file_saver.dart';
import 'package:toshiba_flashair_wifi_viewer/core/wifi_manager.dart';
import 'package:toshiba_flashair_wifi_viewer/models/app_config.dart';
import 'package:toshiba_flashair_wifi_viewer/models/card_item.dart';
import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';
import 'package:toshiba_flashair_wifi_viewer/ui/preview_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('shows thumbnail progress and replaces it with the full image', (
    tester,
  ) async {
    final fixture = _Fixture();
    fixture.selectJpeg();
    fixture.state
      ..previewBytes = _imageBytes
      ..previewIsThumbnail = true
      ..previewProgress = 0.5;

    await _pumpPreview(tester, fixture.state);

    expect(find.text('Carregando versão completa'), findsOneWidget);
    final progress = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(progress.value, 0.5);
    expect(find.byType(InteractiveViewer), findsOneWidget);

    fixture.state
      ..previewBytes = Uint8List.fromList(_imageBytes)
      ..previewIsThumbnail = false
      ..previewProgress = 1
      ..notifyListeners();
    await tester.pump();

    expect(find.text('Carregando versão completa'), findsNothing);
  });

  testWidgets('keeps save and delete available for a RAW file', (tester) async {
    final fixture = _Fixture();
    fixture.state.selected = const CardItem(
      name: 'PHOTO.CR3',
      parentPath: '/DCIM',
      size: 2048,
      isDir: false,
    );

    await _pumpPreview(tester, fixture.state);

    expect(
      find.text('Pré-visualização indisponível para este formato'),
      findsOneWidget,
    );
    expect(find.text('Salvar'), findsOneWidget);
    expect(find.text('Apagar'), findsOneWidget);
  });

  testWidgets('cancelling deletion makes no card request', (tester) async {
    final fixture = _Fixture()..selectJpeg();
    await _pumpPreview(tester, fixture.state);

    await tester.tap(find.text('Apagar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.textContaining('Esta ação não pode ser desfeita'),
      findsOneWidget,
    );
    expect(
      find.text('Salvar uma cópia no computador antes de apagar'),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancelar'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(fixture.card.requestLog, isEmpty);
  });

  testWidgets('saves a copy before sending DEL', (tester) async {
    final fixture = _Fixture()..selectJpeg(size: _imageBytes.length);
    fixture.state
      ..previewBytes = _imageBytes
      ..previewIsThumbnail = false;
    await _pumpPreview(tester, fixture.state);

    await tester.tap(find.text('Apagar'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Apagar').last);
    await tester.pumpAndSettle();

    expect(fixture.events, <String>['save', 'delete']);
    expect(fixture.card.deletedPaths, <String>['/DCIM/PHOTO.JPG']);
    expect(find.textContaining('Foto apagada'), findsOneWidget);
    expect(find.textContaining('desligue e ligue a câmera'), findsOneWidget);
  });

  testWidgets('Ctrl+S reports the path and can open its folder', (
    tester,
  ) async {
    final fixture = _Fixture()..selectJpeg(size: _imageBytes.length);
    fixture.state
      ..previewBytes = _imageBytes
      ..previewIsThumbnail = false;
    await _pumpPreview(tester, fixture.state);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('Arquivo salvo em /tmp/PHOTO.JPG'), findsOneWidget);
    await tester.tap(find.text('Abrir pasta'));
    await tester.pump();
    expect(fixture.saver.openedPaths, <String>['/tmp/PHOTO.JPG']);
  });

  test('formats known and missing dates', () {
    expect(formatDate(DateTime(2024, 2, 3, 4, 5, 6)), '03/02/2024 04:05:06');
    expect(formatDate(null), 'Data desconhecida');
  });
}

final Uint8List _imageBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
);

Future<void> _pumpPreview(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: PreviewPane())),
    ),
  );
}

class _Fixture {
  _Fixture() : card = _FakeCardClient(), saver = _FakeFileSaver() {
    card.events = events;
    saver.events = events;
    state =
        AppState(
            configService: _FakeConfigService(),
            wifiManager: _FakeWifiManager(),
            cardClient: card,
            cacheService: _MemoryCacheService(),
            fileSaver: saver,
          )
          ..config = const AppConfig(ssid: 'FlashAir', deleteEnabled: true)
          ..connection = ConnectionStatus.connected
          ..uploadEnabled = true;
  }

  final List<String> events = <String>[];
  final _FakeCardClient card;
  final _FakeFileSaver saver;
  late final AppState state;

  void selectJpeg({int size = 1024}) {
    final item = CardItem(
      name: 'PHOTO.JPG',
      parentPath: '/DCIM',
      size: size,
      isDir: false,
      dateTime: DateTime(2024, 2, 3, 4, 5, 6),
    );
    state.selected = item;
    state.tree['/DCIM'] = <CardItem>[item];
    card.directories['/DCIM'] = <CardItem>[];
  }
}

class _FakeCardClient implements CardClient {
  @override
  Future<int> countFiles(String dir) async => 0;

  @override
  Future<void> deleteEmptyFolder(String path) async {}

  List<String> events = <String>[];
  final List<String> requestLog = <String>[];
  final List<String> deletedPaths = <String>[];
  final Map<String, List<CardItem>> directories = <String, List<CardItem>>{};

  @override
  void updateBaseUrl(String baseUrl) {}

  @override
  Future<void> deleteFile(String path, {bool writeProtect = true}) async {
    requestLog.add('delete');
    events.add('delete');
    deletedPaths.add(path);
  }

  @override
  Future<Uint8List> download(
    String path, {
    DownloadProgress? onProgress,
  }) async {
    requestLog.add('download');
    return _imageBytes;
  }

  @override
  Future<bool?> isUploadEnabled() async => true;

  @override
  Future<List<CardItem>> listDir(String path) async {
    requestLog.add('list');
    return List<CardItem>.of(directories[path] ?? const <CardItem>[]);
  }

  @override
  Future<bool> ping() async => true;

  @override
  Future<Uint8List?> thumbnail(
    String path, {
    CancellationToken? cancellationToken,
  }) async => null;
}

class _FakeFileSaver implements FileSaver {
  List<String> events = <String>[];
  final List<String> openedPaths = <String>[];
  final Map<String, int> sizes = <String, int>{};

  @override
  Future<void> openContainingFolder(String filePath) async {
    openedPaths.add(filePath);
  }

  @override
  Future<String?> save({
    required String suggestedName,
    required Uint8List bytes,
    String? initialDirectory,
  }) async {
    events.add('save');
    final result = '/tmp/$suggestedName';
    sizes[result] = bytes.length;
    return result;
  }

  @override
  Future<int> sizeOf(String filePath) async => sizes[filePath]!;
}

class _MemoryCacheService implements CacheService {
  @override
  int get maxSizeBytes => 500 * 1024 * 1024;

  @override
  Future<void> clear() async {}

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
  Future<int> sizeOnDisk() async => 0;
}

class _FakeConfigService implements ConfigService {
  @override
  Duration get timeout => const Duration(seconds: 1);

  @override
  Future<AppConfig> load() async => const AppConfig();

  @override
  Future<void> save(AppConfig config) async {}
}

class _FakeWifiManager implements WifiManager {
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
  Future<List<String>> listNetworks() async => const <String>[];
}
