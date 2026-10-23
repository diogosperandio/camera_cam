import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

const Color appSnackBarBackgroundColor = Color(0xFF212121);

void showAppSnackBar(
  BuildContext context,
  String message, {
  String? actionLabel,
  VoidCallback? onAction,
  bool isError = false,
}) {
  final messenger = ScaffoldMessenger.of(context);
  final seconds = context.read<AppState>().config.snackBarSeconds.clamp(3, 60);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(color: Colors.white)),
      duration: Duration(seconds: seconds),
      persist: false,
      showCloseIcon: true,
      backgroundColor: appSnackBarBackgroundColor,
      closeIconColor: Colors.white,
      action: actionLabel == null || onAction == null
          ? null
          : SnackBarAction(
              label: actionLabel,
              textColor: Colors.white,
              onPressed: onAction,
            ),
    ),
  );
}
