import 'package:camera_cam/state/app_state.dart';
import 'package:camera_cam/state/update_controller.dart';
import 'package:flutter/material.dart';

class CameraToolbar extends StatelessWidget {
  const CameraToolbar({
    required this.state,
    required this.onConnect,
    required this.onDisconnect,
    required this.onRefresh,
    required this.onSettings,
    this.updateController,
    this.onOpenUpdate,
    super.key,
  });

  final AppState state;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;
  final VoidCallback? onRefresh;
  final VoidCallback onSettings;
  final UpdateController? updateController;
  final VoidCallback? onOpenUpdate;

  @override
  Widget build(BuildContext context) {
    final actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: <Widget>[
        FilledButton.icon(
          onPressed: onConnect,
          icon: const Icon(Icons.wifi),
          label: const Text('Conectar'),
        ),
        OutlinedButton.icon(
          onPressed: onDisconnect,
          icon: const Icon(Icons.wifi_off),
          label: const Text('Desconectar'),
        ),
        if (updateController?.status == UpdateStatus.available)
          ActionChip(
            avatar: const Icon(Icons.system_update, size: 18),
            label: Text(
              'Atualização v${updateController!.availableUpdate!.version}',
            ),
            onPressed: onOpenUpdate,
          ),
        OutlinedButton.icon(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh),
          label: const Text('Atualizar'),
        ),
        IconButton(
          onPressed: onSettings,
          tooltip: 'Configurações',
          icon: const Icon(Icons.settings),
        ),
      ],
    );
    final status = _ConnectionStatus(state: state);

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 850) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: <Widget>[
                      actions,
                      const SizedBox(width: 16),
                      status,
                    ],
                  ),
                );
              }
              return Row(
                children: <Widget>[
                  actions,
                  const Spacer(),
                  Flexible(child: status),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final (statusColor, statusText) = switch (state.connection) {
      ConnectionStatus.disconnected => (Colors.grey, 'Desconectado'),
      ConnectionStatus.connecting => (Colors.orange, 'Conectando'),
      ConnectionStatus.connected => (Colors.green, 'Conectado'),
      ConnectionStatus.error => (colorScheme.error, 'Erro'),
    };
    final ssid = state.config.ssid?.trim();
    final deletionAvailable =
        state.connection == ConnectionStatus.connected &&
        state.uploadEnabled == true;

    return Wrap(
      spacing: 10,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.end,
      children: <Widget>[
        Semantics(
          label: 'Status da conexão: $statusText',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 260),
                child: Text(
                  '${ssid == null || ssid.isEmpty ? 'Sem rede' : ssid} · '
                  '$statusText',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        if (state.config.deleteEnabled)
          Tooltip(
            message: deletionAvailable ? 'Exclusão habilitada pelo cartão.' : 'O cartão precisa estar conectado e configurado com UPLOAD=1.',
            child: Chip(
              avatar: Icon(
                deletionAvailable ? Icons.check_circle : Icons.block,
                size: 18,
                color: deletionAvailable
                    ? Colors.green.shade800
                    : colorScheme.onSurfaceVariant,
              ),
              label: Text(
                deletionAvailable ? 'Apagar: liberado' : 'Apagar: indisponível',
              ),
              backgroundColor: deletionAvailable
                  ? Colors.green.shade100
                  : colorScheme.surfaceContainerHighest,
              side: BorderSide.none,
            ),
          ),
      ],
    );
  }
}
