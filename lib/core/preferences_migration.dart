import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:toshiba_flashair_wifi_viewer/core/app_constants.dart';

class PreferencesMigration {
  PreferencesMigration({
    this.oldSupportDirectory,
    this.newSupportDirectory,
    String? platform,
  }) : _platform = platform ?? Platform.operatingSystem;

  static const String preferencesFileName = 'shared_preferences.json';

  final Directory? oldSupportDirectory;
  final Directory? newSupportDirectory;
  final String _platform;
  final Logger _log = Logger('PreferencesMigration');

  Future<bool> migrateIfNeeded() async {
    final newDirectory =
        newSupportDirectory ?? await getApplicationSupportDirectory();
    final oldDirectory =
        oldSupportDirectory ?? _legacySupportDirectory(newDirectory, _platform);
    final newPreferences = File(
      path.join(newDirectory.path, preferencesFileName),
    );
    final oldPreferences = File(
      path.join(oldDirectory.path, preferencesFileName),
    );

    if (await newPreferences.exists() || !await oldPreferences.exists()) {
      return false;
    }
    await newPreferences.parent.create(recursive: true);
    await oldPreferences.copy(newPreferences.path);
    _log.info(
      'Preferências importadas de ${oldPreferences.path} para '
      '${newPreferences.path}.',
    );
    return true;
  }
}

Directory _legacySupportDirectory(Directory current, String platform) {
  if (platform == 'windows') {
    final roaming = current.parent.parent;
    return Directory(path.join(roaming.path, 'com.example', appName));
  }
  if (platform == 'linux') {
    return Directory(path.join(current.parent.path, 'com.example.$appSlug'));
  }
  return current;
}
