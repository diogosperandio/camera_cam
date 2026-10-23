import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:toshiba_flashair_wifi_viewer/core/version_utils.dart';

enum InstallKind { portable, unsupported }

typedef InstallDetection = (InstallKind, String?);

extension InstallDetectionFields on InstallDetection {
  InstallKind get kind => $1;
  String? get reason => $2;
}

Future<InstallDetection> detectInstall({
  String? executablePath,
  String? platform,
  bool? developmentMode,
}) async {
  if (developmentMode ?? (kDebugMode || kProfileMode)) {
    return (InstallKind.unsupported, 'modo de desenvolvimento');
  }
  final appDir = File(executablePath ?? Platform.resolvedExecutable).parent;
  if (!await File(path.join(appDir.path, 'portable.txt')).exists()) {
    return (InstallKind.unsupported, 'instalação sem portable.txt');
  }
  final helperName = (platform ?? Platform.operatingSystem) == 'windows'
      ? 'ezshare_updater.exe'
      : 'ezshare_updater';
  if (!await File(path.join(appDir.path, helperName)).exists()) {
    return (InstallKind.unsupported, 'auxiliar ausente');
  }
  final probe = File(
    path.join(
      appDir.path,
      '.ezshare_write_test_${DateTime.now().microsecondsSinceEpoch}',
    ),
  );
  try {
    await probe.writeAsString('test', flush: true);
    await probe.delete();
  } catch (_) {
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {}
    return (InstallKind.unsupported, 'pasta sem permissão de escrita');
  }
  return (InstallKind.portable, null);
}

String effectiveCurrentVersion(
  String packageVersion, {
  Map<String, String>? environment,
}) {
  final pretend =
      (environment ?? Platform.environment)['EZSHARE_PRETEND_VERSION'];
  return parseVersion(pretend ?? '')?.toString() ?? packageVersion;
}
