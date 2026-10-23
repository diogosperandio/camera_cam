import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:toshiba_flashair_wifi_viewer/core/update/install_kind.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update_installer.dart';

void main() {
  late Directory temporary;

  setUp(() async => temporary = await Directory.systemTemp.createTemp('install_kind_test_'));
  tearDown(() async {
    if (await temporary.exists()) {
      if (!Platform.isWindows) await Process.run('chmod', <String>['755', temporary.path]);
      await temporary.delete(recursive: true);
    }
  });

  test('detectInstall rejects development mode', () async {
    final result = await detectInstall(developmentMode: true);
    expect(result.kind, InstallKind.unsupported);
    expect(result.reason, 'modo de desenvolvimento');
  });

  test('detectInstall requires portable marker and helper', () async {
    final executable = File(path.join(temporary.path, 'ezshare_viewer'))..writeAsStringSync('app');
    var result = await detectInstall(developmentMode: false, platform: 'linux', executablePath: executable.path);
    expect(result.reason, 'instalação sem portable.txt');
    File(path.join(temporary.path, 'portable.txt')).writeAsStringSync('portable');
    result = await detectInstall(developmentMode: false, platform: 'linux', executablePath: executable.path);
    expect(result.reason, 'auxiliar ausente');
    File(path.join(temporary.path, 'ezshare_updater')).writeAsStringSync('helper');
    result = await detectInstall(developmentMode: false, platform: 'linux', executablePath: executable.path);
    expect(result.kind, InstallKind.portable);
  });

  test('detectInstall reports a folder without write permission', () async {
    if (Platform.isWindows) return;
    final executable = File(path.join(temporary.path, 'ezshare_viewer'))..writeAsStringSync('app');
    File(path.join(temporary.path, 'portable.txt')).writeAsStringSync('portable');
    File(path.join(temporary.path, 'ezshare_updater')).writeAsStringSync('helper');
    await Process.run('chmod', <String>['555', temporary.path]);
    final result = await detectInstall(developmentMode: false, platform: 'linux', executablePath: executable.path);
    expect(result.reason, 'pasta sem permissão de escrita');
  });

  test('pretend version overrides only when valid', () {
    expect(
      effectiveCurrentVersion('1.2.3', environment: const <String, String>{'EZSHARE_PRETEND_VERSION': '1.0.0'}),
      '1.0.0',
    );
    expect(
      effectiveCurrentVersion('1.2.3', environment: const <String, String>{'EZSHARE_PRETEND_VERSION': 'latest'}),
      '1.2.3',
    );
  });

  test('a failed helper log clears the anti-loop marker', () async {
    final installer = UpdateInstaller(cacheDirectory: temporary);
    await installer.markerFile.parent.create(recursive: true);
    await installer.markerFile.writeAsString('v2.0.0\n2026-10-23T12:00:00\n');
    await installer.logFile.writeAsString('ERRO: falha de cópia');
    expect(await installer.consumePreviousLog(), contains('ERRO'));
    expect(await installer.markerFile.exists(), isFalse);
    expect(await installer.logFile.exists(), isFalse);
  });
}
