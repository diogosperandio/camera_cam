import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:toshiba_flashair_wifi_viewer/core/app_constants.dart';

class AppLog {
  AppLog._();

  static StreamSubscription<LogRecord>? _subscription;
  static Future<void> _pendingWrite = Future<void>.value();
  static File? _file;

  static String? get filePath => _file?.path;

  static Future<void> initialize({Directory? supportDirectory}) async {
    await close();
    final directory =
        supportDirectory ?? await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    _file = File(path.join(directory.path, '$appSlug.log'));
    Logger.root.level = Level.ALL;
    _subscription = Logger.root.onRecord.listen(_writeRecord);
    Logger('App').info('Logging iniciado em ${_file!.path}');
  }

  static Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    await _pendingWrite;
    _file = null;
  }

  static void _writeRecord(LogRecord record) {
    final file = _file;
    if (file == null) {
      return;
    }
    final error = record.error == null ? '' : ' | erro=${record.error}';
    final line =
        '${record.time.toIso8601String()} '
        '${record.level.name.padRight(7)} '
        '[${record.loggerName}] ${record.message}$error\n';
    _pendingWrite = _pendingWrite.then((_) async {
      try {
        await file.writeAsString(line, mode: FileMode.append, flush: true);
      } catch (_) {
        // Uma falha de log nunca deve interromper o aplicativo.
      }
    });
  }
}
