import 'dart:io';
import 'dart:typed_data';

import 'package:toshiba_flashair_wifi_viewer/core/cache_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/card_client.dart';
import 'package:toshiba_flashair_wifi_viewer/core/config_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/file_saver.dart';
import 'package:toshiba_flashair_wifi_viewer/core/metadata/photo_metadata.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update_installer.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update/install_kind.dart';
import 'package:toshiba_flashair_wifi_viewer/core/wifi_manager.dart';
import 'package:toshiba_flashair_wifi_viewer/models/app_config.dart';
import 'package:toshiba_flashair_wifi_viewer/models/update_info.dart';
import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';
import 'package:toshiba_flashair_wifi_viewer/state/update_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('automatic network failures stay silent', () async {
    final fixture = _Fixture();
    fixture.repository.error = UpdateNetworkException(
      const SocketException('offline'),
    );
    await fixture.controller.init();

    await fixture.controller.checkAutomatically();

    expect(fixture.controller.status, UpdateStatus.idle);
    expect(fixture.controller.errorMessage, isNull);
    fixture.dispose();
  });

  test('automatic check does not run while connected to the card', () async {
    final fixture = _Fixture()..state.connection = ConnectionStatus.connected;
    await fixture.controller.init();

    await fixture.controller.checkAutomatically();

    expect(fixture.repository.fetchCalls, 0);
    fixture.dispose();
  });

  test('skipped version is hidden automatically but shown manually', () async {
    final fixture = _Fixture(config: const AppConfig(skippedVersion: '1.1.0'));
    fixture.repository.result = _update;
    await fixture.controller.init();

    await fixture.controller.checkAutomatically();
    expect(fixture.controller.status, UpdateStatus.available);
    expect(fixture.controller.promptPending, isFalse);
    await fixture.controller.checkNow();
    expect(fixture.controller.status, UpdateStatus.available);
    expect(fixture.controller.availableUpdate?.version, '1.1.0');
    fixture.dispose();
  });

  test('startUpdate waits while saving and can cancel the wait', () async {
    final fixture = _Fixture();
    fixture.repository.result = _update;
    await fixture.controller.init();
    await fixture.controller.checkNow();
    fixture.state.saving = true;

    final updating = fixture.controller.startUpdate();
    await Future<void>.delayed(Duration.zero);

    expect(fixture.repository.downloadCalls, 1);
    expect(fixture.controller.status, UpdateStatus.waitingForTasks);
    fixture.controller.cancelUpdate();
    await updating;
    expect(fixture.controller.status, UpdateStatus.available);
    fixture.dispose();
  });

  test('checks after the app changes to disconnected', () async {
    final fixture = _Fixture(disconnectDelay: const Duration(milliseconds: 10))
      ..state.connection = ConnectionStatus.connected;
    await fixture.controller.init();
    fixture.state.connection = ConnectionStatus.disconnected;
    fixture.state.notifyListeners();

    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(fixture.repository.fetchCalls, 1);
    fixture.dispose();
  });
}

const UpdateInfo _update = UpdateInfo(
  version: '1.1.0',
  tag: 'v1.1.0',
  notes: 'Notas',
  pageUrl: 'https://github.com/OWNER/REPO/releases/tag/v1.1.0',
  assetName: 'update.tar.gz',
  assetUrl: 'https://github.com/OWNER/REPO/update.tar.gz',
  assetSize: 10,
  sha256Url: 'https://github.com/OWNER/REPO/update.tar.gz.sha256',
);

class _Fixture {
  _Fixture({
    AppConfig config = const AppConfig(),
    Duration disconnectDelay = const Duration(days: 1),
  }) : configService = _MemoryConfigService(config) {
    state = AppState(
      configService: configService,
      wifiManager: WifiManager(),
      cardClient: CardClient(
        'http://flashair',
        MockClient((_) async => http.Response('', 500)),
      ),
      cacheService: _Cache(),
      fileSaver: _Saver(),
    )..config = config;
    controller = UpdateController(
      appState: state,
      service: repository,
      installer: installer,
      versionLoader: () async => '1.0.0+2',
      initialDelay: const Duration(days: 1),
      disconnectDelay: disconnectDelay,
      repo: 'OWNER/REPO',
    );
  }

  final _MemoryConfigService configService;
  final _Repository repository = _Repository();
  final _Installer installer = _Installer();
  late final AppState state;
  late final UpdateController controller;

  void dispose() {
    controller.dispose();
    state.dispose();
  }
}

class _Repository implements UpdateRepository {
  UpdateInfo? result;
  Object? error;
  int fetchCalls = 0;
  int downloadCalls = 0;

  @override
  Future<UpdateInfo?> fetchLatest(String currentVersion) async {
    fetchCalls++;
    if (error case final value?) throw value;
    return result;
  }

  @override
  Future<File> download(
    UpdateInfo info,
    Directory directory, {
    UpdateProgress? onProgress,
    UpdateCancelToken? cancelToken,
    UpdatePhaseCallback? onVerifying,
  }) async {
    downloadCalls++;
    return File('${directory.path}/update');
  }
}

class _Installer implements UpdateInstallation {
  @override
  Directory get updateDirectory => Directory.systemTemp;
  @override
  Future<InstallDetection> detect() async => (InstallKind.portable, null);
  @override
  Future<String?> consumePreviousLog() async => null;
  @override
  Future<void> openReleasePage(String url) async {}
  @override
  Future<void> install(UpdateInfo info, File archive) async {}
}

class _MemoryConfigService extends ConfigService {
  _MemoryConfigService(this.value);
  AppConfig value;
  @override
  Future<AppConfig> load() async => value;
  @override
  Future<void> save(AppConfig config) async => value = config;
}

class _Cache implements CacheService {
  @override
  int get maxSizeBytes => 0;
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

class _Saver implements FileSaver {
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
