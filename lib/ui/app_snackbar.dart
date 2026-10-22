import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

void showAppSnackBar(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  bool isError = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final seconds = context.read<AppState>().config.snackBarSeconds.clamp(3, 60);
  final colorScheme = Theme.of(context).colorScheme;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: Duration(seconds: seconds),
      persist: false,
      showCloseIcon: true,
      backgroundColor: isError ? colorScheme.errorContainer : null,
      closeIconColor: isError ? colorScheme.onErrorContainer : null,
      action: actionLabel == null || onAction == null
          ? null
          : SnackBarAction(label: actionLabel, onPressed: onAction),
    ),
  );
}
