import 'dart:async';

import 'package:camera_cam/state/update_controller.dart';
import 'package:flutter/material.dart';

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({required this.controller, super.key});

  final UpdateController controller;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  late Future<({bool ok, String? reason})> _installationCheck;

  @override
  void initState() {
    super.initState();
    _installationCheck = widget.controller.canInstall();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final updating = switch (controller.status) {
          UpdateStatus.downloading ||
          UpdateStatus.verifying ||
          UpdateStatus.readyToInstall ||
          UpdateStatus.installing => true,
          _ => false,
        };
        if (updating) return _progressDialog(controller);
        final info = controller.availableUpdate;
        if (info == null) {
          return AlertDialog(
            title: const Text('Atualização'),
            content: Text(
              controller.errorMessage ?? 'Atualização indisponível.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Fechar'),
              ),
            ],
          );
        }
        return AlertDialog(
          title: Text('Atualização v${info.version}'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Versão atual: ${controller.currentVersion} → ${info.version}',
                ),
                const SizedBox(height: 16),
                const Text('Notas da versão:'),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      info.notes.isEmpty ? 'Sem notas.' : info.notes,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FutureBuilder<({bool ok, String? reason})>(
                  future: _installationCheck,
                  builder: (context, snapshot) {
                    final noAsset = info.assetUrl == null;
                    final reason = noAsset
                        ? 'Não há pacote compatível com esta plataforma.'
                        : snapshot.data?.reason;
                    return reason == null
                        ? const SizedBox.shrink()
                        : Text(reason);
                  },
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () {
                controller.remindLater();
                Navigator.of(context).pop();
              },
              child: const Text('Lembrar depois'),
            ),
            TextButton(
              onPressed: () async {
                await controller.skipThisVersion();
                if (context.mounted) Navigator.of(context).pop();
              },
              child: const Text('Ignorar esta versão'),
            ),
            FutureBuilder<({bool ok, String? reason})>(
              future: _installationCheck,
              builder: (context, snapshot) {
                final canInstall =
                    snapshot.data?.ok == true && info.assetUrl != null;
                return FilledButton.icon(
                  onPressed: snapshot.connectionState != ConnectionState.done
                      ? null
                      : canInstall
                      ? () => unawaited(controller.startUpdate())
                      : () => unawaited(controller.openReleasePage()),
                  icon: Icon(
                    canInstall ? Icons.system_update : Icons.open_in_new,
                  ),
                  label: Text(
                    canInstall ? 'Atualizar agora' : 'Baixar manualmente',
                  ),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Widget _progressDialog(UpdateController controller) {
    final (message, value, cancellable) = switch (controller.status) {
      UpdateStatus.downloading => (
        'Baixando atualização…',
        controller.progress,
        true,
      ),
      UpdateStatus.verifying => ('Verificando integridade…', null, true),
      UpdateStatus.readyToInstall => ('Preparando instalação…', null, true),
      UpdateStatus.installing => ('O app vai reiniciar.', null, false),
      _ => ('Preparando…', null, false),
    };
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Atualizando'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(message),
              const SizedBox(height: 16),
              LinearProgressIndicator(value: value),
              if (value != null) ...<Widget>[
                const SizedBox(height: 8),
                Text('${(value * 100).clamp(0, 100).round()}%'),
              ],
            ],
          ),
        ),
        actions: cancellable
            ? <Widget>[
                TextButton(
                  onPressed: controller.cancelUpdate,
                  child: const Text('Cancelar'),
                ),
              ]
            : null,
      ),
    );
  }
}
