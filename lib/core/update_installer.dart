import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:toshiba_flashair_wifi_viewer/core/app_constants.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update/install_kind.dart';
import 'package:toshiba_flashair_wifi_viewer/models/update_info.dart';

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);
typedef DetachedProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
});

abstract interface class UpdateInstallation {
  Directory get updateDirectory;
  Future<InstallDetection> detect();
  Future<void> install(UpdateInfo info, File archive);
  Future<String?> consumePreviousLog();
  Future<void> openReleasePage(String url);
}

class UpdateInstaller implements UpdateInstallation {
  UpdateInstaller({
    String? platform,
    String? executablePath,
    Directory? cacheDirectory,
    this.developmentMode,
    ProcessRunner? processRunner,
    DetachedProcessStarter? detachedStarter,
    DateTime Function()? now,
  }) : platform = platform ?? Platform.operatingSystem,
       executablePath = executablePath ?? Platform.resolvedExecutable,
       cacheDirectory = cacheDirectory ?? Directory.systemTemp,
       _processRunner = processRunner ?? _runProcess,
       _detachedStarter = detachedStarter ?? _startDetached,
       _now = now ?? DateTime.now;

  final String platform;
  final String executablePath;
  final Directory cacheDirectory;
  final bool? developmentMode;
  final ProcessRunner _processRunner;
  final DetachedProcessStarter _detachedStarter;
  final DateTime Function() _now;
  final Logger _log = Logger('UpdateInstaller');

  @override
  Directory get updateDirectory =>
      Directory(path.join(cacheDirectory.path, 'updates'));
  File get markerFile =>
      File(path.join(updateDirectory.path, 'data', 'just_updated.txt'));
  File get logFile => File(path.join(updateDirectory.path, 'update.log'));

  String get _helperName =>
      platform == 'windows' ? '$updaterName.exe' : updaterName;

  @override
  Future<InstallDetection> detect() => detectInstall(
    executablePath: executablePath,
    platform: platform,
    developmentMode: developmentMode,
  );

  @override
  Future<void> install(UpdateInfo info, File archive) async {
    final detection = await detect();
    if (detection.kind != InstallKind.portable) {
      throw UpdateInstallException(
        detection.reason ?? 'atualização automática indisponível',
      );
    }
    final appDir = File(executablePath).parent.absolute;
    final helperDir = Directory(path.join(updateDirectory.path, 'helper'));
    await helperDir.create(recursive: true);
    final helper = File(path.join(helperDir.path, _helperName));
    if (await helper.exists()) await helper.delete();
    await File(path.join(appDir.path, _helperName)).copy(helper.path);
    if (platform != 'windows') {
      final chmod = await _processRunner('chmod', <String>['755', helper.path]);
      if (chmod.exitCode != 0) {
        throw const UpdateInstallException(
          'Não foi possível preparar o auxiliar.',
        );
      }
    }

    final staging = Directory(
      path.join(updateDirectory.path, 'staging-${info.tag}'),
    );
    await markerFile.parent.create(recursive: true);
    await markerFile.writeAsString(
      '${info.tag}\n${_now().toIso8601String()}\n',
      flush: true,
    );
    final arguments = <String>[
      '--finish-update',
      '$pid',
      appDir.path,
      path.basename(executablePath),
      archive.absolute.path,
      staging.absolute.path,
      logFile.absolute.path,
    ];
    _log.info('Iniciando auxiliar: pid=$pid; argumentos=$arguments');
    try {
      final environment = Map<String, String>.of(Platform.environment)
        ..remove(pretendVarName);
      await _detachedStarter(helper.path, arguments, environment: environment);
    } catch (error) {
      if (await markerFile.exists()) await markerFile.delete();
      throw UpdateInstallException(
        'Não foi possível iniciar o auxiliar: $error',
      );
    }
  }

  @override
  Future<String?> consumePreviousLog() async {
    if (!await logFile.exists()) return null;
    final result = await logFile.readAsString();
    _log.info('Resultado do auxiliar: ${result.trim()}');
    await logFile.delete();
    if (!RegExp(r'(^|\n).*\bOK\b').hasMatch(result)) {
      if (await markerFile.exists()) await markerFile.delete();
    }
    return result;
  }

  @override
  Future<void> openReleasePage(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      throw const UpdateInstallException('Link da release inválido.');
    }
    final result = platform == 'windows'
        ? await _processRunner('cmd', <String>['/c', 'start', '', url])
        : await _processRunner('xdg-open', <String>[url]);
    if (result.exitCode != 0) {
      throw const UpdateInstallException(
        'Não foi possível abrir a página da release.',
      );
    }
  }
}

Future<ProcessResult> _runProcess(String executable, List<String> arguments) =>
    Process.run(executable, arguments);

Future<Process> _startDetached(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) => Process.start(
  executable,
  arguments,
  mode: ProcessStartMode.detached,
  environment: environment,
  includeParentEnvironment: false,
);

class UpdateInstallException implements Exception {
  const UpdateInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}
