import 'dart:async';

import 'package:camera_cam/core/card_client.dart';
import 'package:camera_cam/models/card_item.dart';
import 'package:camera_cam/state/app_state.dart';
import 'package:flutter/material.dart';

Future<void> showEmptyFoldersDialog(BuildContext context, AppState state) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _EmptyFoldersDialog(state: state),
  );
}

class _EmptyFoldersDialog extends StatefulWidget {
  const _EmptyFoldersDialog({required this.state});

  final AppState state;

  @override
  State<_EmptyFoldersDialog> createState() => _EmptyFoldersDialogState();
}

class _EmptyFoldersDialogState extends State<_EmptyFoldersDialog> {
  final CancelToken _cancelToken = CancelToken();
  final Set<String> _selectedPaths = <String>{};
  bool _scanFinished = false;
  bool _deleting = false;
  FolderDeletionSummary? _summary;

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_stateChanged);
    unawaited(_scan());
  }

  @override
  void dispose() {
    _cancelToken.cancel();
    widget.state.removeListener(_stateChanged);
    super.dispose();
  }

  void _stateChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _scan() async {
    final folders = await widget.state.scanEmptyFolders(cancel: _cancelToken);
    if (!mounted || _cancelToken.isCancelled) {
      return;
    }
    setState(() {
      _selectedPaths.addAll(
        folders
            .where((folder) => folder.name.toUpperCase() != '100__TSB')
            .map((folder) => folder.fullPath),
      );
      _scanFinished = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final progress = widget.state.scanProgress;
    final folders = widget.state.emptyFolders;
    return AlertDialog(
      title: const Text('Limpar pastas vazias'),
      content: SizedBox(
        width: 560,
        child: _summary != null
            ? _Summary(summary: _summary!)
            : _deleting
            ? const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('Apagando as pastas selecionadas…'),
                  SizedBox(height: 16),
                  LinearProgressIndicator(),
                ],
              )
            : !_scanFinished
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text('Verificando pastas ${progress.done}/${progress.total}'),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(
                    value: progress.total == 0
                        ? null
                        : progress.done / progress.total,
                  ),
                ],
              )
            : folders.isEmpty
            ? const Text('Nenhuma pasta vazia encontrada.')
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 380),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: folders.length,
                  itemBuilder: (context, index) {
                    final folder = folders[index];
                    final isFactoryFolder =
                        folder.name.toUpperCase() == '100__TSB';
                    return CheckboxListTile(
                      value: _selectedPaths.contains(folder.fullPath),
                      onChanged: (selected) {
                        setState(() {
                          if (selected ?? false) {
                            _selectedPaths.add(folder.fullPath);
                          } else {
                            _selectedPaths.remove(folder.fullPath);
                          }
                        });
                      },
                      title: Text(folder.fullPath),
                      subtitle: isFactoryFolder
                          ? const Text('pasta de fábrica do cartão')
                          : null,
                      controlAffinity: ListTileControlAffinity.leading,
                    );
                  },
                ),
              ),
      ),
      actions: _buildActions(context, folders),
    );
  }

  List<Widget> _buildActions(BuildContext context, List<CardItem> folders) {
    if (_summary != null) {
      return <Widget>[
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Fechar'),
        ),
      ];
    }
    if (_deleting) {
      return const <Widget>[];
    }
    if (!_scanFinished) {
      return <Widget>[
        TextButton(
          autofocus: true,
          onPressed: () {
            _cancelToken.cancel();
            Navigator.of(context).pop();
          },
          child: const Text('Cancelar'),
        ),
      ];
    }

    final selected = folders
        .where((folder) => _selectedPaths.contains(folder.fullPath))
        .toList();
    return <Widget>[
      TextButton(
        autofocus: true,
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancelar'),
      ),
      Tooltip(
        message: widget.state.canDeleteFolders
            ? 'Apagar as pastas selecionadas'
            : _disabledReason(widget.state),
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: selected.isEmpty || !widget.state.canDeleteFolders
              ? null
              : () => _delete(selected),
          child: Text('Apagar ${selected.length} pastas'),
        ),
      ),
    ];
  }

  Future<void> _delete(List<CardItem> folders) async {
    setState(() => _deleting = true);
    final summary = await widget.state.deleteEmptyFolders(folders);
    if (!mounted) {
      return;
    }
    setState(() {
      _summary = summary;
      _deleting = false;
    });
  }
}

String _disabledReason(AppState state) {
  if (!state.config.deleteEnabled) {
    return 'Ative a exclusão nas configurações.';
  }
  if (state.uploadEnabled != true) {
    return 'O cartão precisa estar configurado com UPLOAD=1.';
  }
  if (state.connection != ConnectionStatus.connected) {
    return 'Conecte ao cartão para apagar pastas vazias.';
  }
  return 'Aguarde a operação atual terminar.';
}

class _Summary extends StatelessWidget {
  const _Summary({required this.summary});

  final FolderDeletionSummary summary;

  @override
  Widget build(BuildContext context) {
    final skippedNames = summary.skipped
        .map((folder) => folder.name)
        .join(', ');
    final failureNames = summary.failures.keys
        .map((folder) => folder.name)
        .join(', ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          '${summary.deleted.length} apagadas, '
          '${summary.skipped.length} puladas (não estavam vazias), '
          '${summary.failures.length} com falha',
        ),
        if (skippedNames.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          Text('Puladas: $skippedNames'),
        ],
        if (failureNames.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text('Com falha: $failureNames'),
        ],
      ],
    );
  }
}
