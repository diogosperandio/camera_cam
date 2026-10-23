import 'dart:io';

import 'package:archive/archive.dart';
import 'package:ezshare_updater/updater.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('parser', () {
    test('rejects missing, extra, invalid pid and wrong flag', () {
      expect(
        () => UpdateArguments.parse(const <String>[]),
        throwsFormatException,
      );
      expect(
        () => UpdateArguments.parse(<String>[
          '--finish-update',
          ...List<String>.filled(7, 'x'),
        ]),
        throwsFormatException,
      );
      expect(
        () => UpdateArguments.parse(const <String>[
          '--finish-update',
          'x',
          'a',
          'e',
          'f',
          's',
          'l',
        ]),
        throwsFormatException,
      );
      expect(
        () => UpdateArguments.parse(const <String>[
          '--wrong',
          '1',
          'a',
          'e',
          'f',
          's',
          'l',
        ]),
        throwsFormatException,
      );
    });
  });

  group('update', () {
    late _Fixture fixture;
    setUp(() async => fixture = await _Fixture.create());
    tearDown(() async => fixture.dispose());

    test(
      'rejects archive outside updates and missing portable marker',
      () async {
        final outside = File(path.join(fixture.root.path, 'outside.zip'));
        await fixture.writePackage(outside);
        expect(await fixture.run(archive: outside), 1);

        await fixture.writePackage(fixture.archive);
        await fixture.portable.delete();
        expect(await fixture.run(), 1);
        expect(await fixture.executable.readAsString(), 'old');
      },
    );

    test('timeout changes nothing', () async {
      await fixture.writePackage(fixture.archive);
      expect(
        await fixture.run(
          pidAlive: (_) async => true,
          waitTimeout: Duration.zero,
        ),
        1,
      );
      expect(await fixture.executable.readAsString(), 'old');
    });

    test('rejects traversal and package without executable', () async {
      await fixture.writeEntries(fixture.archive, <ArchiveFile>[
        ArchiveFile.string('../escape', 'bad'),
      ]);
      expect(await fixture.run(), 1);
      expect(
        File(path.join(fixture.root.path, 'escape')).existsSync(),
        isFalse,
      );

      await fixture.resetArchive();
      await fixture.writeEntries(fixture.archive, <ArchiveFile>[
        ArchiveFile.string('portable.txt', 'ok'),
        ArchiveFile.string('ezshare_updater', 'helper'),
      ]);
      expect(await fixture.run(), 1);
      expect(await fixture.executable.readAsString(), 'old');
    });

    test(
      'successful replacement preserves user extras and cleans temporary files',
      () async {
        final extra = File(path.join(fixture.app.path, 'user.txt'))
          ..writeAsStringSync('keep');
        await fixture.writePackage(
          fixture.archive,
          extraEntries: <ArchiveFile>[
            ArchiveFile.string('sub/novo.txt', 'novo'),
          ],
        );
        expect(await fixture.run(), 0);
        expect(await fixture.executable.readAsString(), 'new');
        expect(await extra.readAsString(), 'keep');
        expect(
          File(path.join(fixture.app.path, 'sub', 'novo.txt')).existsSync(),
          isTrue,
        );
        if (Platform.isLinux) {
          final mode = await Process.run('stat', <String>[
            '-c',
            '%a',
            fixture.executable.path,
          ]);
          expect(mode.stdout.toString().trim(), '755');
        }
        expect(fixture.archive.existsSync(), isFalse);
        expect(fixture.staging.existsSync(), isFalse);
      },
    );

    test('refuses an existing backup and does not delete it', () async {
      await fixture.writePackage(fixture.archive);
      final backupFile = File(
        path.join(fixture.staging.path, 'backup', 'important'),
      );
      backupFile.createSync(recursive: true);
      backupFile.writeAsStringSync('preserve');
      expect(await fixture.run(), 1);
      expect(backupFile.existsSync(), isTrue);
      expect(await fixture.executable.readAsString(), 'old');
    });

    test('failure during copy restores every original', () async {
      await fixture.writePackage(fixture.archive);
      expect(
        await fixture.run(
          copyFile: (source, destination) async {
            if (path.basename(source.path) == 'portable.txt') {
              throw const FileSystemException('simulated copy failure');
            }
            return source.copy(destination);
          },
        ),
        1,
      );
      expect(await fixture.executable.readAsString(), 'old');
      expect(await fixture.portable.readAsString(), 'portable');
    });

    test('paths with spaces and accents work', () async {
      await fixture.writePackage(fixture.archive);
      expect(await fixture.run(), 0);
      expect(await fixture.executable.readAsString(), 'new');
    });
  });
}

class _Fixture {
  _Fixture(
    this.root,
    this.updates,
    this.app,
    this.helper,
    this.archive,
    this.staging,
    this.log,
    this.executable,
    this.portable,
  );

  final Directory root;
  final Directory updates;
  final Directory app;
  final File helper;
  final File archive;
  final Directory staging;
  final File log;
  final File executable;
  final File portable;

  static Future<_Fixture> create() async {
    final root = await Directory.systemTemp.createTemp(
      'atualização com acento á ',
    );
    final updates = Directory(path.join(root.path, 'cache', 'updates'))
      ..createSync(recursive: true);
    final helper = File(path.join(updates.path, 'helper', 'ezshare_updater'))
      ..createSync(recursive: true)
      ..writeAsStringSync('helper');
    final app = Directory(path.join(root.path, 'Aplicativo com espaço'))
      ..createSync();
    final executable = File(path.join(app.path, 'ezshare_viewer'))
      ..writeAsStringSync('old');
    final portable = File(path.join(app.path, 'portable.txt'))
      ..writeAsStringSync('portable');
    File(path.join(app.path, 'ezshare_updater'))
        .writeAsStringSync('old helper');
    return _Fixture(
      root,
      updates,
      app,
      helper,
      File(path.join(updates.path, 'pacote.zip')),
      Directory(path.join(updates.path, 'preparação á')),
      File(path.join(updates.path, 'update.log')),
      executable,
      portable,
    );
  }

  Future<int> run({
    File? archive,
    Future<bool> Function(int)? pidAlive,
    Duration waitTimeout = const Duration(milliseconds: 10),
    FileCopier? copyFile,
  }) => runUpdater(
    <String>[
      '--finish-update',
      '999999',
      app.path,
      'ezshare_viewer',
      (archive ?? this.archive).path,
      staging.path,
      log.path,
    ],
    helperPath: helper.path,
    pidAlive: pidAlive ?? (_) async => false,
    waitTimeout: waitTimeout,
    delay: (_) async {},
    restarter: (_, environment) async {
      expect(environment.containsKey('EZSHARE_PRETEND_VERSION'), isFalse);
    },
    copyFile: copyFile,
  );

  Future<void> writePackage(
    File target, {
    List<ArchiveFile> extraEntries = const <ArchiveFile>[],
  }) => writeEntries(target, <ArchiveFile>[
    ArchiveFile.string('ezshare_viewer', 'new'),
    ArchiveFile.string('portable.txt', 'portable'),
    ArchiveFile.string('ezshare_updater', 'new helper'),
    ...extraEntries,
  ]);

  Future<void> writeEntries(File target, List<ArchiveFile> entries) async {
    final archiveData = Archive();
    for (final entry in entries) {
      archiveData.addFile(entry);
    }
    await target.parent.create(recursive: true);
    await target.writeAsBytes(
      ZipEncoder().encodeBytes(archiveData),
      flush: true,
    );
  }

  Future<void> resetArchive() async {
    if (await archive.exists()) await archive.delete();
    if (await staging.exists()) await staging.delete(recursive: true);
    await portable.writeAsString('portable');
  }

  Future<void> dispose() async {
    if (await root.exists()) await root.delete(recursive: true);
  }
}
