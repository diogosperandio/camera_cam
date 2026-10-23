import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:toshiba_flashair_wifi_viewer/core/app_constants.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update/install_kind.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update_installer.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/version_utils.dart';
import 'package:toshiba_flashair_wifi_viewer/models/update_info.dart';
import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';

enum UpdateStatus {
  idle,
  checking,
  available,
  upToDate,
  downloading,
  verifying,
  waitingForTasks,
  installing,
  error,
}

class UpdateController extends ChangeNotifier {
  UpdateController({
    required this.appState,
    required this.service,
    required this.installer,
    Future<String> Function()? versionLoader,
    Future<void> Function()? requestAppClose,
    this.repo = githubRepo,
    this.initialDelay = const Duration(seconds: 2),
    this.disconnectDelay = const Duration(seconds: 10),
  }) : _versionLoader = versionLoader ?? _loadPackageVersion,
       _requestAppClose = requestAppClose ?? _noClose;

  final AppState appState;
  final UpdateRepository service;
  final UpdateInstallation installer;
  final Future<String> Function() _versionLoader;
  final Future<void> Function() _requestAppClose;
  final String repo;
  final Duration initialDelay;
  final Duration disconnectDelay;
  final Logger _log = Logger('UpdateController');

  UpdateStatus status = UpdateStatus.idle;
  String currentVersion = '0.0.0';
  UpdateInfo? availableUpdate;
  InstallDetection installDetection = (InstallKind.unsupported, 'verificando');
  double? progress;
  int receivedBytes = 0;
  int? totalBytes;
  String? errorMessage;
  String? previousUpdateFailure;
  bool promptPending = false;
  bool bannerVisible = false;
  bool _automaticAttempted = false;
  bool _waitingCancelled = false;
  UpdateCancelToken? _cancelToken;
  Timer? _initialTimer;
  Timer? _disconnectTimer;
  ConnectionStatus? _previousConnection;

  Future<void> init() async {
    currentVersion = effectiveCurrentVersion(
      parseVersion(await _versionLoader())?.toString() ?? '0.0.0',
    );
    installDetection = await installer.detect();
    _log.info(
      'Tipo de instalação=${installDetection.kind.name}; motivo=${installDetection.reason}',
    );
    final previousLog = await installer.consumePreviousLog();
    if (previousLog != null &&
        !RegExp(r'(^|\n).*\bOK\b').hasMatch(previousLog)) {
      previousUpdateFailure =
          'A atualização anterior falhou: ${_lastErrorLine(previousLog)}';
      _log.warning('Falha informada pelo auxiliar: $previousLog');
    }
    _previousConnection = appState.connection;
    appState.addListener(_handleAppState);
    if (repo.isNotEmpty) {
      _initialTimer = Timer(
        initialDelay,
        () => unawaited(checkAutomatically()),
      );
    }
    notifyListeners();
  }

  Future<void> checkAutomatically() async {
    if (_automaticAttempted ||
        !appState.config.autoCheckUpdates ||
        repo.isEmpty) {
      return;
    }
    if (appState.connection == ConnectionStatus.connecting ||
        appState.connection == ConnectionStatus.connected) {
      _log.info('Verificação automática adiada: conectado ao Wi-Fi do cartão.');
      return;
    }
    _automaticAttempted = true;
    await _check(manual: false);
  }

  Future<void> checkNow() => _check(manual: true);

  Future<void> _check({required bool manual}) async {
    if (repo.isEmpty) {
      if (manual) {
        status = UpdateStatus.error;
        errorMessage = 'Atualizações desativadas nesta compilação.';
        notifyListeners();
      }
      return;
    }
    status = UpdateStatus.checking;
    errorMessage = null;
    notifyListeners();
    _log.info(
      'Verificação de atualização: origem=${manual ? 'manual' : 'automática'}',
    );
    try {
      final info = await service.fetchLatest(currentVersion);
      if (info == null) {
        availableUpdate = null;
        promptPending = false;
        bannerVisible = false;
        status = manual ? UpdateStatus.upToDate : UpdateStatus.idle;
        _log.info('Verificação concluída: nenhuma atualização.');
      } else {
        availableUpdate = info;
        bannerVisible = true;
        promptPending =
            manual || info.version != appState.config.skippedVersion;
        status = UpdateStatus.available;
        _log.info(
          'Verificação concluída: ${info.tag} disponível; prompt=$promptPending.',
        );
      }
    } catch (error) {
      _log.warning(
        'Falha na verificação ${manual ? 'manual' : 'automática'}.',
        error,
      );
      if (manual) {
        errorMessage = _humanError(error);
        status = UpdateStatus.error;
      } else {
        status = UpdateStatus.idle;
      }
    }
    notifyListeners();
  }

  Future<void> startUpdate() async {
    final info = availableUpdate;
    if (info == null || info.assetUrl == null) return;
    if (installDetection.kind != InstallKind.portable) {
      await openReleasePage();
      return;
    }
    promptPending = false;
    _cancelToken = UpdateCancelToken();
    status = UpdateStatus.downloading;
    receivedBytes = 0;
    totalBytes = info.assetSize > 0 ? info.assetSize : null;
    progress = 0;
    errorMessage = null;
    notifyListeners();
    try {
      final archive = await service.download(
        info,
        installer.updateDirectory,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          receivedBytes = received;
          totalBytes = total;
          progress = total == null || total == 0 ? null : received / total;
          notifyListeners();
        },
        onVerifying: () {
          status = UpdateStatus.verifying;
          notifyListeners();
        },
      );
      if (_cancelToken?.isCancelled ?? false) return;
      if (_tasksBusy) {
        status = UpdateStatus.waitingForTasks;
        _waitingCancelled = false;
        notifyListeners();
        while (_tasksBusy && !_waitingCancelled) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (_waitingCancelled) {
          status = UpdateStatus.available;
          return;
        }
      }
      status = UpdateStatus.installing;
      notifyListeners();
      await installer.install(info, archive);
      await _requestAppClose();
    } on UpdateCancelledException {
      status = UpdateStatus.available;
    } catch (error) {
      status = UpdateStatus.error;
      errorMessage = _humanError(error);
      _log.warning('Falha ao atualizar.', error);
    } finally {
      _cancelToken = null;
      notifyListeners();
    }
  }

  bool get _tasksBusy =>
      appState.saving ||
      appState.deleting ||
      appState.deletingFolders ||
      appState.downloading;

  void cancelUpdate() {
    if (status == UpdateStatus.waitingForTasks) {
      _waitingCancelled = true;
    } else {
      _cancelToken?.cancel();
    }
  }

  Future<void> skipThisVersion() async {
    final version = availableUpdate?.version;
    if (version == null) return;
    await appState.updateConfig(
      appState.config.copyWith(skippedVersion: version),
    );
    promptPending = false;
    bannerVisible = true;
    status = UpdateStatus.available;
    notifyListeners();
  }

  void remindLater() {
    promptPending = false;
    bannerVisible = true;
    notifyListeners();
  }

  void closeBanner() {
    bannerVisible = false;
    notifyListeners();
  }

  Future<void> stopIgnoring() async {
    await appState.updateConfig(appState.config.copyWith(skippedVersion: null));
    notifyListeners();
  }

  Future<void> openReleasePage() async {
    final url = availableUpdate?.pageUrl;
    if (url == null) return;
    try {
      await installer.openReleasePage(url);
    } catch (error) {
      status = UpdateStatus.error;
      errorMessage = _humanError(error);
      notifyListeners();
    }
  }

  void markPromptShown() {
    promptPending = false;
    notifyListeners();
  }

  void _handleAppState() {
    final current = appState.connection;
    if (_previousConnection != ConnectionStatus.disconnected &&
        current == ConnectionStatus.disconnected &&
        !_automaticAttempted) {
      _disconnectTimer?.cancel();
      _disconnectTimer = Timer(
        disconnectDelay,
        () => unawaited(checkAutomatically()),
      );
    }
    _previousConnection = current;
  }

  @override
  void dispose() {
    _initialTimer?.cancel();
    _disconnectTimer?.cancel();
    _cancelToken?.cancel();
    appState.removeListener(_handleAppState);
    super.dispose();
  }
}

Future<String> _loadPackageVersion() async =>
    (await PackageInfo.fromPlatform()).version;
Future<void> _noClose() async {}

String _lastErrorLine(String log) =>
    log.split('\n').where((line) => line.contains('ERRO')).lastOrNull ??
    'consulte o log';

String _humanError(Object error) => switch (error) {
  UpdateNetworkException() => 'Sem acesso à internet. Se estiver conectado ao Wi-Fi do cartão, desconecte e tente de novo.',
  UpdateRateLimitException() =>
    'O limite de consultas do GitHub foi atingido. Tente novamente mais tarde.',
  UpdateException exception => exception.message,
  UpdateInstallException exception => exception.message,
  _ => 'Não foi possível concluir a atualização.',
};
