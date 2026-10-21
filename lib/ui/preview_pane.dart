import 'dart:async';

import 'package:camera_cam/models/card_item.dart';
import 'package:camera_cam/state/app_state.dart';
import 'package:camera_cam/ui/file_tree.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class PreviewPane extends StatefulWidget {
  const PreviewPane({super.key});

  @override
  State<PreviewPane> createState() => _PreviewPaneState();
}

class _PreviewPaneState extends State<PreviewPane> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'Visualização da foto');

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final selected = state.selected;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          unawaited(saveSelectedWithFeedback(context, state));
        },
        const SingleActivator(LogicalKeyboardKey.delete): () {
          unawaited(confirmDeleteWithFeedback(context, state));
        },
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
          unawaited(state.selectPrevious());
        },
        const SingleActivator(LogicalKeyboardKey.arrowRight): () {
          unawaited(state.selectNext());
        },
      },
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _focusNode.requestFocus,
          child: selected == null
              ? const Center(
                  child: Text('Selecione um arquivo para visualizar'),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _PreviewHeader(
                      item: selected,
                      state: state,
                      onSave: () =>
                          unawaited(saveSelectedWithFeedback(context, state)),
                      onDelete: () =>
                          unawaited(confirmDeleteWithFeedback(context, state)),
                    ),
                    const Divider(height: 1),
                    Expanded(child: _buildPreview(state, selected)),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildPreview(AppState state, CardItem item) {
    if (!item.isImage) {
      return const _UnsupportedPreview();
    }

    final bytes = state.previewBytes;
    if (bytes == null) {
      return _LoadingPreview(progress: state.previewProgress);
    }

    return _ZoomablePreview(
      key: ValueKey<String>(item.fullPath),
      bytes: bytes,
      loadingFullImage: state.previewIsThumbnail,
      progress: state.previewProgress,
    );
  }
}

Future<void> saveSelectedWithFeedback(
  BuildContext context,
  AppState state,
) async {
  final item = state.selected;
  if (item == null || item.isDir || state.saving || state.deleting) {
    return;
  }
  final path = await state.saveSelected();
  if (!context.mounted || path == null) {
    return;
  }
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text('Arquivo salvo em $path'),
      action: SnackBarAction(
        label: 'Abrir pasta',
        onPressed: () => unawaited(state.openContainingFolder(path)),
      ),
    ),
  );
}

Future<void> confirmDeleteWithFeedback(
  BuildContext context,
  AppState state,
) async {
  final item = state.selected;
  if (!state.config.deleteEnabled || !state.canDelete || item == null) {
    return;
  }

  final decision = await showDialog<_DeleteDecision>(
    context: context,
    builder: (context) =>
        _DeleteConfirmationDialog(item: item, previewBytes: state.previewBytes),
  );
  if (decision == null || !context.mounted) {
    return;
  }

  final deleted = await state.deleteSelected(
    saveCopyFirst: decision.saveCopyFirst,
  );
  if (!context.mounted || !deleted) {
    return;
  }
  ScaffoldMessenger.of(context)
      .showSnackBar(const SnackBar(content: Text(_deleteSuccessNotice)));
}

const String _deleteSuccessNotice =
    'Foto apagada. Se a câmera não enxergar o cartão ou mostrar o cartão como '
    'protegido, desligue e ligue a câmera.';

class _PreviewHeader extends StatelessWidget {
  const _PreviewHeader({
    required this.item,
    required this.state,
    required this.onSave,
    required this.onDelete,
  });

  final CardItem item;
  final AppState state;
  final VoidCallback onSave;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final canSave = !item.isDir && !state.saving && !state.deleting;
    final compact = MediaQuery.sizeOf(context).width < 700;
    final metadata =
        '${formatFileSize(item.size)} · ${formatDate(item.dateTime)}';

    final actions = <Widget>[
      if (state.saving)
        const Padding(
          padding: EdgeInsets.all(12),
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      if (compact)
        IconButton(
          tooltip: 'Salvar (Ctrl+S)',
          onPressed: canSave ? onSave : null,
          icon: const Icon(Icons.save_alt),
        )
      else
        FilledButton.tonalIcon(
          onPressed: canSave ? onSave : null,
          icon: const Icon(Icons.save_alt),
          label: const Text('Salvar'),
        ),
      if (state.config.deleteEnabled)
        Tooltip(
          message: deleteDisabledReason(state),
          child: compact
              ? IconButton(
                  tooltip: 'Apagar (Delete)',
                  onPressed: state.canDelete ? onDelete : null,
                  color: Theme.of(context).colorScheme.error,
                  icon: state.deleting
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                )
              : FilledButton.icon(
                  onPressed: state.canDelete ? onDelete : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  icon: state.deleting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.delete_outline),
                  label: const Text('Apagar'),
                ),
        ),
    ];

    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final details = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                metadata,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          );
          if (constraints.maxWidth >= 520) {
            return Row(
              children: <Widget>[
                Expanded(child: details),
                const SizedBox(width: 12),
                ..._spaced(actions),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              details,
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 4, children: actions),
            ],
          );
        },
      ),
    );
  }
}

class _ZoomablePreview extends StatefulWidget {
  const _ZoomablePreview({
    required this.bytes,
    required this.loadingFullImage,
    required this.progress,
    super.key,
  });

  final Uint8List bytes;
  final bool loadingFullImage;
  final double? progress;

  @override
  State<_ZoomablePreview> createState() => _ZoomablePreviewState();
}

class _ZoomablePreviewState extends State<_ZoomablePreview> {
  final TransformationController _controller = TransformationController();
  bool _fitImage = true;

  @override
  void didUpdateWidget(covariant _ZoomablePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.bytes, widget.bytes)) {
      _showFitted();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _showFitted() {
    _controller.value = Matrix4.identity();
    setState(() => _fitImage = true);
  }

  void _showActualSize() {
    _controller.value = Matrix4.identity();
    setState(() => _fitImage = false);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(
          color: Theme.of(context).colorScheme.surfaceContainerLowest,
          child: InteractiveViewer(
            transformationController: _controller,
            minScale: 0.05,
            maxScale: 8,
            boundaryMargin: const EdgeInsets.all(200),
            child: Image.memory(
              widget.bytes,
              fit: _fitImage ? BoxFit.contain : BoxFit.none,
              filterQuality: widget.loadingFullImage
                  ? FilterQuality.medium
                  : FilterQuality.high,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const _UnsupportedPreview(),
            ),
          ),
        ),
        Positioned(
          top: 12,
          right: 12,
          child: Material(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(20),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextButton.icon(
                  onPressed: _showFitted,
                  icon: const Icon(Icons.fit_screen, size: 18),
                  label: const Text('Ajustar'),
                ),
                TextButton(
                  onPressed: _showActualSize,
                  child: const Text('100%'),
                ),
              ],
            ),
          ),
        ),
        if (widget.loadingFullImage)
          Positioned(
            left: 12,
            bottom: 20,
            right: 12,
            child: _LoadingFullImageBadge(progress: widget.progress),
          ),
      ],
    );
  }
}

class _LoadingFullImageBadge extends StatelessWidget {
  const _LoadingFullImageBadge({required this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Carregando versão completa'),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
          ],
        ),
      ),
    );
  }
}

class _LoadingPreview extends StatelessWidget {
  const _LoadingPreview({required this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 280,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            const Text('Carregando imagem…'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: progress),
          ],
        ),
      ),
    );
  }
}

class _UnsupportedPreview extends StatelessWidget {
  const _UnsupportedPreview();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Card(
        margin: const EdgeInsets.all(24),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.hide_image_outlined,
                size: 52,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 12),
              const Text(
                'Pré-visualização indisponível para este formato',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeleteConfirmationDialog extends StatefulWidget {
  const _DeleteConfirmationDialog({
    required this.item,
    required this.previewBytes,
  });

  final CardItem item;
  final Uint8List? previewBytes;

  @override
  State<_DeleteConfirmationDialog> createState() =>
      _DeleteConfirmationDialogState();
}

class _DeleteConfirmationDialogState extends State<_DeleteConfirmationDialog> {
  bool _saveCopyFirst = true;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    return AlertDialog(
      title: const Text('Confirmar exclusão'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _DialogThumbnail(bytes: widget.previewBytes),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(formatFileSize(item.size)),
                      Text(formatDate(item.dateTime)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              'Apagar ${item.name} do cartão? '
              'Esta ação não pode ser desfeita.',
            ),
            const SizedBox(height: 12),
            CheckboxListTile(
              value: _saveCopyFirst,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'Salvar uma cópia no computador antes de apagar',
              ),
              onChanged: (value) {
                setState(() => _saveCopyFirst = value ?? true);
              },
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () =>
              Navigator.of(context).pop(_DeleteDecision(_saveCopyFirst)),
          child: const Text('Apagar'),
        ),
      ],
    );
  }
}

class _DialogThumbnail extends StatelessWidget {
  const _DialogThumbnail({required this.bytes});

  final Uint8List? bytes;

  @override
  Widget build(BuildContext context) {
    final imageBytes = bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox.square(
        dimension: 72,
        child: imageBytes == null
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.image_outlined),
              )
            : Image.memory(
                imageBytes,
                cacheWidth: 144,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const Icon(Icons.broken_image),
              ),
      ),
    );
  }
}

class _DeleteDecision {
  const _DeleteDecision(this.saveCopyFirst);

  final bool saveCopyFirst;
}

Iterable<Widget> _spaced(List<Widget> widgets) sync* {
  for (var index = 0; index < widgets.length; index++) {
    if (index > 0) {
      yield const SizedBox(width: 8);
    }
    yield widgets[index];
  }
}

String formatDate(DateTime? dateTime) {
  if (dateTime == null) {
    return 'Data desconhecida';
  }
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${twoDigits(dateTime.day)}/${twoDigits(dateTime.month)}/'
      '${dateTime.year} ${twoDigits(dateTime.hour)}:'
      '${twoDigits(dateTime.minute)}:${twoDigits(dateTime.second)}';
}

String deleteDisabledReason(AppState state) {
  if (!state.config.deleteEnabled) {
    return 'Ative a exclusão nas configurações.';
  }
  if (state.selected == null) {
    return 'Selecione um arquivo para apagar.';
  }
  if (state.selected!.isDir) {
    return 'Pastas não podem ser apagadas.';
  }
  if (state.uploadEnabled != true) {
    return 'O cartão precisa estar com UPLOAD=1.';
  }
  if (state.connection != ConnectionStatus.connected) {
    return 'Conecte-se ao cartão para apagar.';
  }
  if (state.saving) {
    return 'Aguarde o salvamento terminar.';
  }
  if (state.deleting) {
    return 'Exclusão em andamento.';
  }
  return 'Apagar do cartão (Delete)';
}
