import 'dart:io';

import 'package:camera_cam/core/app_constants.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);
typedef DetachedProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments,
);

abstract interface class UpdateInstallation {
  Directory get updateDirectory;
  Future<({bool ok, String? reason})> canInstall();
  Future<void> prepareAndLaunch(File archive);
  Future<String?> consumePreviousLog();
  Future<void> openReleasePage(String url);
}

class UpdateInstaller implements UpdateInstallation {
  UpdateInstaller({
    String? platform,
    String? executablePath,
    Map<String, String>? environment,
    bool? developmentMode,
    Directory? temporaryDirectory,
    ProcessRunner? processRunner,
    DetachedProcessStarter? detachedStarter,
  }) : platform = platform ?? Platform.operatingSystem,
       executablePath = executablePath ?? Platform.resolvedExecutable,
       environment = environment ?? Platform.environment,
       developmentMode = developmentMode ?? (kDebugMode || kProfileMode),
       temporaryDirectory = temporaryDirectory ?? Directory.systemTemp,
       _processRunner = processRunner ?? _runProcess,
       _detachedStarter = detachedStarter ?? _startDetached;

  final String platform;
  final String executablePath;
  final Map<String, String> environment;
  final bool developmentMode;
  final Directory temporaryDirectory;
  final ProcessRunner _processRunner;
  final DetachedProcessStarter _detachedStarter;
  final Logger _log = Logger('UpdateInstaller');

  @override
  Directory get updateDirectory =>
      Directory(path.join(temporaryDirectory.path, 'ezshare_update'));

  @override
  Future<({bool ok, String? reason})> canInstall() async {
    if (developmentMode) {
      return (ok: false, reason: 'modo de desenvolvimento');
    }
    if (platform == 'linux' && (environment['APPIMAGE']?.isNotEmpty ?? false)) {
      return (ok: false, reason: 'AppImage');
    }
    final installDirectory = File(executablePath).parent;
    final probe = File(
      path.join(
        installDirectory.path,
        '.ezshare_write_test_${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    try {
      await probe.writeAsString('test', flush: true);
      await probe.delete();
    } catch (_) {
      if (await probe.exists()) {
        try {
          await probe.delete();
        } catch (_) {}
      }
      return (ok: false, reason: 'instalado em local protegido');
    }
    return (ok: true, reason: null);
  }

  @override
  Future<void> prepareAndLaunch(File archive) async {
    final allowed = await canInstall();
    if (!allowed.ok) throw UpdateInstallException(allowed.reason!);
    final root = updateDirectory;
    final staging = Directory(path.join(root.path, 'staging'));
    final backup = Directory(path.join(root.path, 'backup'));
    await root.create(recursive: true);
    await _recreate(staging);
    await _recreate(backup);

    final extraction = platform == 'windows'
        ? await _processRunner('powershell', <String>[
            '-NoProfile',
            '-Command',
            'Expand-Archive -LiteralPath ${_powershellQuote(archive.path)} '
                '-DestinationPath ${_powershellQuote(staging.path)} -Force',
          ])
        : await _processRunner('tar', <String>[
            '-xzf',
            archive.path,
            '-C',
            staging.path,
          ]);
    if (extraction.exitCode != 0) {
      await _deleteTree(root);
      throw UpdateInstallException('Não foi possível extrair a atualização.');
    }

    final executableName = platform == 'windows'
        ? '$appBinaryName.exe'
        : appBinaryName;
    final stagedExecutable = File(path.join(staging.path, executableName));
    if (!await stagedExecutable.exists()) {
      await _deleteTree(root);
      throw UpdateInstallException(
        'O pacote não contém o executável esperado.',
      );
    }

    final installation = File(executablePath).parent;
    await _copyDirectory(installation, backup);
    final processId = pid;
    final script = platform == 'windows'
        ? File(path.join(root.path, 'update.bat'))
        : File(path.join(root.path, 'update.sh'));
    final contents = platform == 'windows'
        ? buildWindowsScript(
            pid: processId,
            stagingPath: staging.path,
            installPath: installation.path,
            backupPath: backup.path,
            executablePath: executablePath,
            logPath: path.join(root.path, 'update.log'),
          )
        : buildLinuxScript(
            pid: processId,
            stagingPath: staging.path,
            installPath: installation.path,
            backupPath: backup.path,
            executablePath: executablePath,
            logPath: path.join(root.path, 'update.log'),
          );
    await script.writeAsString(contents, flush: true);
    if (platform != 'windows') {
      final chmod = await _processRunner('chmod', <String>['+x', script.path]);
      if (chmod.exitCode != 0) {
        throw UpdateInstallException(
          'Não foi possível preparar o instalador auxiliar.',
        );
      }
    }
    _log.info('Script de atualização=${script.path}; PID=$processId');
    if (platform == 'windows') {
      await _detachedStarter('cmd', <String>['/c', script.path, '$processId']);
    } else {
      await _detachedStarter(script.path, <String>['$processId']);
    }
  }

  @override
  Future<String?> consumePreviousLog() async {
    final root = updateDirectory;
    final log = File(path.join(root.path, 'update.log'));
    if (!await log.exists()) return null;
    final result = await log.readAsString();
    _log.info('Resultado da atualização anterior: ${result.trim()}');
    await _deleteTree(root);
    return result;
  }

  @override
  Future<void> openReleasePage(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') {
      throw UpdateInstallException('Link da release inválido.');
    }
    final result = platform == 'windows'
        ? await _processRunner('cmd', <String>['/c', 'start', '', url])
        : await _processRunner('xdg-open', <String>[url]);
    if (result.exitCode != 0) {
      throw UpdateInstallException(
        'Não foi possível abrir a página da release.',
      );
    }
  }
}

String buildLinuxScript({
  required int pid,
  required String stagingPath,
  required String installPath,
  required String backupPath,
  required String executablePath,
  required String logPath,
}) {
  final staging = _shellQuote(stagingPath);
  final install = _shellQuote(installPath);
  final backup = _shellQuote(backupPath);
  final executable = _shellQuote(executablePath);
  final log = _shellQuote(logPath);
  return '''#!/bin/sh
PID="\${1:-$pid}"
LOG=$log
{
count=0
while kill -0 "\$PID" 2>/dev/null && [ "\$count" -lt 60 ]; do
  sleep 1
  count=\$((count + 1))
done
if kill -0 "\$PID" 2>/dev/null; then
  echo "FAILURE: timeout esperando PID $pid"
  RESULT=1
elif cp -a $staging/. $install/; then
  chmod +x $executable
  echo "SUCCESS"
  RESULT=0
else
  echo "FAILURE: cópia; restaurando backup"
  cp -a $backup/. $install/
  RESULT=1
fi
} >"\$LOG" 2>&1
nohup $executable >/dev/null 2>&1 &
exit "\$RESULT"
''';
}

String buildWindowsScript({
  required int pid,
  required String stagingPath,
  required String installPath,
  required String backupPath,
  required String executablePath,
  required String logPath,
}) {
  return '''@echo off
set "PID=%~1"
if "%PID%"=="" set "PID=$pid"
set "LOG=${_batchValue(logPath)}"
call :run > "%LOG%" 2>&1
set "RESULT=%ERRORLEVEL%"
start "" ${_batchQuote(executablePath)}
exit /b %RESULT%
:run
set /a COUNT=0
:waitloop
tasklist /FI "PID eq %PID%" | find "%PID%" >nul
if errorlevel 1 goto copy
if %COUNT% GEQ 60 echo FAILURE: timeout esperando PID $pid & exit /b 1
set /a COUNT+=1
ping 127.0.0.1 -n 2 >nul
goto waitloop
:copy
robocopy ${_batchQuote(stagingPath)} ${_batchQuote(installPath)} /E /R:2 /W:1
if errorlevel 8 goto restore
echo SUCCESS
exit /b 0
:restore
echo FAILURE: copia; restaurando backup
robocopy ${_batchQuote(backupPath)} ${_batchQuote(installPath)} /E /R:2 /W:1
exit /b 1
''';
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
String _powershellQuote(String value) => "'${value.replaceAll("'", "''")}'";
String _batchValue(String value) =>
    value.replaceAll('%', '%%').replaceAll('"', '""');
String _batchQuote(String value) => '"${_batchValue(value)}"';

Future<ProcessResult> _runProcess(String executable, List<String> arguments) {
  return Process.run(executable, arguments);
}

Future<Process> _startDetached(String executable, List<String> arguments) {
  return Process.start(executable, arguments, mode: ProcessStartMode.detached);
}

Future<void> _recreate(Directory directory) async {
  await _deleteTree(directory);
  await directory.create(recursive: true);
}

Future<void> _deleteTree(Directory directory) async {
  if (await directory.exists()) await directory.delete(recursive: true);
}

Future<void> _copyDirectory(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final target = path.join(destination.path, path.basename(entity.path));
    if (entity is Directory) {
      await _copyDirectory(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    } else if (entity is Link) {
      await Link(target).create(await entity.target());
    }
  }
}

class UpdateInstallException implements Exception {
  const UpdateInstallException(this.message);
  final String message;
  @override
  String toString() => message;
}
