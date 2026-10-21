import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera_cam/core/cache_service.dart';
import 'package:camera_cam/core/card_client.dart';
import 'package:camera_cam/core/config_service.dart';
import 'package:camera_cam/core/file_saver.dart';
import 'package:camera_cam/core/user_prompter.dart';
import 'package:camera_cam/core/wifi_manager.dart';
import 'package:camera_cam/models/app_config.dart';
import 'package:camera_cam/models/card_item.dart';
import 'package:camera_cam/state/app_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('init applies the persisted card URL', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(baseUrl: 'http://192.168.0.1'),
    );

    await dependencies.createState().init();

    expect(dependencies.card.updatedBaseUrls, <String>['http://192.168.0.1']);
  });

  group('connect', () {
    for (final uploadResult in <bool?>[true, false, null]) {
      test('connects and stores uploadEnabled=$uploadResult', () async {
        final dependencies = _Dependencies(
          config: const AppConfig(ssid: 'FlashAir'),
        );
        dependencies.card.uploadResult = uploadResult;
        dependencies.card.directories['/'] = <CardItem>[];
        final state = dependencies.createState();

        await state.init();
        await state.connect();

        expect(state.connection, ConnectionStatus.connected);
        expect(state.uploadEnabled, uploadResult);
        expect(state.tree['/'], isEmpty);
        expect(dependencies.wifi.connectedSsids, <String>['FlashAir']);
        expect(dependencies.prompter.calls, 0);
      });
    }

    test('reports a Wi-Fi failure without pinging the card', () async {
      final dependencies = _Dependencies(
        config: const AppConfig(ssid: 'FlashAir'),
      );
      dependencies.wifi.connectError = const WifiException('perfil ausente');
      final state = dependencies.createState();

      await state.init();
      await state.connect();

      expect(state.connection, ConnectionStatus.error);
      expect(state.errorMessage, contains('Falha ao conectar ao Wi-Fi'));
      expect(dependencies.card.pingCalls, 0);
    });

    test('tries ten pings and reports a distinct card failure', () async {
      var delayCalls = 0;
      final dependencies = _Dependencies(
        config: const AppConfig(ssid: 'FlashAir'),
        delay: (_) async => delayCalls++,
      );
      dependencies.card.pingResult = false;
      final state = dependencies.createState();

      await state.init();
      await state.connect();

      expect(dependencies.card.pingCalls, 10);
      expect(delayCalls, 9);
      expect(state.connection, ConnectionStatus.error);
      expect(state.errorMessage, contains('cartão não respondeu'));
      expect(state.errorMessage, isNot(contains('Falha ao conectar ao Wi-Fi')));
    });

    test('enables a disabled adapter after confirmation', () async {
      final dependencies = _Dependencies(
        config: const AppConfig(ssid: 'FlashAir'),
      );
      dependencies.wifi.state = WifiAdapterState.disabled;
      dependencies.prompter.answer = true;
      dependencies.card.directories['/'] = <CardItem>[];
      final state = dependencies.createState();

      await state.init();
      await state.connect();

      expect(dependencies.prompter.calls, 1);
      expect(dependencies.wifi.enableCalls, 1);
      expect(state.connection, ConnectionStatus.connected);
    });

    test('keeps disconnected when enabling Wi-Fi is declined', () async {
      final dependencies = _Dependencies(
        config: const AppConfig(ssid: 'FlashAir'),
      );
      dependencies.wifi.state = WifiAdapterState.disabled;
      final state = dependencies.createState();

      await state.init();
      await state.connect();

      expect(state.connection, ConnectionStatus.disconnected);
      expect(state.noticeMessage, contains('Conexão cancelada'));
      expect(state.errorMessage, isNull);
      expect(dependencies.wifi.enableCalls, 0);
      expect(dependencies.wifi.connectedSsids, isEmpty);
    });

    test('reports a hardware-blocked adapter without prompting', () async {
      final dependencies = _Dependencies(
        config: const AppConfig(ssid: 'FlashAir'),
      );
      dependencies.wifi.state = WifiAdapterState.blocked;
      final state = dependencies.createState();

      await state.init();
      await state.connect();

      expect(state.connection, ConnectionStatus.error);
      expect(state.errorMessage, contains('bloqueado por hardware'));
      expect(dependencies.prompter.calls, 0);
    });

    test('reports an unavailable adapter', () async {
      final dependencies = _Dependencies(
        config: const AppConfig(ssid: 'FlashAir'),
      );
      dependencies.wifi.state = WifiAdapterState.unavailable;
      final state = dependencies.createState();

      await state.init();
      await state.connect();

      expect(state.connection, ConnectionStatus.error);
      expect(state.errorMessage, contains('não tem adaptador Wi-Fi'));
      expect(dependencies.prompter.calls, 0);
    });

    test('reports failure while enabling the adapter', () async {
      final dependencies = _Dependencies(
        config: const AppConfig(ssid: 'FlashAir'),
      );
      dependencies.wifi.state = WifiAdapterState.disabled;
      dependencies.wifi.enableError = const WifiException('acesso negado');
      dependencies.prompter.answer = true;
      final state = dependencies.createState();

      await state.init();
      await state.connect();

      expect(state.connection, ConnectionStatus.error);
      expect(state.errorMessage, contains('acesso negado'));
      expect(dependencies.wifi.connectedSsids, isEmpty);
    });
  });

  test('a quick selection change ignores the older response', () async {
    final dependencies = _Dependencies();
    final state = dependencies.createState();
    const first = CardItem(
      name: 'FIRST.JPG',
      parentPath: '/DCIM',
      size: 3,
      isDir: false,
    );
    const second = CardItem(
      name: 'SECOND.JPG',
      parentPath: '/DCIM',
      size: 3,
      isDir: false,
    );
    final firstDownload = Completer<Uint8List>();
    final secondDownload = Completer<Uint8List>();
    dependencies.card.downloadCompleters[first.fullPath] = firstDownload;
    dependencies.card.downloadCompleters[second.fullPath] = secondDownload;

    final firstSelection = state.selectFile(first);
    await Future<void>.delayed(Duration.zero);
    final secondSelection = state.selectFile(second);
    await Future<void>.delayed(Duration.zero);
    secondDownload.complete(Uint8List.fromList(<int>[2, 2, 2]));
    await secondSelection;
    firstDownload.complete(Uint8List.fromList(<int>[1, 1, 1]));
    await firstSelection;

    expect(state.selected?.fullPath, second.fullPath);
    expect(state.previewBytes, <int>[2, 2, 2]);
    expect(state.previewIsThumbnail, isFalse);
  });

  test('canDelete reflects every safety condition', () {
    final dependencies = _Dependencies(
      config: const AppConfig(deleteEnabled: true),
    );
    final state = dependencies.createState();
    const file = CardItem(
      name: 'PHOTO.JPG',
      parentPath: '/DCIM',
      size: 3,
      isDir: false,
    );
    const folder = CardItem(
      name: 'FOLDER',
      parentPath: '/DCIM',
      size: 0,
      isDir: true,
    );

    state.config = const AppConfig(deleteEnabled: false);
    state.connection = ConnectionStatus.connected;
    state.uploadEnabled = true;
    state.selected = file;
    expect(state.canDelete, isFalse);

    state.config = const AppConfig(deleteEnabled: true);
    state.uploadEnabled = false;
    expect(state.canDelete, isFalse);
    state.uploadEnabled = null;
    expect(state.canDelete, isFalse);
    state.uploadEnabled = true;
    state.selected = folder;
    expect(state.canDelete, isFalse);
    state.selected = file;
    state.saving = true;
    expect(state.canDelete, isFalse);
    state.saving = false;
    state.deleting = true;
    expect(state.canDelete, isFalse);
    state.deleting = false;
    expect(state.canDelete, isTrue);
  });

  test('canDeleteFolders reflects deletion safety conditions', () {
    final state = _Dependencies().createState()
      ..connection = ConnectionStatus.connected
      ..uploadEnabled = true;

    state.config = const AppConfig(deleteEnabled: false);
    expect(state.canDeleteFolders, isFalse);
    state.config = const AppConfig(deleteEnabled: true);
    state.uploadEnabled = false;
    expect(state.canDeleteFolders, isFalse);
    state.uploadEnabled = null;
    expect(state.canDeleteFolders, isFalse);
    state.uploadEnabled = true;
    expect(state.canDeleteFolders, isTrue);
    state.scanningFolders = true;
    expect(state.canDeleteFolders, isFalse);
  });

  test(
    'scanEmptyFolders finds empty folders with at most two counts',
    () async {
      final dependencies = _Dependencies(
        config: const AppConfig(deleteEnabled: true),
      );
      const folders = <CardItem>[
        CardItem(name: 'A', parentPath: '/DCIM', size: 0, isDir: true),
        CardItem(name: 'B', parentPath: '/DCIM', size: 0, isDir: true),
        CardItem(name: 'C', parentPath: '/DCIM', size: 0, isDir: true),
      ];
      dependencies.card.fileCounts.addAll(<String, int>{
        '/DCIM/A': 0,
        '/DCIM/B': 2,
        '/DCIM/C': 0,
      });
      dependencies.card.countRelease = Completer<void>();
      final state = dependencies.createState()
        ..config = const AppConfig(deleteEnabled: true)
        ..connection = ConnectionStatus.connected
        ..uploadEnabled = true
        ..tree['/DCIM'] = folders;

      final scan = state.scanEmptyFolders();
      await Future<void>.delayed(Duration.zero);
      expect(dependencies.card.maximumCountInFlight, 2);
      dependencies.card.countRelease!.complete();
      final result = await scan;

      expect(result.map((folder) => folder.name), <String>['A', 'C']);
      expect(state.emptyFolders, result);
      expect(state.scanProgress, (done: 3, total: 3));
    },
  );

  test('deleteFolder updates tree, expansion and selection', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(deleteEnabled: true),
    );
    const folder = CardItem(
      name: 'EMPTY',
      parentPath: '/DCIM',
      size: 0,
      isDir: true,
    );
    const selected = CardItem(
      name: 'OLD.JPG',
      parentPath: '/DCIM/EMPTY',
      size: 1,
      isDir: false,
    );
    dependencies.card.directories['/DCIM'] = <CardItem>[folder];
    dependencies.card.fileCounts[folder.fullPath] = 0;
    final state = dependencies.createState()
      ..config = const AppConfig(deleteEnabled: true)
      ..connection = ConnectionStatus.connected
      ..uploadEnabled = true
      ..tree['/DCIM'] = <CardItem>[folder]
      ..tree[folder.fullPath] = <CardItem>[]
      ..expandedPaths.add(folder.fullPath)
      ..selected = selected
      ..previewBytes = Uint8List.fromList(<int>[1]);

    expect(await state.deleteFolder(folder), isTrue);

    expect(state.tree['/DCIM'], isEmpty);
    expect(state.tree.containsKey(folder.fullPath), isFalse);
    expect(state.expandedPaths, isNot(contains(folder.fullPath)));
    expect(state.selected, isNull);
    expect(state.previewBytes, isNull);
  });

  test('deleteFolder reports when the folder is no longer empty', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(deleteEnabled: true),
    );
    const folder = CardItem(
      name: 'CHANGED',
      parentPath: '/DCIM',
      size: 0,
      isDir: true,
    );
    dependencies.card.fileCounts[folder.fullPath] = 2;
    final state = dependencies.createState()
      ..config = const AppConfig(deleteEnabled: true)
      ..connection = ConnectionStatus.connected
      ..uploadEnabled = true;

    expect(await state.deleteFolder(folder), isFalse);

    expect(state.errorMessage, contains('2 arquivos'));
    expect(dependencies.card.deletedFolderPaths, isEmpty);
  });

  test('scanEmptyFolders can be cancelled', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(deleteEnabled: true),
    );
    const folder = CardItem(
      name: 'WAIT',
      parentPath: '/DCIM',
      size: 0,
      isDir: true,
    );
    dependencies.card.countRelease = Completer<void>();
    final state = dependencies.createState()
      ..config = const AppConfig(deleteEnabled: true)
      ..connection = ConnectionStatus.connected
      ..uploadEnabled = true
      ..tree['/DCIM'] = <CardItem>[folder];
    final token = CancelToken();

    final scan = state.scanEmptyFolders(cancel: token);
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    dependencies.card.countRelease!.complete();

    expect(await scan, isEmpty);
    expect(state.scanningFolders, isFalse);
    expect(state.emptyFolders, isEmpty);
  });

  test(
    'deleteEmptyFolders skips non-empty and continues after failure',
    () async {
      final dependencies = _Dependencies(
        config: const AppConfig(deleteEnabled: true),
      );
      const folders = <CardItem>[
        CardItem(name: 'A', parentPath: '/DCIM', size: 0, isDir: true),
        CardItem(name: 'B', parentPath: '/DCIM', size: 0, isDir: true),
        CardItem(name: 'C', parentPath: '/DCIM', size: 0, isDir: true),
      ];
      dependencies.card.directories['/DCIM'] = List<CardItem>.of(folders);
      dependencies.card.fileCounts['/DCIM/A'] = 1;
      dependencies.card.folderDeleteErrors['/DCIM/B'] = CardDeleteException(
        statusCode: 500,
        body: 'ERROR',
      );
      final state = dependencies.createState()
        ..config = const AppConfig(deleteEnabled: true)
        ..connection = ConnectionStatus.connected
        ..uploadEnabled = true
        ..tree['/DCIM'] = List<CardItem>.of(folders);

      final summary = await state.deleteEmptyFolders(folders);

      expect(summary.deleted.map((folder) => folder.name), <String>['C']);
      expect(summary.skipped.map((folder) => folder.name), <String>['A']);
      expect(summary.failures.keys.map((folder) => folder.name), <String>['B']);
      expect(dependencies.card.deletedFolderPaths, <String>['/DCIM/C']);
    },
  );

  test('deleteEmptyFolders stops after a connection loss', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(deleteEnabled: true),
    );
    const folders = <CardItem>[
      CardItem(name: 'A', parentPath: '/DCIM', size: 0, isDir: true),
      CardItem(name: 'B', parentPath: '/DCIM', size: 0, isDir: true),
    ];
    dependencies.card.directories['/DCIM'] = List<CardItem>.of(folders);
    dependencies.card.folderDeleteErrors['/DCIM/A'] = CardUnreachableException(
      Uri.parse('http://flashair/upload.cgi'),
      const SocketException('offline'),
    );
    final state = dependencies.createState()
      ..config = const AppConfig(deleteEnabled: true)
      ..connection = ConnectionStatus.connected
      ..uploadEnabled = true
      ..tree['/DCIM'] = List<CardItem>.of(folders);

    final summary = await state.deleteEmptyFolders(folders);

    expect(summary.failures.keys.single.name, 'A');
    expect(dependencies.card.deletedFolderPaths, isEmpty);
    expect(state.connection, ConnectionStatus.disconnected);
  });

  group('deleteSelected', () {
    test('selects the next file after a successful deletion', () async {
      final scenario = await _deleteScenario(selectedIndex: 0);

      await scenario.state.deleteSelected();

      expect(scenario.state.selected?.name, 'B.JPG');
      expect(scenario.card.deletedPaths, <String>['/DCIM/A.JPG']);
      expect(scenario.cache.removedPaths, contains('/DCIM/A.JPG'));
    });

    test('selects the previous file when deleting the last one', () async {
      final scenario = await _deleteScenario(selectedIndex: 1);

      await scenario.state.deleteSelected();

      expect(scenario.state.selected?.name, 'A.JPG');
    });

    test('keeps selection and list when the card rejects deletion', () async {
      final scenario = await _deleteScenario(selectedIndex: 0);
      scenario.card.deleteError = CardDeleteException(
        statusCode: 500,
        body: 'ERROR',
      );

      await scenario.state.deleteSelected();

      expect(scenario.state.selected?.name, 'A.JPG');
      expect(scenario.state.tree['/DCIM'], hasLength(2));
      expect(
        scenario.state.errorMessage,
        'O cartão recusou apagar. Confirme se UPLOAD=1 está ativo e se a '
        'chave de proteção do cartão não está travada.',
      );
    });

    test('does not delete when save-first is cancelled', () async {
      final scenario = await _deleteScenario(selectedIndex: 0);
      scenario.fileSaver.nextPath = null;

      await scenario.state.deleteSelected(saveCopyFirst: true);

      expect(scenario.card.deletedPaths, isEmpty);
      expect(scenario.state.selected?.name, 'A.JPG');
    });

    test('does not delete when the saved size differs', () async {
      final scenario = await _deleteScenario(selectedIndex: 0);
      scenario.fileSaver.nextPath = '/tmp/A.JPG';
      scenario.fileSaver.fileSizes['/tmp/A.JPG'] = 2;

      await scenario.state.deleteSelected(saveCopyFirst: true);

      expect(scenario.card.deletedPaths, isEmpty);
      expect(scenario.state.errorMessage, contains('tamanho da cópia'));
    });

    test('reports when the file persists after relisting', () async {
      final scenario = await _deleteScenario(selectedIndex: 0);
      scenario.card.keepDeletedFile = true;

      await scenario.state.deleteSelected();

      expect(scenario.state.selected?.name, 'A.JPG');
      expect(scenario.state.errorMessage, 'O cartão não removeu o arquivo.');
    });
  });

  test('loadDir applies the configured sort order', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(sortBy: SortBy.size),
    );
    dependencies.card.directories['/DCIM'] = <CardItem>[
      const CardItem(
        name: 'SMALL.JPG',
        parentPath: '/DCIM',
        size: 1,
        isDir: false,
      ),
      const CardItem(
        name: 'LARGE.JPG',
        parentPath: '/DCIM',
        size: 10,
        isDir: false,
      ),
    ];
    final state = dependencies.createState();
    await state.init();

    await state.loadDir('/DCIM');

    expect(state.tree['/DCIM']!.map((item) => item.name), <String>[
      'LARGE.JPG',
      'SMALL.JPG',
    ]);
  });

  test('collapsing and expanding a loaded folder does not reload it', () async {
    final dependencies = _Dependencies();
    dependencies.card.directories['/DCIM'] = <CardItem>[];
    final state = dependencies.createState();

    await state.toggleFolder('/DCIM');
    await state.toggleFolder('/DCIM');
    await state.toggleFolder('/DCIM');

    expect(dependencies.card.listDirCalls['/DCIM'], 1);
    expect(state.expandedPaths, contains('/DCIM'));
  });

  test('enabling deletion while connected refreshes upload support', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(deleteEnabled: false),
    );
    dependencies.card.uploadResult = true;
    final state = dependencies.createState();
    await state.init();
    state.connection = ConnectionStatus.connected;
    state.uploadEnabled = null;

    await state.updateConfig(state.config.copyWith(deleteEnabled: true));

    expect(state.uploadEnabled, isTrue);
    expect(dependencies.configService.value.deleteEnabled, isTrue);
  });

  test('periodic ping reports a lost card without blocking the app', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(ssid: 'FlashAir'),
      pingInterval: const Duration(milliseconds: 10),
    );
    dependencies.card.directories['/'] = <CardItem>[];
    final state = dependencies.createState();
    await state.init();
    await state.connect();
    dependencies.card.pingResult = false;

    await Future<void>.delayed(const Duration(milliseconds: 35));

    expect(state.connection, ConnectionStatus.disconnected);
    expect(state.errorMessage, contains('conexão com o cartão foi perdida'));
    state.dispose();
  });

  test('periodic ping is skipped while a download is active', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(ssid: 'FlashAir'),
      pingInterval: const Duration(milliseconds: 10),
    );
    dependencies.card.directories['/'] = <CardItem>[];
    final state = dependencies.createState();
    await state.init();
    await state.connect();
    final baselinePings = dependencies.card.pingCalls;
    const item = CardItem(
      name: 'WAIT.JPG',
      parentPath: '/DCIM',
      size: 3,
      isDir: false,
    );
    final download = Completer<Uint8List>();
    dependencies.card.downloadCompleters[item.fullPath] = download;
    final selection = state.selectFile(item);
    await Future<void>.delayed(Duration.zero);
    dependencies.card.pingResult = false;

    await Future<void>.delayed(const Duration(milliseconds: 35));

    expect(state.downloading, isTrue);
    expect(state.connection, ConnectionStatus.connected);
    expect(dependencies.card.pingCalls, baselinePings);

    download.complete(Uint8List.fromList(<int>[1, 2, 3]));
    await selection;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(state.connection, ConnectionStatus.disconnected);
    state.dispose();
  });

  test('periodic ping is skipped while deletion is active', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(ssid: 'FlashAir', deleteEnabled: true),
      pingInterval: const Duration(milliseconds: 10),
    );
    const item = CardItem(
      name: 'DELETE.JPG',
      parentPath: '/DCIM',
      size: 3,
      isDir: false,
    );
    dependencies.card.directories['/'] = <CardItem>[];
    dependencies.card.directories['/DCIM'] = <CardItem>[item];
    final state = dependencies.createState();
    await state.init();
    await state.connect();
    state.tree['/DCIM'] = <CardItem>[item];
    state.selected = item;
    final deleteCompleter = Completer<void>();
    dependencies.card.deleteCompleter = deleteCompleter;
    final baselinePings = dependencies.card.pingCalls;
    final deletion = state.deleteSelected();
    await Future<void>.delayed(Duration.zero);
    dependencies.card.pingResult = false;

    await Future<void>.delayed(const Duration(milliseconds: 35));

    expect(state.deleting, isTrue);
    expect(state.connection, ConnectionStatus.connected);
    expect(dependencies.card.pingCalls, baselinePings);
    deleteCompleter.complete();
    await deletion;
    state.dispose();
  });

  test(
    'reconnect confirms an interrupted deletion before reporting success',
    () async {
      final scenario = await _deleteScenario(selectedIndex: 0);
      scenario.card.deleteError = CardUnreachableException(
        Uri.parse('http://flashair/upload.cgi'),
        const SocketException('offline'),
      );

      final deleted = await scenario.state.deleteSelected();

      expect(deleted, isFalse);
      expect(scenario.state.connection, ConnectionStatus.disconnected);
      scenario.card.deleteError = null;
      scenario.card.directories['/DCIM']!.removeAt(0);
      scenario.card.directories['/'] = <CardItem>[];

      await scenario.state.connect();

      expect(scenario.card.listDirCalls['/DCIM'], 1);
      expect(scenario.state.selected?.name, 'B.JPG');
      expect(scenario.state.noticeMessage, contains('Foto apagada'));
      scenario.state.dispose();
    },
  );

  test('disconnects on close only when the app connected the Wi-Fi', () async {
    final dependencies = _Dependencies(
      config: const AppConfig(ssid: 'FlashAir'),
    );
    dependencies.card.directories['/'] = <CardItem>[];
    final state = dependencies.createState();
    await state.init();
    await state.connect();

    expect(state.connectedByApp, isTrue);
    await state.disconnectOnAppClose();
    expect(dependencies.wifi.disconnectedSsids, <String>['FlashAir']);
    state.dispose();

    final preconnected = _Dependencies(
      config: const AppConfig(ssid: 'FlashAir'),
    );
    preconnected.wifi.connectedSsids.add('FlashAir');
    preconnected.card.directories['/'] = <CardItem>[];
    final preconnectedState = preconnected.createState();
    await preconnectedState.init();
    await preconnectedState.connect();
    expect(preconnectedState.connectedByApp, isFalse);

    await preconnectedState.disconnectOnAppClose();

    expect(preconnected.wifi.disconnectedSsids, isEmpty);
    preconnectedState.dispose();
  });
}

class _Dependencies {
  _Dependencies({
    AppConfig config = const AppConfig(),
    this.delay,
    this.pingInterval = const Duration(seconds: 15),
  }) : configService = _FakeConfigService(config);

  final _FakeConfigService configService;
  final _FakeWifiManager wifi = _FakeWifiManager();
  final _FakeCardClient card = _FakeCardClient();
  final _FakeCacheService cache = _FakeCacheService();
  final _FakeFileSaver fileSaver = _FakeFileSaver();
  final _FakeUserPrompter prompter = _FakeUserPrompter();
  final Future<void> Function(Duration)? delay;
  final Duration pingInterval;

  AppState createState() {
    return AppState(
      configService: configService,
      wifiManager: wifi,
      cardClient: card,
      cacheService: cache,
      fileSaver: fileSaver,
      userPrompter: prompter,
      delay: delay ?? (_) async {},
      pingInterval: pingInterval,
    );
  }
}

class _DeleteScenario {
  const _DeleteScenario({
    required this.state,
    required this.card,
    required this.cache,
    required this.fileSaver,
  });

  final AppState state;
  final _FakeCardClient card;
  final _FakeCacheService cache;
  final _FakeFileSaver fileSaver;
}

Future<_DeleteScenario> _deleteScenario({required int selectedIndex}) async {
  final dependencies = _Dependencies(
    config: const AppConfig(ssid: 'FlashAir', deleteEnabled: true),
  );
  const files = <CardItem>[
    CardItem(name: 'A.JPG', parentPath: '/DCIM', size: 3, isDir: false),
    CardItem(name: 'B.JPG', parentPath: '/DCIM', size: 4, isDir: false),
  ];
  dependencies.card.directories['/DCIM'] = List<CardItem>.of(files);
  dependencies.card.downloadBytes['/DCIM/A.JPG'] = Uint8List.fromList(<int>[
    1,
    2,
    3,
  ]);
  dependencies.card.downloadBytes['/DCIM/B.JPG'] = Uint8List.fromList(<int>[
    1,
    2,
    3,
    4,
  ]);
  final state = dependencies.createState();
  await state.init();
  state.connection = ConnectionStatus.connected;
  state.uploadEnabled = true;
  state.tree['/DCIM'] = List<CardItem>.of(files);
  state.selected = files[selectedIndex];
  state.previewBytes =
      dependencies.card.downloadBytes[files[selectedIndex].fullPath];
  state.previewIsThumbnail = false;

  return _DeleteScenario(
    state: state,
    card: dependencies.card,
    cache: dependencies.cache,
    fileSaver: dependencies.fileSaver,
  );
}

class _FakeConfigService implements ConfigService {
  _FakeConfigService(this.value);

  AppConfig value;

  @override
  Duration get timeout => const Duration(seconds: 5);

  @override
  Future<AppConfig> load() async => value;

  @override
  Future<void> save(AppConfig config) async {
    value = config;
  }
}

class _FakeWifiManager implements WifiManager {
  WifiAdapterState state = WifiAdapterState.enabled;
  Object? connectError;
  Object? enableError;
  int enableCalls = 0;
  final List<String> connectedSsids = <String>[];
  final List<String> disconnectedSsids = <String>[];

  @override
  Future<WifiAdapterState> adapterState() async => state;

  @override
  Future<void> enableAdapter() async {
    enableCalls++;
    if (enableError case final error?) {
      throw error;
    }
    state = WifiAdapterState.enabled;
  }

  @override
  Future<void> connect(String ssid) async {
    if (connectError case final error?) {
      throw error;
    }
    connectedSsids.add(ssid);
  }

  @override
  Future<String?> currentSsid() async => connectedSsids.lastOrNull;

  @override
  Future<void> disconnect(String ssid) async {
    disconnectedSsids.add(ssid);
  }

  @override
  Future<List<String>> listNetworks() async => <String>['FlashAir'];
}

class _FakeUserPrompter implements UserPrompter {
  bool answer = false;
  int calls = 0;

  @override
  Future<bool> confirmEnableWifi() async {
    calls++;
    return answer;
  }
}

class _FakeCardClient implements CardClient {
  bool pingResult = true;
  int pingCalls = 0;
  bool? uploadResult = true;
  Object? deleteError;
  Completer<void>? deleteCompleter;
  bool keepDeletedFile = false;
  final Map<String, List<CardItem>> directories = <String, List<CardItem>>{};
  final Map<String, Uint8List> downloadBytes = <String, Uint8List>{};
  final Map<String, Completer<Uint8List>> downloadCompleters =
      <String, Completer<Uint8List>>{};
  final List<String> deletedPaths = <String>[];
  final Map<String, int> listDirCalls = <String, int>{};
  final List<String> updatedBaseUrls = <String>[];
  final Map<String, int> fileCounts = <String, int>{};
  final Map<String, Object> folderDeleteErrors = <String, Object>{};
  final List<String> deletedFolderPaths = <String>[];
  int countInFlight = 0;
  int maximumCountInFlight = 0;
  Completer<void>? countRelease;

  @override
  Future<int> countFiles(String dir) async {
    countInFlight++;
    maximumCountInFlight = countInFlight > maximumCountInFlight
        ? countInFlight
        : maximumCountInFlight;
    await countRelease?.future;
    countInFlight--;
    return fileCounts[dir] ?? directories[dir]?.length ?? 0;
  }

  @override
  Future<void> deleteEmptyFolder(String path) async {
    if (folderDeleteErrors[path] case final error?) {
      throw error;
    }
    final count = fileCounts[path] ?? directories[path]?.length ?? 0;
    if (count != 0) {
      throw FolderNotEmptyException(path, count);
    }
    deletedFolderPaths.add(path);
    for (final items in directories.values) {
      items.removeWhere((item) => item.fullPath == path);
    }
    directories.remove(path);
  }

  @override
  void updateBaseUrl(String baseUrl) {
    updatedBaseUrls.add(baseUrl);
  }

  @override
  Future<void> deleteFile(String path, {bool writeProtect = true}) async {
    await deleteCompleter?.future;
    if (deleteError case final error?) {
      throw error;
    }
    deletedPaths.add(path);
    if (!keepDeletedFile) {
      for (final entry in directories.entries) {
        entry.value.removeWhere((item) => item.fullPath == path);
      }
    }
  }

  @override
  Future<Uint8List> download(
    String path, {
    DownloadProgress? onProgress,
  }) async {
    final completer = downloadCompleters[path];
    final bytes = completer == null
        ? downloadBytes[path] ?? Uint8List.fromList(<int>[1, 2, 3])
        : await completer.future;
    onProgress?.call(bytes.length, bytes.length);
    return bytes;
  }

  @override
  Future<bool?> isUploadEnabled() async => uploadResult;

  @override
  Future<List<CardItem>> listDir(String path) async {
    listDirCalls.update(path, (count) => count + 1, ifAbsent: () => 1);
    return List<CardItem>.of(directories[path] ?? const <CardItem>[]);
  }

  @override
  Future<bool> ping() async {
    pingCalls++;
    return pingResult;
  }

  @override
  Future<Uint8List?> thumbnail(
    String path, {
    CancellationToken? cancellationToken,
  }) async => null;
}

class _FakeCacheService implements CacheService {
  final Map<String, Uint8List> photos = <String, Uint8List>{};
  final Map<String, Uint8List> thumbs = <String, Uint8List>{};
  final List<String> removedPaths = <String>[];

  @override
  int get maxSizeBytes => 500 * 1024 * 1024;

  @override
  Future<void> clear() async {
    photos.clear();
    thumbs.clear();
  }

  @override
  Future<Uint8List?> get(String cardPath, {int? fileSize}) async {
    return photos[cardPath];
  }

  @override
  Future<Uint8List?> getThumb(String cardPath, {int? fileSize}) async {
    return thumbs[cardPath];
  }

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
    thumbs[cardPath] = bytes;
  }

  @override
  Future<void> remove(String cardPath) async {
    removedPaths.add(cardPath);
    photos.remove(cardPath);
    thumbs.remove(cardPath);
  }

  @override
  Future<int> sizeOnDisk() async {
    return <Uint8List>[
      ...photos.values,
      ...thumbs.values,
    ].fold<int>(0, (sum, bytes) => sum + bytes.length);
  }
}

class _FakeFileSaver implements FileSaver {
  String? nextPath = '/tmp/photo.jpg';
  final Map<String, int> fileSizes = <String, int>{};
  int saveCalls = 0;
  final List<String> openedPaths = <String>[];

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
    saveCalls++;
    final path = nextPath;
    if (path != null) {
      fileSizes.putIfAbsent(path, () => bytes.length);
    }
    return path;
  }

  @override
  Future<int> sizeOf(String filePath) async => fileSizes[filePath]!;
}
