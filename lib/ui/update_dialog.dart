import 'dart:async';

import 'package:flutter/material.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update/install_kind.dart';
import 'package:toshiba_flashair_wifi_viewer/state/update_controller.dart';

class UpdateDialog extends StatelessWidget {
  const UpdateDialog({required this.controller, super.key});

  final UpdateController controller;

  @override
  Widget build(BuildContext context) {
    final info = controller.availableUpdate;
    if (info == null) return const SizedBox.shrink();
    final portable =
        controller.installDetection.kind == InstallKind.portable &&
        info.assetUrl != null;
    return AlertDialog(
      title: Text('Nova versão disponível: ${info.tag}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('${controller.currentVersion} → ${info.version}'),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260),
              child: SingleChildScrollView(
                child: SelectableText(
                  info.notes.isEmpty ? 'Sem notas.' : info.notes,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: () => unawaited(controller.openReleasePage()),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Ver no GitHub'),
            ),
            if (!portable)
              Text(
                controller.installDetection.reason ??
                    'Não há pacote compatível com esta plataforma.',
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () {
            controller.remindLater();
            Navigator.pop(context);
          },
          child: const Text('Depois'),
        ),
        if (portable)
          TextButton(
            onPressed: () async {
              await controller.skipThisVersion();
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Ignorar esta versão'),
          ),
        FilledButton.icon(
          onPressed: () {
            Navigator.pop(context);
            if (portable) {
              unawaited(controller.startUpdate());
            } else {
              unawaited(controller.openReleasePage());
            }
          },
          icon: Icon(portable ? Icons.system_update : Icons.download),
          label: Text(portable ? 'Atualizar e reiniciar' : 'Baixar'),
        ),
      ],
    );
  }
}

class UpdateBanner extends StatelessWidget {
  const UpdateBanner({
    required this.controller,
    required this.onOpenUpdate,
    super.key,
  });

  final UpdateController controller;
  final VoidCallback onOpenUpdate;

  @override
  Widget build(BuildContext context) {
    final active = switch (controller.status) {
      UpdateStatus.downloading ||
      UpdateStatus.verifying ||
      UpdateStatus.waitingForTasks ||
      UpdateStatus.installing => true,
      _ => false,
    };
    if (!active &&
        (!controller.bannerVisible || controller.availableUpdate == null)) {
      return const SizedBox.shrink();
    }
    final (message, value, cancellable) = switch (controller.status) {
      UpdateStatus.downloading => (
        _downloadText(controller),
        controller.progress,
        true,
      ),
      UpdateStatus.verifying => ('Verificando…', null, true),
      UpdateStatus.waitingForTasks => ('Aguardando terminar…', null, true),
      UpdateStatus.installing => ('Instalando e reiniciando…', null, false),
      _ => (
        'Atualização ${controller.availableUpdate!.tag} disponível',
        null,
        false,
      ),
    };
    return Material(
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: <Widget>[
            if (active) ...<Widget>[
              SizedBox(
                width: 120,
                child: LinearProgressIndicator(value: value),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(child: Text(message)),
            if (!active)
              TextButton(
                onPressed: onOpenUpdate,
                child: const Text('Atualizar'),
              ),
            if (cancellable)
              TextButton(
                onPressed: controller.cancelUpdate,
                child: const Text('Cancelar'),
              ),
            if (!active)
              TextButton(
                onPressed: controller.closeBanner,
                child: const Text('Fechar'),
              ),
          ],
        ),
      ),
    );
  }
}

String _downloadText(UpdateController controller) {
  final received = _megabytes(controller.receivedBytes);
  final total = controller.totalBytes;
  return total == null
      ? 'Baixando $received MB'
      : 'Baixando $received de ${_megabytes(total)} MB';
}

String _megabytes(int bytes) =>
    (bytes / (1024 * 1024)).toStringAsFixed(1).replaceAll('.', ',');
