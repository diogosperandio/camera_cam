import 'dart:async';
import 'dart:math' as math;

import 'package:camera_cam/state/app_state.dart';
import 'package:camera_cam/ui/file_tree.dart';
import 'package:camera_cam/ui/preview_pane.dart';
import 'package:camera_cam/ui/settings_dialog.dart';
import 'package:camera_cam/ui/toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

class MainPage extends StatefulWidget {
  const MainPage({this.onOpenSettings, super.key});

  final VoidCallback? onOpenSettings;

  @override
  State<MainPage> createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  static const double _defaultSidebarWidth = 320;
  static const double _minimumSidebarWidth = 220;
  static const double _maximumSidebarWidth = 520;

  double _sidebarWidth = _defaultSidebarWidth;
  AppState? _state;
  String? _lastShownError;
  String? _lastFailedPath;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    if (!identical(_state, state)) {
      _state?.removeListener(_handleStateChanged);
      _state = state..addListener(_handleStateChanged);
    }
  }

  @override
  void dispose() {
    _state?.removeListener(_handleStateChanged);
    super.dispose();
  }

  void _handleStateChanged() {
    final state = _state;
    final folderError = state?.folderErrors.entries.lastOrNull;
    final error = state?.errorMessage ?? folderError?.value;
    final message = error ?? state?.noticeMessage;
    _lastFailedPath = state?.errorMessage == null && folderError != null
        ? folderError.key
        : null;
    if (message == null) {
      _lastShownError = null;
      _lastFailedPath = null;
      return;
    }
    if (message == _lastShownError || !mounted) {
      return;
    }
    _lastShownError = message;
    if (error == null) {
      state?.noticeMessage = null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          action: error == null
              ? null
              : SnackBarAction(
                  label: 'Tentar novamente',
                  onPressed: _retryLastAction,
                ),
        ),
      );
    });
  }

  void _retryLastAction() {
    final state = _state;
    if (state == null) {
      return;
    }
    if (_lastFailedPath case final path?) {
      unawaited(state.loadDir(path, force: true));
    } else if (state.connection == ConnectionStatus.error) {
      unawaited(state.connect());
    } else if (state.selected case final selected?) {
      unawaited(state.selectFile(selected));
    } else if (state.connection == ConnectionStatus.connected) {
      unawaited(state.loadDir('/', force: true));
    } else {
      unawaited(state.init());
    }
  }

  void _openSettings() {
    final callback = widget.onOpenSettings;
    if (callback != null) {
      callback();
      return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => const SettingsDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ssid = state.config.ssid?.trim();
    final canConnect =
        ssid != null &&
        ssid.isNotEmpty &&
        (state.connection == ConnectionStatus.disconnected ||
            state.connection == ConnectionStatus.error);
    final canDisconnect = state.connection == ConnectionStatus.connected;
    final canRefresh =
        state.connection == ConnectionStatus.connected &&
        !state.loadingPaths.contains('/');

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): () {
          unawaited(saveSelectedWithFeedback(context, state));
        },
        const SingleActivator(LogicalKeyboardKey.f5): () {
          if (canRefresh) {
            unawaited(state.loadDir('/', force: true));
          }
        },
        const SingleActivator(LogicalKeyboardKey.comma, control: true):
            _openSettings,
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
        autofocus: true,
        child: Scaffold(
          body: Column(
            children: <Widget>[
              CameraToolbar(
                state: state,
                onConnect: canConnect ? () => unawaited(state.connect()) : null,
                onDisconnect: canDisconnect
                    ? () => unawaited(state.disconnect())
                    : null,
                onRefresh: canRefresh
                    ? () => unawaited(state.loadDir('/', force: true))
                    : null,
                onSettings: _openSettings,
              ),
              const Divider(height: 1),
              Expanded(child: _buildBody(state, ssid)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(AppState state, String? ssid) {
    if (ssid == null || ssid.isEmpty) {
      return _EmptyState(
        icon: Icons.settings_outlined,
        message: 'Selecione uma rede em Configurações',
        actionLabel: 'Abrir configurações',
        onAction: _openSettings,
      );
    }
    if (state.connection == ConnectionStatus.disconnected ||
        state.connection == ConnectionStatus.error) {
      return _EmptyState(
        icon: Icons.wifi_off,
        message: 'Desconectado',
        actionLabel: 'Conectar',
        onAction: () => unawaited(state.connect()),
      );
    }
    if (state.connection == ConnectionStatus.connecting) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Conectando ao cartão…'),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        const dividerWidth = 10.0;
        final responsiveMinimum = math.min(
          _minimumSidebarWidth,
          math.max(0.0, constraints.maxWidth * 0.45),
        );
        final responsiveMaximum = math.min(
          _maximumSidebarWidth,
          math.max(responsiveMinimum, constraints.maxWidth - dividerWidth),
        );
        final width = _sidebarWidth
            .clamp(responsiveMinimum, responsiveMaximum)
            .toDouble();

        return Row(
          children: <Widget>[
            SizedBox(width: width, child: const FileTree()),
            MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) {
                  setState(() {
                    _sidebarWidth = (_sidebarWidth + details.delta.dx)
                        .clamp(responsiveMinimum, responsiveMaximum)
                        .toDouble();
                  });
                },
                child: SizedBox(
                  width: dividerWidth,
                  child: VerticalDivider(width: dividerWidth, thickness: 1),
                ),
              ),
            ),
            const Expanded(child: PreviewPane()),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              icon,
              size: 56,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            Text(message, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 20),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
