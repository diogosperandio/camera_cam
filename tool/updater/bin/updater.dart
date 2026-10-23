import 'dart:io';

import 'package:toshiba_flashair_wifi_viewer_updater/updater.dart';

Future<void> main(List<String> arguments) async {
  final code = await runUpdater(arguments);
  exitCode = code;
}
