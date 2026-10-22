import 'package:camera_cam/core/update_installer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'canInstall rejects development, AppImage and protected locations',
    () async {
      expect(
        (await UpdateInstaller(developmentMode: true).canInstall()).reason,
        'modo de desenvolvimento',
      );
      expect(
        (await UpdateInstaller(
          developmentMode: false,
          platform: 'linux',
          environment: const <String, String>{'APPIMAGE': '/tmp/app.AppImage'},
        ).canInstall()).reason,
        'AppImage',
      );
      expect(
        (await UpdateInstaller(
          developmentMode: false,
          platform: 'linux',
          executablePath: '/proc/1/ezshare_viewer',
          environment: const <String, String>{},
        ).canInstall()).reason,
        'instalado em local protegido',
      );
    },
  );

  test('Linux script includes escaped paths and PID', () {
    final script = buildLinuxScript(
      pid: 123,
      stagingPath: "/tmp/stage with 'quote",
      installPath: '/tmp/install space',
      backupPath: '/tmp/backup',
      executablePath: '/tmp/install space/ezshare_viewer',
      logPath: '/tmp/update log',
    );
    expect(script, contains('123'));
    expect(script, contains("'\"'\"'"));
    expect(script, contains('kill -0'));
    expect(script, contains('cp -a'));
  });

  test('Windows script includes quoted paths, PID and robocopy rollback', () {
    final script = buildWindowsScript(
      pid: 456,
      stagingPath: r'C:\stage with space',
      installPath: r'C:\install "quoted"',
      backupPath: r'C:\backup',
      executablePath: r'C:\install\ezshare_viewer.exe',
      logPath: r'C:\update log',
    );
    expect(script, contains('456'));
    expect(script, contains('"C:\\stage with space"'));
    expect(script, contains('robocopy'));
    expect(script, contains('tasklist'));
  });
}
