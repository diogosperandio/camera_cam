import 'dart:async';

import 'package:toshiba_flashair_wifi_viewer/core/update_installer.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/version_utils.dart';
import 'package:toshiba_flashair_wifi_viewer/models/update_info.dart';
import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:package_info_plus/package_info_plus.dart';

enum UpdateStatus {
  idle,
  checking,
  available,
  upToDate,
  downloading,
  verifying,
  readyToInstall,
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
    DateTime Function()? now,
    this.initialDelay = const Duration(seconds: 3),
    this.disconnectDelay = const Duration(seconds: 10),
  }) : _versionLoader = versionLoader ?? _loadPackageVersion,
       _requestAppClose = requestAppClose ?? _noClose,
       _now = now ?? DateTime.now;

  final AppState appState;
  final UpdateRepository service;
  final UpdateInstallation installer;
  final Future<String> Function() _versionLoader;
  final Future<void> Function() _requestAppClose;
  final DateTime Function() _now;
  final Duration initialDelay;
  final Duration disconnectDelay;
  final Logger _log = Logger('UpdateController');

  UpdateStatus status = UpdateStatus.idle;
  String currentVersion = '0.0.0';
  UpdateInfo? availableUpdate;
  double? progress;
  String? errorMessage;
  String? previousUpdateFailure;
  UpdateCancelToken? _cancelToken;
  Timer? _initialTimer;
  Timer? _disconnectTimer;
  ConnectionStatus? _previousConnection;

  Future<void> init() async {
    currentVersion =
        parseVersion(await _versionLoader())?.toString() ?? '0.0.0';
    final previousLog = await installer.consumePreviousLog();
    if (previousLog != null && previousLog.contains('FAILURE')) {
      previousUpdateFailure =
          'A atualização anterior falhou. Consulte o log do aplicativo.';
    }
    _previousConnection = appState.connection;
    appState.addListener(_handleAppState);
    _initialTimer = Timer(initialDelay, () => unawaited(checkAutomatically()));
    notifyListeners();
  }

  Future<void> checkAutomatically() async {
    if (!appState.config.autoCheckUpdates ||
        !isUpdateDue(appState.config.lastUpdateCheck, _now()) ||
        appState.connection == ConnectionStatus.connecting ||
        appState.connection == ConnectionStatus.connected) {
      return;
    }
    await _check(manual: false);
  }

  Future<void> checkNow() => _check(manual: true);

  Future<void> _check({required bool manual}) async {
    status = UpdateStatus.checking;
    errorMessage = null;
    notifyListeners();
    _log.info(
      'Verificação de atualização: origem=${manual ? 'manual' : 'automática'}',
    );
    try {
      final info = await service.fetchLatest(currentVersion);
      if (!manual) {
        await appState.updateConfig(
          appState.config.copyWith(lastUpdateCheck: _now()),
        );
      }
      if (info == null) {
        availableUpdate = null;
        status = manual ? UpdateStatus.upToDate : UpdateStatus.idle;
        _log.info('Verificação concluída: aplicativo atualizado.');
      } else if (!manual && info.version == appState.config.skippedVersion) {
        availableUpdate = null;
        status = UpdateStatus.idle;
        _log.info('Verificação concluída: versão ${info.version} ignorada.');
      } else {
        availableUpdate = info;
        status = UpdateStatus.available;
        _log.info('Verificação concluída: versão ${info.version} disponível.');
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

  Future<({bool ok, String? reason})> canInstall() => installer.canInstall();

  Future<void> startUpdate() async {
    final info = availableUpdate;
    if (info == null || info.assetUrl == null) return;
    if (appState.saving || appState.deleting || appState.downloading) {
      status = UpdateStatus.error;
      errorMessage =
          'Aguarde a operação com a foto terminar antes de atualizar.';
      notifyListeners();
      return;
    }
    final allowed = await installer.canInstall();
    if (!allowed.ok) {
      status = UpdateStatus.error;
      errorMessage = allowed.reason;
      notifyListeners();
      return;
    }
    _cancelToken = UpdateCancelToken();
    status = UpdateStatus.downloading;
    progress = 0;
    errorMessage = null;
    notifyListeners();
    try {
      final archive = await service.download(
        info,
        installer.updateDirectory,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          progress = total == null || total == 0 ? null : received / total;
          if (total != null && received >= total) {
            status = UpdateStatus.verifying;
          }
          notifyListeners();
        },
        onVerifying: () {
          status = UpdateStatus.verifying;
          notifyListeners();
        },
      );
      if (_cancelToken?.isCancelled ?? false) return;
      status = UpdateStatus.readyToInstall;
      notifyListeners();
      status = UpdateStatus.installing;
      notifyListeners();
      await installer.prepareAndLaunch(archive);
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

  void cancelUpdate() => _cancelToken?.cancel();

  Future<void> skipThisVersion() async {
    final version = availableUpdate?.version;
    if (version == null) return;
    await appState.updateConfig(
      appState.config.copyWith(skippedVersion: version),
    );
    availableUpdate = null;
    status = UpdateStatus.idle;
    notifyListeners();
  }

  void remindLater() {
    availableUpdate = null;
    status = UpdateStatus.idle;
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

  void _handleAppState() {
    final current = appState.connection;
    if (_previousConnection != ConnectionStatus.disconnected &&
        current == ConnectionStatus.disconnected) {
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

String _humanError(Object error) {
  return switch (error) {
    UpdateNetworkException() => 'Sem acesso à internet. Se estiver conectado ao Wi-Fi do cartão, desconecte e tente de novo.',
    UpdateRateLimitException() => 'O limite de consultas do GitHub foi atingido. Tente novamente mais tarde.',
    UpdateException exception => exception.message,
    UpdateInstallException exception => exception.message,
    _ => 'Não foi possível concluir a atualização.',
  };
}
