import 'dart:async';

import 'package:camera_cam/core/card_client.dart';
import 'package:camera_cam/models/app_config.dart';
import 'package:camera_cam/models/card_item.dart';
import 'package:camera_cam/state/app_state.dart';
import 'package:camera_cam/ui/app_snackbar.dart';
import 'package:camera_cam/ui/empty_folders_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class FileTree extends StatefulWidget {
  const FileTree({super.key});

  @override
  State<FileTree> createState() => _FileTreeState();
}

class _FileTreeState extends State<FileTree> {
  final FocusNode _focusNode = FocusNode(debugLabel: 'Árvore de arquivos');
  String? _activePath;

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final rows = _flattenTree(state);
    final itemRows = rows.whereType<_ItemRow>().toList();
    final activePath = itemRows.any((row) => row.item.fullPath == _activePath)
        ? _activePath
        : state.selected?.fullPath;
    final selectedSort = state.config.sortBy == SortBy.date
        ? SortBy.date
        : SortBy.name;

    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (_, event) =>
            _handleKeyEvent(event, state, itemRows, activePath),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
              child: Row(
                children: <Widget>[
                  const Text('Ordenar por:'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<SortBy>(
                        value: selectedSort,
                        isExpanded: true,
                        items: const <DropdownMenuItem<SortBy>>[
                          DropdownMenuItem(
                            value: SortBy.name,
                            child: Text('nome'),
                          ),
                          DropdownMenuItem(
                            value: SortBy.date,
                            child: Text('data'),
                          ),
                        ],
                        onChanged: (sortBy) {
                          if (sortBy != null) {
                            unawaited(
                              state.updateConfig(
                                state.config.copyWith(sortBy: sortBy),
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ),
                  if (state.config.deleteEnabled)
                    PopupMenuButton<String>(
                      enabled: state.canDeleteFolders,
                      tooltip: state.canDeleteFolders
                          ? 'Mais opções'
                          : _folderDeleteDisabledReason(state),
                      icon: const Icon(Icons.more_vert),
                      onSelected: (_) =>
                          unawaited(showEmptyFoldersDialog(context, state)),
                      itemBuilder: (_) => const <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'clean-empty-folders',
                          child: Text('Limpar pastas vazias…'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: rows.isEmpty && !state.loadingPaths.contains('/')
                  ? const Center(child: Text('Nenhum arquivo encontrado'))
                  : ListView.builder(
                      key: const Key('file-tree-list'),
                      itemCount: rows.length,
                      itemExtent: 64,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(0),
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        return switch (row) {
                          _ItemRow() => _buildItemRow(
                            context,
                            state,
                            row,
                            row.item.fullPath == activePath,
                          ),
                          _ErrorRow() => _FolderErrorRow(row: row),
                          _RootLoadingRow() => const Center(
                            child: SizedBox.square(
                              dimension: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        };
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemRow(
    BuildContext context,
    AppState state,
    _ItemRow row,
    bool selected,
  ) {
    final item = row.item;
    final children = item.isDir ? state.tree[item.fullPath] : null;
    final fileCount = children?.where((child) => !child.isDir).length;
    final isLoading = state.loadingPaths.contains(item.fullPath);
    final isExpanded = state.expandedPaths.contains(item.fullPath);
    final canOfferFolderDeletion =
        item.isDir && children != null && children.isEmpty;

    return Material(
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer
          : Colors.transparent,
      child: InkWell(
        onSecondaryTapDown: state.config.deleteEnabled && canOfferFolderDeletion
            ? (details) => unawaited(
                _showFolderContextMenu(context, state, item, details),
              )
            : null,
        onTap: () {
          _focusNode.requestFocus();
          setState(() => _activePath = item.fullPath);
          if (item.isDir) {
            unawaited(state.toggleFolder(item.fullPath));
          } else {
            unawaited(state.selectFile(item));
          }
        },
        child: Padding(
          padding: EdgeInsets.only(left: 8 + row.depth * 16, right: 8),
          child: Row(
            children: <Widget>[
              if (item.isDir)
                SizedBox(
                  width: 32,
                  child: isLoading
                      ? const Padding(
                          padding: EdgeInsets.all(7),
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          isExpanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right,
                        ),
                )
              else
                const SizedBox(width: 8),
              if (item.isDir)
                const Icon(Icons.folder_outlined, size: 28)
              else if (_supportsThumbnail(item))
                _FileThumbnail(item: item)
              else
                const SizedBox.square(
                  dimension: 40,
                  child: Icon(Icons.insert_drive_file_outlined),
                ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.isDir && children != null && children.isEmpty)
                      Text(
                        'vazia',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      )
                    else if (item.isDir && fileCount != null)
                      Text(
                        '$fileCount arquivo${fileCount == 1 ? '' : 's'}',
                        style: Theme.of(context).textTheme.bodySmall,
                      )
                    else if (!item.isDir)
                      Text(
                        formatFileSize(item.size),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              if (state.config.deleteEnabled && canOfferFolderDeletion)
                IconButton(
                  onPressed: state.canDeleteFolders
                      ? () => unawaited(
                          _requestDeleteFolder(context, state, item),
                        )
                      : null,
                  tooltip: state.canDeleteFolders
                      ? 'Apagar pasta vazia'
                      : _folderDeleteDisabledReason(state),
                  icon: const Icon(Icons.delete_outline),
                  color: Theme.of(context).colorScheme.error,
                ),
            ],
          ),
        ),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(
    KeyEvent event,
    AppState state,
    List<_ItemRow> rows,
    String? activePath,
  ) {
    if (event is! KeyDownEvent || rows.isEmpty) {
      return KeyEventResult.ignored;
    }

    var currentIndex = rows.indexWhere(
      (row) => row.item.fullPath == activePath,
    );
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      currentIndex = currentIndex < 0
          ? 0
          : (currentIndex + 1).clamp(0, rows.length - 1);
      _activateRow(state, rows[currentIndex], selectFile: true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      currentIndex = currentIndex < 0
          ? rows.length - 1
          : (currentIndex - 1).clamp(0, rows.length - 1);
      _activateRow(state, rows[currentIndex], selectFile: true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.home) {
      _activateRow(state, rows.first, selectFile: true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.end) {
      _activateRow(state, rows.last, selectFile: true);
      return KeyEventResult.handled;
    }
    if (currentIndex < 0) {
      return KeyEventResult.ignored;
    }

    final current = rows[currentIndex];
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _activateRow(state, current, activate: true);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete &&
        current.item.isDir &&
        state.config.deleteEnabled) {
      unawaited(_requestDeleteFolder(context, state, current.item));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
        current.item.isDir &&
        !state.expandedPaths.contains(current.item.fullPath)) {
      unawaited(state.toggleFolder(current.item.fullPath));
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (current.item.isDir &&
          state.expandedPaths.contains(current.item.fullPath)) {
        unawaited(state.toggleFolder(current.item.fullPath));
      } else {
        final parentIndex = rows.indexWhere(
          (row) => row.item.fullPath == current.item.parentPath,
        );
        if (parentIndex >= 0) {
          _activateRow(state, rows[parentIndex]);
        }
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _activateRow(
    AppState state,
    _ItemRow row, {
    bool activate = false,
    bool selectFile = false,
  }) {
    setState(() => _activePath = row.item.fullPath);
    if (row.item.isDir) {
      if (activate) {
        unawaited(state.toggleFolder(row.item.fullPath));
      }
    } else if (activate || selectFile) {
      unawaited(state.selectFile(row.item));
    }
  }

  Future<void> _showFolderContextMenu(
    BuildContext context,
    AppState state,
    CardItem folder,
    TapDownDetails details,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(details.globalPosition, details.globalPosition),
        Offset.zero & overlay.size,
      ),
      items: <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: 'delete-empty-folder',
          enabled: state.canDeleteFolders,
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline),
            title: Text('Apagar pasta vazia'),
          ),
        ),
      ],
    );
    if (selected == 'delete-empty-folder' && context.mounted) {
      await _requestDeleteFolder(context, state, folder);
    }
  }

  Future<void> _requestDeleteFolder(
    BuildContext context,
    AppState state,
    CardItem folder,
  ) async {
    if (!state.canDeleteFolders || !folder.isDir) {
      return;
    }
    if (!state.tree.containsKey(folder.fullPath)) {
      final loaded = await state.loadDir(folder.fullPath);
      if (!loaded || !context.mounted) {
        return;
      }
    }
    final count = state.tree[folder.fullPath]?.length ?? 0;
    if (count != 0) {
      showAppSnackBar(
        context,
        'Esta pasta não está vazia ($count arquivos). Só é possível apagar '
        'pastas vazias.',
        isError: true,
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apagar pasta vazia'),
        content: Text(
          'Apagar a pasta vazia ${folder.name} do cartão? Esta ação não pode '
          'ser desfeita.',
        ),
        actions: <Widget>[
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancelar'),
          ),
          Tooltip(
            message: state.canDeleteFolders
                ? 'Apagar pasta vazia'
                : _folderDeleteDisabledReason(state),
            child: FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: state.canDeleteFolders
                  ? () => Navigator.of(context).pop(true)
                  : null,
              child: const Text('Apagar'),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await state.deleteFolder(folder);
    }
  }
}

class _FileThumbnail extends StatefulWidget {
  const _FileThumbnail({required this.item});

  final CardItem item;

  @override
  State<_FileThumbnail> createState() => _FileThumbnailState();
}

class _FileThumbnailState extends State<_FileThumbnail> {
  Timer? _debounce;
  CancellationToken? _cancellationToken;
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _scheduleLoad();
  }

  @override
  void didUpdateWidget(covariant _FileThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.fullPath != widget.item.fullPath ||
        oldWidget.item.size != widget.item.size) {
      _cancelLoad();
      _bytes = null;
      _scheduleLoad();
    }
  }

  @override
  void dispose() {
    _cancelLoad();
    super.dispose();
  }

  void _scheduleLoad() {
    _debounce = Timer(const Duration(milliseconds: 150), () async {
      final token = CancellationToken();
      _cancellationToken = token;
      try {
        final bytes = await context.read<AppState>().loadThumbnail(
          widget.item,
          cancellationToken: token,
        );
        if (mounted && !token.isCancelled && bytes != null) {
          setState(() => _bytes = bytes);
        }
      } catch (_) {
        // A ausência de miniatura não impede a navegação pelo arquivo.
      }
    });
  }

  void _cancelLoad() {
    _debounce?.cancel();
    _debounce = null;
    _cancellationToken?.cancel();
    _cancellationToken = null;
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox.square(
        dimension: 40,
        child: bytes == null
            ? ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Icon(Icons.image_outlined, size: 22),
              )
            : Image.memory(
                bytes,
                cacheWidth: 80,
                width: 40,
                height: 40,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) =>
                    const Icon(Icons.broken_image_outlined),
              ),
      ),
    );
  }
}

class _FolderErrorRow extends StatelessWidget {
  const _FolderErrorRow({required this.row});

  final _ErrorRow row;

  @override
  Widget build(BuildContext context) {
    final state = context.read<AppState>();
    return Padding(
      padding: EdgeInsets.only(left: 24 + row.depth * 16, right: 8),
      child: Row(
        children: <Widget>[
          Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              row.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(state.loadDir(row.path, force: true)),
            child: const Text('Recarregar'),
          ),
        ],
      ),
    );
  }
}

sealed class _TreeRow {
  const _TreeRow();
}

class _ItemRow extends _TreeRow {
  const _ItemRow(this.item, this.depth);

  final CardItem item;
  final int depth;
}

class _ErrorRow extends _TreeRow {
  const _ErrorRow(this.path, this.message, this.depth);

  final String path;
  final String message;
  final int depth;
}

class _RootLoadingRow extends _TreeRow {
  const _RootLoadingRow();
}

List<_TreeRow> _flattenTree(AppState state) {
  final rows = <_TreeRow>[];
  final visited = <String>{};

  void addDirectory(String path, int depth) {
    if (!visited.add(path)) {
      return;
    }
    final error = state.folderErrors[path];
    if (error != null) {
      rows.add(_ErrorRow(path, error, depth));
    }
    for (final item in state.tree[path] ?? const <CardItem>[]) {
      rows.add(_ItemRow(item, depth));
      if (item.isDir && state.expandedPaths.contains(item.fullPath)) {
        addDirectory(item.fullPath, depth + 1);
      }
    }
  }

  if (state.loadingPaths.contains('/') && !state.tree.containsKey('/')) {
    rows.add(const _RootLoadingRow());
  }
  addDirectory('/', 0);
  return rows;
}

bool _supportsThumbnail(CardItem item) {
  final name = item.name.toLowerCase();
  return !item.isDir && (name.endsWith('.jpg') || name.endsWith('.jpeg'));
}

String _folderDeleteDisabledReason(AppState state) {
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

String formatFileSize(int bytes) {
  if (bytes < 1024) {
    return '$bytes B';
  }
  const units = <String>['KB', 'MB', 'GB', 'TB'];
  var value = bytes / 1024;
  var unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final decimals = value >= 10 ? 0 : 1;
  return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
}
