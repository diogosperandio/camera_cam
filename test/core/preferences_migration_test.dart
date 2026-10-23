import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:toshiba_flashair_wifi_viewer/core/preferences_migration.dart';

void main() {
  late Directory root;
  late Directory oldDirectory;
  late Directory newDirectory;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('preferences_migration_');
    oldDirectory = Directory(path.join(root.path, 'old'));
    newDirectory = Directory(path.join(root.path, 'new'));
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('copies preferences when only the old file exists', () async {
    final oldFile = File(
      path.join(oldDirectory.path, PreferencesMigration.preferencesFileName),
    );
    await oldFile.create(recursive: true);
    await oldFile.writeAsString('{"flutter.app_config":"old"}');
    final migration = PreferencesMigration(
      oldSupportDirectory: oldDirectory,
      newSupportDirectory: newDirectory,
    );

    expect(await migration.migrateIfNeeded(), isTrue);
    expect(
      await File(
        path.join(newDirectory.path, PreferencesMigration.preferencesFileName),
      ).readAsString(),
      '{"flutter.app_config":"old"}',
    );
    expect(await oldFile.exists(), isTrue);
  });

  test('does not touch either file when the new file already exists', () async {
    final oldFile = File(
      path.join(oldDirectory.path, PreferencesMigration.preferencesFileName),
    );
    final newFile = File(
      path.join(newDirectory.path, PreferencesMigration.preferencesFileName),
    );
    await oldFile.create(recursive: true);
    await oldFile.writeAsString('old');
    await newFile.create(recursive: true);
    await newFile.writeAsString('new');
    final migration = PreferencesMigration(
      oldSupportDirectory: oldDirectory,
      newSupportDirectory: newDirectory,
    );

    expect(await migration.migrateIfNeeded(), isFalse);
    expect(await newFile.readAsString(), 'new');
    expect(await oldFile.readAsString(), 'old');
  });
}
