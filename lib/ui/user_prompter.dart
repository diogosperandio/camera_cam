import 'package:camera_cam/core/user_prompter.dart';
import 'package:flutter/material.dart';

class DialogUserPrompter implements UserPrompter {
  DialogUserPrompter(this.navigatorKey);

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Future<bool> confirmEnableWifi() async {
    final context = navigatorKey.currentContext;
    if (context == null) {
      return false;
    }
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Wi-Fi desligado'),
            content: const Text(
              'O adaptador Wi-Fi está desligado. Deseja ligá-lo para conectar '
              'ao cartão?',
            ),
            actions: <Widget>[
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Agora não'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Ligar Wi-Fi'),
              ),
            ],
          ),
        ) ??
        false;
  }
}
