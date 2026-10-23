import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as path;

class UpdateArguments {
  const UpdateArguments({
    required this.pid,
    required this.appDir,
    required this.exeName,
    required this.archive,
    required this.stagingDir,
    required this.logFile,
  });

  final int pid;
  final Directory appDir;
  final String exeName;
  final File archive;
  final Directory stagingDir;
  final File logFile;

  static UpdateArguments parse(List<String> arguments) {
    if (arguments.length != 7 || arguments.first != '--finish-update') {
      throw const FormatException('uso inválido');
    }
    final processId = int.tryParse(arguments[1]);
    if (processId == null || processId <= 0) {
      throw const FormatException('pid inválido');
    }
    if (arguments[3].isEmpty || path.basename(arguments[3]) != arguments[3]) {
      throw const FormatException('nome do executável inválido');
    }
    return UpdateArguments(
      pid: processId,
      appDir: Directory(path.absolute(arguments[2])),
      exeName: arguments[3],
      archive: File(path.absolute(arguments[4])),
      stagingDir: Directory(path.absolute(arguments[5])),
      logFile: File(path.absolute(arguments[6])),
    );
  }
}

typedef PidAlive = Future<bool> Function(int pid);
typedef Delay = Future<void> Function(Duration duration);
typedef Restarter = Future<void> Function(
  String executable,
  Map<String, String> environment,
);
typedef FileCopier = Future<File> Function(File source, String destination);

Future<int> runUpdater(
  List<String> arguments, {
  String? helperPath,
  PidAlive? pidAlive,
  Delay delay = Future<void>.delayed,
  Duration waitTimeout = const Duration(seconds: 60),
  Restarter? restarter,
  FileCopier? copyFile,
}) async {
  UpdateArguments parsed;
  try {
    parsed = UpdateArguments.parse(arguments);
  } catch (_) {
    return 64;
  }

  IOSink? log;
  var validated = false;
  var success = false;
  var preserveBackup = false;
  var createdFiles = <File>[];
  try {
    await parsed.logFile.parent.create(recursive: true);
    log = parsed.logFile.openWrite(mode: FileMode.write);
    void step(String message) =>
        log!.writeln('${DateTime.now().toIso8601String()} $message');
    step('Início da atualização; PID=${parsed.pid}');
    final updatesDir = await _validate(
      parsed,
      helperPath ?? Platform.resolvedExecutable,
    );
    validated = true;
    step('Validações concluídas; updates=${updatesDir.path}');
    final backup = Directory(path.join(parsed.stagingDir.path, 'backup'));
    if (await backup.exists()) {
      preserveBackup = true;
      throw UpdateFailure(
        'há arquivos de uma atualização anterior que falhou em ${backup.path}',
      );
    }

    final alive = pidAlive ?? _isPidAlive;
    final deadline = DateTime.now().add(waitTimeout);
    while (await alive(parsed.pid)) {
      if (!DateTime.now().isBefore(deadline)) {
        throw const UpdateFailure(
          'tempo esgotado esperando o aplicativo fechar',
        );
      }
      await delay(const Duration(milliseconds: 100));
    }
    step('Aplicativo fechado');
    final unpacked = Directory(path.join(parsed.stagingDir.path, 'unpacked'));
    await unpacked.create(recursive: true);
    await _extract(parsed.archive, unpacked);
    final source = await _bundleRoot(unpacked);
    final helperName = Platform.isWindows
        ? 'toshiba_flashair_wifi_viewer_updater.exe'
        : 'toshiba_flashair_wifi_viewer_updater';
    for (final requiredName in <String>[
      parsed.exeName,
      'portable.txt',
      helperName,
    ]) {
      if (!await File(path.join(source.path, requiredName)).exists()) {
        throw UpdateFailure('o pacote não contém $requiredName');
      }
    }
    step('Pacote extraído e validado');
    createdFiles = await _replace(
      source,
      parsed.appDir,
      backup,
      step,
      copyFile ?? (source, destination) => source.copy(destination),
    );
    if (!Platform.isWindows) {
      for (final name in <String>[parsed.exeName, helperName]) {
        final result = await Process.run('chmod', <String>[
          '755',
          path.join(parsed.appDir.path, name),
        ]);
        if (result.exitCode != 0) {
          throw UpdateFailure('chmod falhou para $name');
        }
      }
    }
    success = true;
    step('OK');
  } catch (error, stack) {
    log ??= parsed.logFile.openWrite(mode: FileMode.write);
    log.writeln('ERRO: $error');
    log.writeln(stack);
    final backup = Directory(path.join(parsed.stagingDir.path, 'backup'));
    for (final file in createdFiles.reversed) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    if (await backup.exists()) {
      try {
        await _restore(backup, parsed.appDir);
        log.writeln('Originais restaurados');
      } catch (restoreError) {
        final recovery = Directory(
          '${parsed.stagingDir.path}-recuperacao-${DateTime.now().millisecondsSinceEpoch}',
        );
        await backup.rename(recovery.path);
        preserveBackup = true;
        log.writeln(
          'Falha na restauração; arquivos preservados em ${recovery.path}: $restoreError',
        );
      }
    }
  } finally {
    if (validated) {
      try {
        if (await parsed.archive.exists()) await parsed.archive.delete();
        if (!preserveBackup && await parsed.stagingDir.exists()) {
          await parsed.stagingDir.delete(recursive: true);
        }
      } catch (cleanupError) {
        log?.writeln('Falha na limpeza: $cleanupError');
      }
      try {
        final environment = Map<String, String>.of(Platform.environment)
          ..remove('TOSHIBA_FLASHAIR_WIFI_VIEWER_PRETEND_VERSION');
        final executable = path.join(parsed.appDir.path, parsed.exeName);
        if (restarter != null) {
          await restarter(executable, environment);
        } else {
          await Process.start(
            executable,
            const <String>[],
            mode: ProcessStartMode.detached,
            environment: environment,
            includeParentEnvironment: false,
          );
        }
        log?.writeln('Aplicativo reaberto');
      } catch (restartError) {
        log?.writeln('Falha ao reabrir: $restartError');
      }
    }
    await log?.flush();
    await log?.close();
  }
  return success ? 0 : 1;
}

Future<Directory> _validate(UpdateArguments args, String helperPath) async {
  if (!await File(path.join(args.appDir.path, 'portable.txt')).exists() ||
      !await File(path.join(args.appDir.path, args.exeName)).exists()) {
    throw const UpdateFailure('instalação portátil inválida');
  }
  final helper = File(helperPath);
  final helperCanonical = await helper.resolveSymbolicLinks();
  final helperDir = File(helperCanonical).parent;
  if (path.basename(helperDir.path) != 'helper' ||
      path.basename(helperDir.parent.path) != 'updates') {
    throw const UpdateFailure('o auxiliar não está em <cache>/updates/helper');
  }
  final updates = Directory(await helperDir.parent.resolveSymbolicLinks());
  final archiveCanonical = await args.archive.resolveSymbolicLinks();
  if (!_inside(updates.path, archiveCanonical)) {
    throw const UpdateFailure('arquivo baixado fora de <cache>/updates');
  }
  final stagingParent = args.stagingDir.parent;
  final parentCanonical = await stagingParent.resolveSymbolicLinks();
  final stagingCanonical = path.join(
    parentCanonical,
    path.basename(args.stagingDir.path),
  );
  if (!_inside(updates.path, stagingCanonical)) {
    throw const UpdateFailure('staging fora de <cache>/updates');
  }
  return updates;
}

bool _inside(String parent, String child) {
  final relative = path.relative(
    path.normalize(child),
    from: path.normalize(parent),
  );
  return relative != '..' &&
      !relative.startsWith('..${path.separator}') &&
      !path.isAbsolute(relative);
}

Future<bool> _isPidAlive(int processId) async {
  if (Platform.isLinux) return Directory('/proc/$processId').exists();
  if (Platform.isWindows) {
    final result = await Process.run('tasklist', <String>[
      '/FI',
      'PID eq $processId',
      '/NH',
    ]);
    return result.exitCode == 0 &&
        result.stdout.toString().contains(RegExp('\\b$processId\\b'));
  }
  return false;
}

Future<void> _extract(File source, Directory output) async {
  final bytes = await source.readAsBytes();
  final Archive archive;
  if (source.path.endsWith('.zip')) {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
  } else if (source.path.endsWith('.tar.gz')) {
    archive = TarDecoder().decodeBytes(
      GZipDecoder().decodeBytes(bytes, verify: true),
      verify: true,
    );
  } else {
    throw const UpdateFailure('formato de pacote não aceito');
  }
  for (final entry in archive) {
    final normalized = path.posix.normalize(entry.name.replaceAll('\\', '/'));
    final segments = path.posix.split(normalized);
    if (path.posix.isAbsolute(entry.name) ||
        path.windows.isAbsolute(entry.name) ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        segments.contains('..') ||
        entry.isSymbolicLink) {
      throw UpdateFailure('entrada insegura no pacote: ${entry.name}');
    }
    final target = path.joinAll(<String>[output.path, ...segments]);
    if (entry.isDirectory) {
      await Directory(target).create(recursive: true);
    } else {
      final file = File(target);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(entry.content, flush: true);
    }
  }
}

Future<Directory> _bundleRoot(Directory unpacked) async {
  final entries = await unpacked.list(followLinks: false).toList();
  return entries.length == 1 && entries.single is Directory
      ? entries.single as Directory
      : unpacked;
}

Future<List<File>> _replace(
  Directory source,
  Directory destination,
  Directory backup,
  void Function(String message) log,
  FileCopier copyFile,
) async {
  final created = <File>[];
  try {
    await for (final entity in source.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = path.relative(entity.path, from: source.path);
      final targetPath = path.join(destination.path, relative);
      if (entity is Directory) {
        await Directory(targetPath).create(recursive: true);
      } else if (entity is File) {
        final target = File(targetPath);
        if (await target.exists()) {
          final saved = File(path.join(backup.path, relative));
          await saved.parent.create(recursive: true);
          await target.copy(saved.path);
        } else {
          created.add(target);
        }
        await target.parent.create(recursive: true);
        await copyFile(entity, target.path);
        log('Copiado $relative');
      }
    }
  } catch (_) {
    for (final file in created.reversed) {
      if (await file.exists()) await file.delete();
    }
    rethrow;
  }
  return created;
}

Future<void> _restore(Directory backup, Directory destination) async {
  await for (final entity in backup.list(recursive: true, followLinks: false)) {
    final relative = path.relative(entity.path, from: backup.path);
    final target = path.join(destination.path, relative);
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      await File(target).parent.create(recursive: true);
      await entity.copy(target);
    }
  }
}

class UpdateFailure implements Exception {
  const UpdateFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
