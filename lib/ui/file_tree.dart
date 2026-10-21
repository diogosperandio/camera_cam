import 'dart:async';

import 'package:camera_cam/core/card_client.dart';
import 'package:camera_cam/models/app_config.dart';
import 'package:camera_cam/models/card_item.dart';
import 'package:camera_cam/state/app_state.dart';
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

    return Material(
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer
          : Colors.transparent,
      child: InkWell(
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
                    if (item.isDir && fileCount != null)
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
