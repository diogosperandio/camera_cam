import 'dart:io';

import 'package:toshiba_flashair_wifi_viewer/core/log_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  test('writes log records to the application support directory', () async {
    final directory = await Directory.systemTemp.createTemp('camera_cam_log_');
    try {
      await AppLog.initialize(supportDirectory: directory);
      Logger('Test').info('registro de teste sem senha');
      final logPath = AppLog.filePath;

      await AppLog.close();

      expect(logPath, isNotNull);
      final contents = await File(logPath!).readAsString();
      expect(contents, contains('[Test] registro de teste sem senha'));
      expect(contents, contains('[App] Logging iniciado'));
    } finally {
      await AppLog.close();
      await directory.delete(recursive: true);
    }
  });
}
