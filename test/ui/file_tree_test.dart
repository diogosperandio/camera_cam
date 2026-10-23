import 'package:toshiba_flashair_wifi_viewer/core/cache_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/card_client.dart';
import 'package:toshiba_flashair_wifi_viewer/core/config_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/file_saver.dart';
import 'package:toshiba_flashair_wifi_viewer/core/metadata/photo_metadata.dart';
import 'package:toshiba_flashair_wifi_viewer/core/wifi_manager.dart';
import 'package:toshiba_flashair_wifi_viewer/models/app_config.dart';
import 'package:toshiba_flashair_wifi_viewer/models/card_item.dart';
import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';
import 'package:toshiba_flashair_wifi_viewer/ui/file_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('virtualizes a folder with one thousand items', (tester) async {
    final state = _createState(MockClient((_) async => http.Response('', 500)));
    state.tree['/'] = List<CardItem>.generate(
      1000,
      (index) => CardItem(
        name: 'ITEM_${index.toString().padLeft(4, '0')}.CR3',
        parentPath: '/',
        size: index,
        isDir: false,
      ),
    );

    await _pumpTree(tester, state);

    expect(find.text('ITEM_0000.CR3'), findsOneWidget);
    expect(find.text('ITEM_0999.CR3'), findsNothing);
    expect(find.byType(ListView), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('supports Home and End keyboard navigation', (tester) async {
    final state = _createState(MockClient((_) async => http.Response('', 500)));
    state.tree['/'] = List<CardItem>.generate(
      3,
      (index) => CardItem(
        name: 'ITEM_$index.CR3',
        parentPath: '/',
        size: index + 1,
        isDir: false,
      ),
    );
    await _pumpTree(tester, state);

    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(state.selected?.name, 'ITEM_2.CR3');

    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(state.selected?.name, 'ITEM_0.CR3');
  });

  testWidgets('shows loaded file count and an inline folder error', (
    tester,
  ) async {
    final state = _createState(MockClient((_) async => http.Response('', 500)));
    const folder = CardItem(
      name: 'DCIM',
      parentPath: '/',
      size: 0,
      isDir: true,
    );
    state.tree['/'] = <CardItem>[folder];
    state.tree['/DCIM'] = const <CardItem>[
      CardItem(name: 'A.JPG', parentPath: '/DCIM', size: 10, isDir: false),
      CardItem(name: 'B.JPG', parentPath: '/DCIM', size: 20, isDir: false),
    ];
    state.expandedPaths.add('/DCIM');
    state.folderErrors['/DCIM'] = 'Falha simulada';

    await _pumpTree(tester, state);

    expect(find.text('2 arquivos'), findsOneWidget);
    expect(find.text('Falha simulada'), findsOneWidget);
    expect(find.text('Recarregar'), findsOneWidget);
  });

  testWidgets('labels a loaded empty folder as empty', (tester) async {
    final state = _createState(MockClient((_) async => http.Response('', 500)));
    const folder = CardItem(
      name: 'EMPTY',
      parentPath: '/DCIM',
      size: 0,
      isDir: true,
    );
    state.tree['/'] = const <CardItem>[
      CardItem(name: 'DCIM', parentPath: '/', size: 0, isDir: true),
    ];
    state.tree['/DCIM'] = <CardItem>[folder];
    state.tree[folder.fullPath] = <CardItem>[];
    state.expandedPaths.add('/DCIM');

    await _pumpTree(tester, state);

    expect(find.text('EMPTY'), findsOneWidget);
    expect(find.text('vazia'), findsOneWidget);
  });

  testWidgets('shows folder delete only for loaded empty folders', (
    tester,
  ) async {
    final state = _createState(MockClient((_) async => http.Response('', 500)))
      ..config = const AppConfig(ssid: 'FlashAir', deleteEnabled: true)
      ..uploadEnabled = true;
    const empty = CardItem(
      name: 'EMPTY',
      parentPath: '/DCIM',
      size: 0,
      isDir: true,
    );
    const full = CardItem(
      name: 'FULL',
      parentPath: '/DCIM',
      size: 0,
      isDir: true,
    );
    const unloaded = CardItem(
      name: 'UNLOADED',
      parentPath: '/DCIM',
      size: 0,
      isDir: true,
    );
    state.tree['/'] = const <CardItem>[
      CardItem(name: 'DCIM', parentPath: '/', size: 0, isDir: true),
    ];
    state.tree['/DCIM'] = const <CardItem>[empty, full, unloaded];
    state.tree[empty.fullPath] = <CardItem>[];
    state.tree[full.fullPath] = const <CardItem>[
      CardItem(
        name: 'PHOTO.JPG',
        parentPath: '/DCIM/FULL',
        size: 1,
        isDir: false,
      ),
    ];
    state.expandedPaths.add('/DCIM');

    await _pumpTree(tester, state);

    expect(find.byTooltip('Apagar pasta vazia'), findsOneWidget);
  });

  testWidgets('confirms and deletes a loaded empty folder', (tester) async {
    final urls = <String>[];
    final state = _createState(
      MockClient((request) async {
        urls.add(request.url.toString());
        if (request.url.queryParameters['op'] == '100') {
          return http.Response('WLANSD_FILELIST\n', 200);
        }
        if (request.url.queryParameters['op'] == '101') {
          return http.Response('0', 200);
        }
        return http.Response('SUCCESS', 200);
      }),
    );
    const folder = CardItem(
      name: 'EMPTY',
      parentPath: '/DCIM',
      size: 0,
      isDir: true,
    );
    state.config = const AppConfig(ssid: 'FlashAir', deleteEnabled: true);
    state.uploadEnabled = true;
    state.tree['/'] = const <CardItem>[
      CardItem(name: 'DCIM', parentPath: '/', size: 0, isDir: true),
    ];
    state.tree['/DCIM'] = <CardItem>[folder];
    state.tree[folder.fullPath] = <CardItem>[];
    state.expandedPaths.add('/DCIM');

    await _pumpTree(tester, state);
    await tester.tap(find.byTooltip('Apagar pasta vazia'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Apagar a pasta vazia EMPTY'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Apagar'));
    await tester.pumpAndSettle();

    expect(urls.any((url) => url.contains('DEL=/DCIM/EMPTY')), isTrue);
    expect(state.tree['/DCIM'], isEmpty);
  });

  testWidgets('fast scrolling cancels debounced off-screen thumbnails', (
    tester,
  ) async {
    var requestCount = 0;
    final state = _createState(
      MockClient((_) async {
        requestCount++;
        return http.Response.bytes(<int>[0xFF, 0xD8, 0xFF, 0xD9], 200);
      }),
    );
    state.tree['/'] = List<CardItem>.generate(
      1000,
      (index) => CardItem(
        name: 'IMG_${index.toString().padLeft(4, '0')}.JPG',
        parentPath: '/',
        size: index + 100,
        isDir: false,
      ),
    );
    await _pumpTree(tester, state);

    await tester.drag(
      find.byKey(const Key('file-tree-list')),
      const Offset(0, -10000),
    );
    await tester.pump(const Duration(milliseconds: 149));
    expect(requestCount, 0);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(requestCount, greaterThan(0));
    expect(requestCount, lessThan(30));
  });

  test('formats file sizes', () {
    expect(formatFileSize(512), '512 B');
    expect(formatFileSize(1536), '1.5 KB');
    expect(formatFileSize(2 * 1024 * 1024), '2.0 MB');
  });
}

AppState _createState(http.Client client) {
  return AppState(
      configService: ConfigService(),
      wifiManager: WifiManager(),
      cardClient: CardClient('http://flashair', client),
      cacheService: _MemoryCacheService(),
      fileSaver: _NoOpFileSaver(),
    )
    ..config = const AppConfig(ssid: 'FlashAir')
    ..connection = ConnectionStatus.connected;
}

Future<void> _pumpTree(WidgetTester tester, AppState state) async {
  await tester.binding.setSurfaceSize(const Size(360, 520));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const MaterialApp(home: Scaffold(body: FileTree())),
    ),
  );
}

class _MemoryCacheService implements CacheService {
  final Map<String, Uint8List> photos = <String, Uint8List>{};
  final Map<String, Uint8List> thumbnails = <String, Uint8List>{};

  @override
  int get maxSizeBytes => 500 * 1024 * 1024;

  @override
  Future<void> clear() async {
    photos.clear();
    thumbnails.clear();
  }

  @override
  Future<Uint8List?> get(String cardPath, {int? fileSize}) async {
    return photos[cardPath];
  }

  @override
  Future<Uint8List?> getThumb(String cardPath, {int? fileSize}) async {
    return thumbnails[cardPath];
  }

  @override
  Future<PhotoMetadata?> getMetadata(
    String cardPath, {
    required int fileSize,
  }) async => null;

  @override
  Future<void> put(String cardPath, Uint8List bytes, {int? fileSize}) async {
    photos[cardPath] = bytes;
  }

  @override
  Future<void> putThumb(
    String cardPath,
    Uint8List bytes, {
    int? fileSize,
  }) async {
    thumbnails[cardPath] = bytes;
  }

  @override
  Future<void> putMetadata(
    String cardPath,
    PhotoMetadata metadata, {
    required int fileSize,
  }) async {}

  @override
  Future<void> remove(String cardPath) async {
    photos.remove(cardPath);
    thumbnails.remove(cardPath);
  }

  @override
  Future<int> sizeOnDisk() async => 0;
}

class _NoOpFileSaver implements FileSaver {
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
