import 'dart:async';

import 'package:camera_cam/core/cache_service.dart';
import 'package:camera_cam/core/card_client.dart';
import 'package:camera_cam/core/config_service.dart';
import 'package:camera_cam/core/file_saver.dart';
import 'package:camera_cam/core/exif_orientation.dart';
import 'package:camera_cam/core/image_exporter.dart';
import 'package:camera_cam/core/user_prompter.dart';
import 'package:camera_cam/core/wifi_manager.dart';
import 'package:camera_cam/models/app_config.dart';
import 'package:camera_cam/models/card_item.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

final Logger _stateLog = Logger('AppState');

enum ConnectionStatus { disconnected, connecting, connected, error }

class AppState extends ChangeNotifier {
  AppState({
    required this.configService,
    required this.wifiManager,
    required this.cardClient,
    required this.cacheService,
    required this.fileSaver,
    ImageExporter? imageExporter,
    UserPrompter? userPrompter,
    Future<void> Function(Duration)? delay,
    this.pingInterval = const Duration(seconds: 15),
  }) : imageExporter = imageExporter ?? const IsolateImageExporter(),
       userPrompter = userPrompter ?? const _DecliningUserPrompter(),
       _delay = delay ?? Future<void>.delayed;

  final ConfigService configService;
  final WifiManager wifiManager;
  final CardClient cardClient;
  final CacheService cacheService;
  final FileSaver fileSaver;
  final ImageExporter imageExporter;
  final UserPrompter userPrompter;
  final Future<void> Function(Duration) _delay;
  final Duration pingInterval;

  AppConfig config = const AppConfig();
  ConnectionStatus connection = ConnectionStatus.disconnected;
  String? errorMessage;
  String? noticeMessage;
  final Map<String, List<CardItem>> tree = <String, List<CardItem>>{};
  final Set<String> expandedPaths = <String>{};
  final Set<String> loadingPaths = <String>{};
  final Map<String, String> folderErrors = <String, String>{};
  CardItem? selected;
  Uint8List? previewBytes;
  Uint8List? originalBytes;
  Uint8List? displayBytes;
  int baseOrientation = 1;
  bool previewIsThumbnail = false;
  double? previewProgress;
  bool saving = false;
  bool deleting = false;
  bool scanningFolders = false;
  ({int done, int total}) scanProgress = (done: 0, total: 0);
  List<CardItem> emptyFolders = <CardItem>[];
  bool deletingFolders = false;
  bool? uploadEnabled;
  final Map<String, int> rotations = <String, int>{};
  final Map<String, ({String localPath, int size, bool rotated})>
  savedThisSession = <String, ({String localPath, int size, bool rotated})>{};
  String? lastSaveRotationMode;

  final Map<String, int> _loadGenerations = <String, int>{};
  int _previewGeneration = 0;
  int _connectionGeneration = 0;
  int _activeDownloads = 0;
  bool _pingInProgress = false;
  bool _connectedByApp = false;
  Timer? _pingTimer;
  _PendingDeletion? _pendingDeletion;
  CancellationToken? _thumbnailCancellationToken;

  bool get downloading => _activeDownloads > 0;
  bool get connectedByApp => _connectedByApp;

  int get manualQuarterTurns => rotations[selected?.fullPath] ?? 0;

  int get effectiveOrientation => composeOrientation(
    previewIsThumbnail ? 1 : baseOrientation,
    manualQuarterTurns,
  );

  bool get canRotate =>
      selected?.isJpeg == true && originalBytes != null && !previewIsThumbnail;

  bool get canDelete {
    final item = selected;
    return config.deleteEnabled &&
        uploadEnabled == true &&
        connection == ConnectionStatus.connected &&
        item != null &&
        !item.isDir &&
        !saving &&
        !deleting &&
        !scanningFolders &&
        !deletingFolders;
  }

  bool get canDeleteFolders {
    return config.deleteEnabled &&
        uploadEnabled == true &&
        connection == ConnectionStatus.connected &&
        !saving &&
        !deleting &&
        !scanningFolders &&
        !deletingFolders;
  }

  Future<void> init() async {
    try {
      config = await configService.load();
      cardClient.updateBaseUrl(config.baseUrl);
      errorMessage = null;
    } catch (error) {
      errorMessage =
          'Não foi possível carregar as configurações: '
          '${_errorText(error)}';
    }
    notifyListeners();
  }

  Future<void> connect() async {
    final ssid = config.ssid?.trim();
    if (ssid == null || ssid.isEmpty) {
      connection = ConnectionStatus.error;
      errorMessage = 'Selecione uma rede Wi-Fi nas configurações.';
      notifyListeners();
      return;
    }

    final generation = ++_connectionGeneration;
    _stopPingMonitor();
    connection = ConnectionStatus.connecting;
    errorMessage = null;
    noticeMessage = null;
    uploadEnabled = null;
    notifyListeners();

    if (!await _ensureWifiReady(requiredSsid: ssid)) {
      return;
    }

    var currentSsidKnown = false;
    var wasAlreadyConnected = false;
    try {
      wasAlreadyConnected = await wifiManager.currentSsid() == ssid;
      currentSsidKnown = true;
    } catch (_) {
      // A detecção de propriedade é conservadora: sem confirmação, o app não
      // desconectará automaticamente uma rede que pode ter sido ligada fora dele.
    }

    try {
      await wifiManager.connect(ssid);
      _connectedByApp = currentSsidKnown && !wasAlreadyConnected;
    } catch (error) {
      if (generation != _connectionGeneration) {
        return;
      }
      connection = ConnectionStatus.error;
      errorMessage = 'Falha ao conectar ao Wi-Fi: ${_errorText(error)}';
      notifyListeners();
      return;
    }

    var cardReached = false;
    for (var attempt = 0; attempt < 10; attempt++) {
      if (generation != _connectionGeneration) {
        return;
      }
      try {
        cardReached = await cardClient.ping();
      } catch (_) {
        cardReached = false;
      }
      if (cardReached) {
        break;
      }
      if (attempt < 9) {
        await _delay(const Duration(seconds: 1));
      }
    }

    if (generation != _connectionGeneration) {
      return;
    }
    if (!cardReached) {
      connection = ConnectionStatus.error;
      errorMessage =
          'A rede Wi-Fi foi conectada, mas o cartão não respondeu. '
          'Verifique se a câmera está ligada.';
      notifyListeners();
      return;
    }

    connection = ConnectionStatus.connected;
    try {
      uploadEnabled = await cardClient.isUploadEnabled();
    } catch (_) {
      uploadEnabled = null;
    }
    if (generation != _connectionGeneration) {
      return;
    }
    notifyListeners();
    await _resolvePendingDeletion();
    if (generation != _connectionGeneration) {
      return;
    }
    await loadDir('/', force: true);
    if (generation != _connectionGeneration) {
      return;
    }
    _startPingMonitor();
  }

  Future<void> disconnect() async {
    ++_connectionGeneration;
    _stopPingMonitor();
    _invalidatePreview();
    final ssid = config.ssid?.trim();
    _clearCardState();
    connection = ConnectionStatus.disconnected;
    errorMessage = null;
    noticeMessage = null;
    notifyListeners();

    if (ssid == null || ssid.isEmpty) {
      return;
    }
    try {
      await wifiManager.disconnect(ssid);
      _connectedByApp = false;
    } catch (error) {
      connection = ConnectionStatus.error;
      errorMessage = 'Falha ao desconectar do Wi-Fi: ${_errorText(error)}';
      notifyListeners();
    }
  }

  Future<void> disconnectOnAppClose() async {
    if (!config.disconnectOnClose || !_connectedByApp) {
      return;
    }
    await disconnect();
  }

  Future<bool> loadDir(String path, {bool force = false}) async {
    if (!force && (tree.containsKey(path) || loadingPaths.contains(path))) {
      return true;
    }

    final generation = (_loadGenerations[path] ?? 0) + 1;
    _loadGenerations[path] = generation;
    loadingPaths.add(path);
    folderErrors.remove(path);
    notifyListeners();

    try {
      final items = await cardClient.listDir(path);
      if (_loadGenerations[path] == generation) {
        tree[path] = _sortItems(items);
      }
      return true;
    } catch (error) {
      if (_loadGenerations[path] == generation) {
        folderErrors[path] = _errorText(error);
      }
      return false;
    } finally {
      if (_loadGenerations[path] == generation) {
        loadingPaths.remove(path);
        notifyListeners();
      }
    }
  }

  Future<void> toggleFolder(String path) async {
    if (expandedPaths.remove(path)) {
      notifyListeners();
      return;
    }
    expandedPaths.add(path);
    notifyListeners();
    await loadDir(path);
  }

  Future<void> selectFile(CardItem item) async {
    if (item.isDir) {
      return;
    }

    _thumbnailCancellationToken?.cancel();
    final cancellationToken = CancellationToken();
    _thumbnailCancellationToken = cancellationToken;
    final generation = ++_previewGeneration;
    selected = item;
    previewBytes = null;
    originalBytes = null;
    displayBytes = null;
    baseOrientation = 1;
    previewIsThumbnail = false;
    previewProgress = 0;
    errorMessage = null;
    notifyListeners();

    try {
      var thumbnail = await cacheService.getThumb(
        item.fullPath,
        fileSize: item.size,
      );
      thumbnail ??= await cardClient.thumbnail(
        item.fullPath,
        cancellationToken: cancellationToken,
      );
      if (thumbnail != null) {
        await cacheService.putThumb(
          item.fullPath,
          thumbnail,
          fileSize: item.size,
        );
        if (_isCurrentPreview(generation, item)) {
          previewBytes = thumbnail;
          displayBytes = thumbnail;
          previewIsThumbnail = true;
          notifyListeners();
        }
      }
    } catch (_) {
      // A miniatura é apenas provisória; a foto completa ainda pode funcionar.
    }

    try {
      var photo = await cacheService.get(item.fullPath, fileSize: item.size);
      if (photo == null) {
        photo = await _download(
          item.fullPath,
          onProgress: (receivedBytes, totalBytes) {
            if (!_isCurrentPreview(generation, item)) {
              return;
            }
            previewProgress = totalBytes == null || totalBytes == 0
                ? null
                : receivedBytes / totalBytes;
            notifyListeners();
          },
        );
        await cacheService.put(item.fullPath, photo, fileSize: item.size);
      }
      if (_isCurrentPreview(generation, item)) {
        originalBytes = photo;
        baseOrientation = readOrientation(photo) ?? 1;
        displayBytes = baseOrientation == 1
            ? photo
            : writeOrientation(photo, 1) ?? photo;
        previewBytes = displayBytes;
        previewIsThumbnail = false;
        previewProgress = 1;
        _logOrientation(item.fullPath, mode: 'visualização');
        notifyListeners();
      }
    } catch (error) {
      if (_isCurrentPreview(generation, item)) {
        errorMessage =
            'Não foi possível carregar o arquivo: '
            '${_errorText(error)}';
        previewProgress = null;
        notifyListeners();
      }
    }
  }

  Future<Uint8List?> loadThumbnail(
    CardItem item, {
    CancellationToken? cancellationToken,
  }) async {
    if (!item.isImage || (cancellationToken?.isCancelled ?? false)) {
      return null;
    }

    final cached = await cacheService.getThumb(
      item.fullPath,
      fileSize: item.size,
    );
    if (cached != null || (cancellationToken?.isCancelled ?? false)) {
      return cached;
    }

    final thumbnail = await cardClient.thumbnail(
      item.fullPath,
      cancellationToken: cancellationToken,
    );
    if (thumbnail != null) {
      await cacheService.putThumb(
        item.fullPath,
        thumbnail,
        fileSize: item.size,
      );
    }
    return cancellationToken?.isCancelled ?? false ? null : thumbnail;
  }

  Future<List<String>> listWifiNetworks() async {
    if (!await _ensureWifiReady()) {
      return const <String>[];
    }
    try {
      final networks = await wifiManager.listNetworks();
      errorMessage = null;
      notifyListeners();
      return networks;
    } catch (error) {
      errorMessage =
          'Não foi possível buscar redes Wi-Fi: ${_errorText(error)}';
      notifyListeners();
      return const <String>[];
    }
  }

  Future<bool> _ensureWifiReady({String? requiredSsid}) async {
    WifiAdapterState state;
    try {
      state = await wifiManager.adapterState();
      _stateLog.info('Estado do adaptador Wi-Fi recebido: ${state.name}');
    } catch (error) {
      _stateLog.warning('Falha ao consultar o adaptador Wi-Fi.', error);
      connection = requiredSsid == null ? connection : ConnectionStatus.error;
      errorMessage =
          'Não foi possível verificar o estado do adaptador Wi-Fi: '
          '${_errorText(error)}';
      notifyListeners();
      return false;
    }

    switch (state) {
      case WifiAdapterState.enabled:
      case WifiAdapterState.unknown:
        return true;
      case WifiAdapterState.unavailable:
        connection = requiredSsid == null ? connection : ConnectionStatus.error;
        errorMessage = 'Este computador não tem adaptador Wi-Fi.';
        notifyListeners();
        return false;
      case WifiAdapterState.blocked:
        connection = requiredSsid == null ? connection : ConnectionStatus.error;
        errorMessage =
            'O Wi-Fi está bloqueado por hardware. Desative o modo avião ou '
            'use a chave física do computador.';
        notifyListeners();
        return false;
      case WifiAdapterState.disabled:
        break;
    }

    final shouldEnable = await userPrompter.confirmEnableWifi();
    _stateLog.info('Usuário autorizou ligar o Wi-Fi: $shouldEnable');
    if (!shouldEnable) {
      if (requiredSsid != null) {
        connection = ConnectionStatus.disconnected;
      }
      errorMessage = null;
      noticeMessage = 'Conexão cancelada: o Wi-Fi está desligado.';
      notifyListeners();
      return false;
    }

    try {
      await wifiManager.enableAdapter();
      _stateLog.info('Solicitação para ligar o adaptador concluída.');
    } catch (error) {
      _stateLog.warning('Falha ao ligar o adaptador Wi-Fi.', error);
      connection = requiredSsid == null ? connection : ConnectionStatus.error;
      errorMessage = error is WifiException
          ? error.message
          : 'Não foi possível ligar o Wi-Fi: ${_errorText(error)}';
      notifyListeners();
      return false;
    }

    for (var attempt = 0; attempt < 10; attempt++) {
      try {
        final networks = await wifiManager.listNetworks();
        final ready = requiredSsid == null
            ? networks.isNotEmpty
            : networks.contains(requiredSsid);
        _stateLog.info(
          'Busca após ligar Wi-Fi (${attempt + 1}/10): '
          '${networks.length} rede(s); pronta=$ready',
        );
        if (ready) {
          errorMessage = null;
          return true;
        }
      } catch (error) {
        _stateLog.fine('Rede ainda indisponível após ligar o Wi-Fi: $error');
      }
      if (attempt < 9) {
        await _delay(const Duration(seconds: 1));
      }
    }

    connection = requiredSsid == null ? connection : ConnectionStatus.error;
    errorMessage = requiredSsid == null
        ? 'O Wi-Fi foi ligado, mas nenhuma rede apareceu. Tente buscar novamente.'
        : 'A rede "$requiredSsid" não apareceu após ligar o Wi-Fi. '
              'Verifique se a câmera está ligada.';
    notifyListeners();
    return false;
  }

  Future<bool?> verifyUploadSupport() async {
    if (connection != ConnectionStatus.connected) {
      return null;
    }
    try {
      uploadEnabled = await cardClient.isUploadEnabled();
      errorMessage = null;
    } catch (error) {
      uploadEnabled = null;
      errorMessage =
          'Não foi possível verificar o suporte à exclusão: '
          '${_errorText(error)}';
    }
    notifyListeners();
    return uploadEnabled;
  }

  Future<int?> cacheSizeOnDisk() async {
    try {
      return await cacheService.sizeOnDisk();
    } catch (error) {
      errorMessage = 'Não foi possível medir o cache: ${_errorText(error)}';
      notifyListeners();
      return null;
    }
  }

  Future<bool> clearCache() async {
    try {
      await cacheService.clear();
      errorMessage = null;
      notifyListeners();
      return true;
    } catch (error) {
      errorMessage = 'Não foi possível limpar o cache: ${_errorText(error)}';
      notifyListeners();
      return false;
    }
  }

  Future<void> selectNext() => _selectRelative(1);

  Future<void> selectPrevious() => _selectRelative(-1);

  void rotateRight() => _rotateSelected(1);

  void rotateLeft() => _rotateSelected(-1);

  void resetRotation() {
    final path = selected?.fullPath;
    if (path == null || !rotations.containsKey(path)) {
      return;
    }
    rotations.remove(path);
    savedThisSession.remove(path);
    _logOrientation(path, mode: 'visualização');
    notifyListeners();
  }

  void _rotateSelected(int delta) {
    final item = selected;
    if (!canRotate || item == null) {
      return;
    }
    final turns = ((manualQuarterTurns + delta) % 4 + 4) % 4;
    if (turns == 0) {
      rotations.remove(item.fullPath);
    } else {
      rotations[item.fullPath] = turns;
    }
    savedThisSession.remove(item.fullPath);
    _logOrientation(item.fullPath, mode: 'visualização');
    notifyListeners();
  }

  Future<String?> saveSelected() async {
    final item = selected;
    if (item == null || item.isDir || saving) {
      return null;
    }

    saving = true;
    errorMessage = null;
    lastSaveRotationMode = null;
    notifyListeners();
    try {
      var bytes = !previewIsThumbnail && selected?.fullPath == item.fullPath
          ? originalBytes
          : null;
      bytes ??= await cacheService.get(item.fullPath, fileSize: item.size);
      if (bytes == null) {
        bytes = await _download(item.fullPath);
        await cacheService.put(item.fullPath, bytes, fileSize: item.size);
      }

      final originalOrientation = readOrientation(bytes) ?? 1;
      final turns = rotations[item.fullPath] ?? 0;
      final effective = composeOrientation(originalOrientation, turns);
      var bytesToSave = bytes;
      var mode = 'original';
      if (effective != originalOrientation) {
        if (config.rotateSaveMode == 'exif') {
          final withOrientation = writeOrientation(bytes, effective);
          if (withOrientation != null) {
            bytesToSave = withOrientation;
            mode = 'exif';
          } else {
            noticeMessage = 'Não foi possível ajustar o EXIF; a foto será regravada em pixels.';
            bytesToSave = await imageExporter.exportJpeg(bytes, effective);
            mode = 'pixels';
          }
        } else {
          bytesToSave = await imageExporter.exportJpeg(bytes, effective);
          mode = 'pixels';
        }
      }
      _stateLog.info(
        'Salvando ${item.fullPath}: orientação base=$originalOrientation; '
        'giros=$turns; orientação efetiva=$effective; modo=$mode',
      );

      final localPath = await fileSaver.save(
        suggestedName: item.name,
        bytes: bytesToSave,
        initialDirectory: config.outputDir,
      );
      if (localPath == null) {
        return null;
      }
      savedThisSession[item.fullPath] = (
        localPath: localPath,
        size: bytesToSave.length,
        rotated: turns != 0,
      );
      lastSaveRotationMode = mode == 'original' ? null : mode;
      return localPath;
    } catch (error) {
      errorMessage = 'Não foi possível salvar o arquivo: ${_errorText(error)}';
      return null;
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> openContainingFolder(String filePath) async {
    try {
      await fileSaver.openContainingFolder(filePath);
    } catch (error) {
      errorMessage = 'Não foi possível abrir a pasta: ${_errorText(error)}';
      notifyListeners();
    }
  }

  Future<bool> deleteSelected({bool saveCopyFirst = false}) async {
    if (!canDelete) {
      return false;
    }
    final item = selected!;
    final previousFiles = _filesInFolder(item.parentPath);
    final previousIndex = previousFiles.indexWhere(
      (candidate) => candidate.fullPath == item.fullPath,
    );

    deleting = true;
    errorMessage = null;
    noticeMessage = null;
    notifyListeners();
    try {
      if (saveCopyFirst) {
        var saved = savedThisSession[item.fullPath];
        if (saved == null) {
          final localPath = await saveSelected();
          if (localPath == null) {
            return false;
          }
          saved = savedThisSession[item.fullPath];
        }
        if (saved == null) {
          return false;
        }

        final localSize = await fileSaver.sizeOf(saved.localPath);
        if (localSize != saved.size ||
            (!saved.rotated && localSize != item.size)) {
          errorMessage =
              'O tamanho da cópia salva é diferente do arquivo no cartão.';
          return false;
        }
      }

      try {
        await cardClient.deleteFile(item.fullPath);
      } on CardUnreachableException {
        _pendingDeletion = _PendingDeletion(
          item: item,
          previousIndex: previousIndex,
        );
        _stopPingMonitor();
        connection = ConnectionStatus.disconnected;
        uploadEnabled = null;
        errorMessage =
            'A conexão caiu durante a exclusão. Reconecte para confirmar '
            'se a foto foi apagada.';
        return false;
      }

      final relisted = await loadDir(item.parentPath, force: true);
      if (!relisted) {
        _pendingDeletion = _PendingDeletion(
          item: item,
          previousIndex: previousIndex,
        );
        _stopPingMonitor();
        connection = ConnectionStatus.disconnected;
        uploadEnabled = null;
        errorMessage =
            'A conexão caiu antes de confirmar a exclusão. Reconecte para '
            'verificar o estado da foto.';
        return false;
      }
      if (_folderContains(item.parentPath, item.fullPath)) {
        errorMessage = 'O cartão não removeu o arquivo.';
        return false;
      }

      rotations.remove(item.fullPath);
      await cacheService.remove(item.fullPath);
      await _selectAfterDeletion(item.parentPath, previousIndex);
      return true;
    } catch (error) {
      errorMessage = error is CardDeleteException
          ? _errorText(error)
          : 'Não foi possível excluir o arquivo: ${_errorText(error)}';
      return false;
    } finally {
      deleting = false;
      notifyListeners();
    }
  }

  Future<bool> deleteFolder(CardItem folder) async {
    if (!canDeleteFolders || !folder.isDir) {
      return false;
    }

    deletingFolders = true;
    errorMessage = null;
    noticeMessage = null;
    notifyListeners();
    try {
      await cardClient.deleteEmptyFolder(folder.fullPath);
      _removeFolderFromLocalState(folder);
      final relisted = await loadDir(folder.parentPath, force: true);
      if (!relisted || _folderContains(folder.parentPath, folder.fullPath)) {
        errorMessage = 'O cartão não removeu a pasta.';
        return false;
      }
      noticeMessage = _folderDeleteNotice;
      return true;
    } on FolderNotEmptyException catch (error) {
      errorMessage =
          'A pasta não está vazia (${error.count} arquivos). Nada foi apagado.';
      return false;
    } on CardUnreachableException catch (error) {
      _stopPingMonitor();
      connection = ConnectionStatus.disconnected;
      uploadEnabled = null;
      errorMessage = _errorText(error);
      return false;
    } catch (error) {
      errorMessage = 'Não foi possível apagar a pasta: ${_errorText(error)}';
      return false;
    } finally {
      deletingFolders = false;
      notifyListeners();
    }
  }

  Future<List<CardItem>> scanEmptyFolders({CancelToken? cancel}) async {
    if (!canDeleteFolders) {
      return const <CardItem>[];
    }

    scanningFolders = true;
    emptyFolders = <CardItem>[];
    scanProgress = (done: 0, total: 0);
    errorMessage = null;
    notifyListeners();
    final found = <CardItem>[];
    try {
      var dcimItems = tree['/DCIM'];
      if (dcimItems == null) {
        dcimItems = await cardClient.listDir('/DCIM');
        if (!(cancel?.isCancelled ?? false)) {
          tree['/DCIM'] = _sortItems(dcimItems);
        }
      }
      var folders = dcimItems.where((item) => item.isDir).toList();
      var depth = 1;
      while (folders.isNotEmpty &&
          depth <= 3 &&
          !(cancel?.isCancelled ?? false)) {
        scanProgress = (
          done: scanProgress.done,
          total: scanProgress.total + folders.length,
        );
        notifyListeners();
        final nested = <CardItem>[];
        var nextIndex = 0;

        Future<void> worker() async {
          while (nextIndex < folders.length &&
              !(cancel?.isCancelled ?? false)) {
            final folder = folders[nextIndex++];
            final count = await cardClient.countFiles(folder.fullPath);
            if (cancel?.isCancelled ?? false) {
              return;
            }
            if (count == 0) {
              found.add(folder);
            } else if (depth < 3) {
              var children = tree[folder.fullPath];
              children ??= await cardClient.listDir(folder.fullPath);
              tree[folder.fullPath] = _sortItems(children);
              nested.addAll(children.where((item) => item.isDir));
            }
            scanProgress = (
              done: scanProgress.done + 1,
              total: scanProgress.total,
            );
            notifyListeners();
          }
        }

        await Future.wait(<Future<void>>[worker(), worker()]);
        folders = nested;
        depth++;
      }
      if (!(cancel?.isCancelled ?? false)) {
        found.sort(
          (first, second) => first.fullPath.toLowerCase().compareTo(
            second.fullPath.toLowerCase(),
          ),
        );
        emptyFolders = List<CardItem>.unmodifiable(found);
      }
      _stateLog.info(
        'Varredura de pastas concluída: verificadas=${scanProgress.done}; '
        'vazias=${found.length}; cancelada=${cancel?.isCancelled ?? false}',
      );
      return List<CardItem>.unmodifiable(found);
    } catch (error) {
      errorMessage =
          'Não foi possível verificar as pastas: ${_errorText(error)}';
      _stateLog.warning('Falha na varredura de pastas vazias.', error);
      return const <CardItem>[];
    } finally {
      scanningFolders = false;
      notifyListeners();
    }
  }

  Future<FolderDeletionSummary> deleteEmptyFolders(
    List<CardItem> folders,
  ) async {
    final deleted = <CardItem>[];
    final skipped = <CardItem>[];
    final failures = <CardItem, String>{};
    if (!canDeleteFolders) {
      return FolderDeletionSummary(
        deleted: deleted,
        skipped: skipped,
        failures: failures,
      );
    }

    deletingFolders = true;
    errorMessage = null;
    noticeMessage = null;
    notifyListeners();
    final parents = <String>{};
    try {
      for (final folder in folders.where((item) => item.isDir)) {
        try {
          await cardClient.deleteEmptyFolder(folder.fullPath);
          deleted.add(folder);
          parents.add(folder.parentPath);
          _removeFolderFromLocalState(folder);
        } on FolderNotEmptyException {
          skipped.add(folder);
        } on CardUnreachableException catch (error) {
          failures[folder] = _errorText(error);
          _stopPingMonitor();
          connection = ConnectionStatus.disconnected;
          uploadEnabled = null;
          errorMessage = 'A conexão com o cartão foi perdida. A exclusão das pastas foi interrompida.';
          break;
        } on CardDeleteException catch (error) {
          failures[folder] = _errorText(error);
        } catch (error) {
          failures[folder] = _errorText(error);
        }
      }

      if (connection == ConnectionStatus.connected) {
        for (final parent in parents) {
          await loadDir(parent, force: true);
        }
        for (final folder in deleted.toList()) {
          if (_folderContains(folder.parentPath, folder.fullPath)) {
            deleted.remove(folder);
            failures[folder] = 'O cartão não removeu a pasta.';
          }
        }
      }
      if (deleted.isNotEmpty) {
        noticeMessage = _folderDeleteNotice;
      }
      _stateLog.info(
        'Exclusão de pastas concluída: apagadas=${deleted.length}; '
        'puladas=${skipped.length}; falhas=${failures.length}',
      );
      return FolderDeletionSummary(
        deleted: deleted,
        skipped: skipped,
        failures: failures,
      );
    } finally {
      deletingFolders = false;
      notifyListeners();
    }
  }

  Future<bool> updateConfig(AppConfig updatedConfig) async {
    final shouldRefreshUpload =
        !config.deleteEnabled &&
        updatedConfig.deleteEnabled &&
        connection == ConnectionStatus.connected;

    try {
      await configService.save(updatedConfig);
    } catch (error) {
      errorMessage =
          'Não foi possível salvar as configurações: '
          '${_errorText(error)}';
      notifyListeners();
      return false;
    }

    config = updatedConfig;
    cardClient.updateBaseUrl(updatedConfig.baseUrl);
    for (final path in tree.keys.toList()) {
      tree[path] = _sortItems(tree[path]!);
    }
    errorMessage = null;
    notifyListeners();

    if (shouldRefreshUpload) {
      try {
        uploadEnabled = await cardClient.isUploadEnabled();
      } catch (_) {
        uploadEnabled = null;
      }
      notifyListeners();
    }
    return true;
  }

  void previewSnackBarSeconds(int seconds) {
    config = config.copyWith(snackBarSeconds: seconds.clamp(3, 60));
    notifyListeners();
  }

  Future<Uint8List> _download(
    String path, {
    DownloadProgress? onProgress,
  }) async {
    _activeDownloads++;
    try {
      return await cardClient.download(path, onProgress: onProgress);
    } finally {
      _activeDownloads--;
    }
  }

  void _startPingMonitor() {
    _stopPingMonitor();
    _pingTimer = Timer.periodic(
      pingInterval,
      (_) => unawaited(_checkConnection()),
    );
  }

  void _stopPingMonitor() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _pingInProgress = false;
  }

  Future<void> _checkConnection() async {
    if (_pingInProgress ||
        connection != ConnectionStatus.connected ||
        downloading ||
        deleting ||
        deletingFolders) {
      return;
    }
    _pingInProgress = true;
    final generation = _connectionGeneration;
    var reachable = false;
    try {
      reachable = await cardClient.ping();
    } catch (_) {
      reachable = false;
    } finally {
      _pingInProgress = false;
    }
    if (generation != _connectionGeneration ||
        reachable ||
        connection != ConnectionStatus.connected) {
      return;
    }
    _stopPingMonitor();
    connection = ConnectionStatus.disconnected;
    uploadEnabled = null;
    errorMessage =
        'A conexão com o cartão foi perdida. Verifique se a câmera está ligada '
        'e conecte novamente.';
    notifyListeners();
  }

  Future<void> _resolvePendingDeletion() async {
    final pending = _pendingDeletion;
    if (pending == null) {
      return;
    }
    final relisted = await loadDir(pending.item.parentPath, force: true);
    if (!relisted) {
      errorMessage =
          'A conexão voltou, mas ainda não foi possível confirmar a exclusão.';
      notifyListeners();
      return;
    }

    _pendingDeletion = null;
    if (_folderContains(pending.item.parentPath, pending.item.fullPath)) {
      errorMessage = 'O cartão confirmou que a foto não foi apagada.';
      notifyListeners();
      return;
    }

    rotations.remove(pending.item.fullPath);
    try {
      await cacheService.remove(pending.item.fullPath);
    } catch (error) {
      errorMessage =
          'A foto foi apagada, mas o cache local não pôde ser limpo: '
          '${_errorText(error)}';
    }
    unawaited(
      _selectAfterDeletion(pending.item.parentPath, pending.previousIndex),
    );
    noticeMessage = _deleteSuccessNotice;
    notifyListeners();
  }

  Future<void> _selectRelative(int offset) async {
    final item = selected;
    if (item == null) {
      return;
    }
    final files = _filesInFolder(item.parentPath);
    final index = files.indexWhere(
      (candidate) => candidate.fullPath == item.fullPath,
    );
    final targetIndex = index + offset;
    if (index < 0 || targetIndex < 0 || targetIndex >= files.length) {
      return;
    }
    await selectFile(files[targetIndex]);
  }

  Future<void> _selectAfterDeletion(String folderPath, int oldIndex) async {
    final files = _filesInFolder(folderPath);
    if (files.isEmpty) {
      _invalidatePreview();
      selected = null;
      previewBytes = null;
      originalBytes = null;
      displayBytes = null;
      baseOrientation = 1;
      previewIsThumbnail = false;
      previewProgress = null;
      notifyListeners();
      return;
    }

    final targetIndex = oldIndex >= 0 && oldIndex < files.length
        ? oldIndex
        : files.length - 1;
    await selectFile(files[targetIndex]);
  }

  List<CardItem> _filesInFolder(String path) {
    return (tree[path] ?? const <CardItem>[])
        .where((item) => !item.isDir)
        .toList();
  }

  bool _folderContains(String folderPath, String fullPath) {
    return (tree[folderPath] ?? const <CardItem>[]).any(
      (item) => item.fullPath == fullPath,
    );
  }

  List<CardItem> _sortItems(List<CardItem> source) {
    final items = List<CardItem>.of(source);
    items.sort((first, second) {
      if (first.isDir != second.isDir) {
        return first.isDir ? -1 : 1;
      }
      final comparison = switch (config.sortBy) {
        SortBy.name => first.name.toLowerCase().compareTo(
          second.name.toLowerCase(),
        ),
        SortBy.date => _compareNullableDatesDescending(
          first.dateTime,
          second.dateTime,
        ),
        SortBy.size => second.size.compareTo(first.size),
      };
      return comparison != 0
          ? comparison
          : first.name.toLowerCase().compareTo(second.name.toLowerCase());
    });
    return items;
  }

  void _clearCardState() {
    tree.clear();
    expandedPaths.clear();
    loadingPaths.clear();
    folderErrors.clear();
    _loadGenerations.clear();
    selected = null;
    previewBytes = null;
    originalBytes = null;
    displayBytes = null;
    baseOrientation = 1;
    rotations.clear();
    previewIsThumbnail = false;
    previewProgress = null;
    uploadEnabled = null;
    emptyFolders = <CardItem>[];
    scanProgress = (done: 0, total: 0);
  }

  void _removeFolderFromLocalState(CardItem folder) {
    tree[folder.parentPath]?.removeWhere(
      (item) => item.fullPath == folder.fullPath,
    );
    final prefix = '${folder.fullPath}/';
    tree.removeWhere(
      (path, _) => path == folder.fullPath || path.startsWith(prefix),
    );
    expandedPaths.removeWhere(
      (path) => path == folder.fullPath || path.startsWith(prefix),
    );
    loadingPaths.removeWhere(
      (path) => path == folder.fullPath || path.startsWith(prefix),
    );
    folderErrors.removeWhere(
      (path, _) => path == folder.fullPath || path.startsWith(prefix),
    );
    emptyFolders = emptyFolders
        .where(
          (item) =>
              item.fullPath != folder.fullPath &&
              !item.fullPath.startsWith(prefix),
        )
        .toList();
    final selectedPath = selected?.fullPath;
    if (selectedPath != null &&
        (selectedPath == folder.fullPath || selectedPath.startsWith(prefix))) {
      _invalidatePreview();
      selected = null;
      previewBytes = null;
      originalBytes = null;
      displayBytes = null;
      baseOrientation = 1;
      previewIsThumbnail = false;
      previewProgress = null;
    }
  }

  void _invalidatePreview() {
    _thumbnailCancellationToken?.cancel();
    _thumbnailCancellationToken = null;
    _previewGeneration++;
  }

  void _logOrientation(String path, {required String mode}) {
    _stateLog.info(
      '$path: orientação base=$baseOrientation; giros=${rotations[path] ?? 0}; '
      'orientação efetiva=${composeOrientation(baseOrientation, rotations[path] ?? 0)}; '
      'modo=$mode',
    );
  }

  bool _isCurrentPreview(int generation, CardItem item) {
    return generation == _previewGeneration &&
        selected?.fullPath == item.fullPath;
  }

  @override
  void dispose() {
    _stopPingMonitor();
    _invalidatePreview();
    super.dispose();
  }
}

int _compareNullableDatesDescending(DateTime? first, DateTime? second) {
  if (identical(first, second)) {
    return 0;
  }
  if (first == null) {
    return 1;
  }
  if (second == null) {
    return -1;
  }
  return second.compareTo(first);
}

String _errorText(Object error) {
  return switch (error) {
    WifiException exception => exception.message,
    CardDeleteException() =>
      'O cartão recusou apagar. Confirme se UPLOAD=1 está ativo e se a chave '
          'de proteção do cartão não está travada.',
    FolderNotEmptyException exception =>
      'A pasta não está vazia (${exception.count} arquivos). Nada foi apagado.',
    CardUnreachableException() =>
      'Não foi possível alcançar o cartão. Verifique a conexão Wi-Fi e se a '
          'câmera está ligada.',
    CardParseException exception =>
      'O cartão enviou uma lista de arquivos inválida: ${exception.message}',
    CardHttpException exception =>
      'O cartão respondeu com erro HTTP ${exception.statusCode}.',
    CacheException() => 'Não foi possível acessar o cache local.',
    FileSaveException exception => exception.message,
    ConfigServiceException() => 'Não foi possível acessar as configurações.',
    _ => error.toString(),
  };
}

class _PendingDeletion {
  const _PendingDeletion({required this.item, required this.previousIndex});

  final CardItem item;
  final int previousIndex;
}

class FolderDeletionSummary {
  const FolderDeletionSummary({
    required this.deleted,
    required this.skipped,
    required this.failures,
  });

  final List<CardItem> deleted;
  final List<CardItem> skipped;
  final Map<CardItem, String> failures;
}

const String _deleteSuccessNotice =
    'Foto apagada. Se a câmera não enxergar o cartão ou mostrar o cartão como '
    'protegido, desligue e ligue a câmera.';

const String _folderDeleteNotice =
    'Se a câmera não reconhecer o cartão, desligue e ligue a câmera.';

class _DecliningUserPrompter implements UserPrompter {
  const _DecliningUserPrompter();

  @override
  Future<bool> confirmEnableWifi() async => false;
}
