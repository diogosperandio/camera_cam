import 'dart:io';

import 'package:ezshare_updater/updater.dart';

Future<void> main(List<String> arguments) async {
  final code = await runUpdater(arguments);
  exitCode = code;
}
