import 'dart:async';

import 'package:camera_cam/state/app_state.dart';
import 'package:camera_cam/state/update_controller.dart';
import 'package:camera_cam/ui/app_snackbar.dart';
import 'package:camera_cam/ui/file_tree.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({this.updateController, super.key});

  final UpdateController? updateController;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _ssidController;
  late final TextEditingController _baseUrlController;
  late final TextEditingController _outputDirController;

  List<String> _networks = const <String>[];
  String? _selectedNetwork;
  bool _searchingNetworks = false;
  bool _selectingDirectory = false;
  bool _disconnectOnClose = true;
  bool _deleteEnabled = false;
  bool _deleteConfirmed = false;
  bool _checkingUpload = false;
  bool _uploadChecked = false;
  bool? _uploadAvailable;
  bool _loadingCache = true;
  bool _clearingCache = false;
  int? _cacheSize;
  bool _saving = false;
  late final int _initialSnackBarSeconds;
  late int _snackBarSeconds;
  bool _settingsSaved = false;
  late String _rotateSaveMode;
  late bool _autoCheckUpdates;
  late final AppState _appState;

  @override
  void initState() {
    super.initState();
    _appState = context.read<AppState>();
    final config = _appState.config;
    _ssidController = TextEditingController(text: config.ssid ?? '');
    _baseUrlController = TextEditingController(text: config.baseUrl);
    _outputDirController = TextEditingController(text: config.outputDir ?? '');
    _disconnectOnClose = config.disconnectOnClose;
    _deleteEnabled = config.deleteEnabled;
    _deleteConfirmed = config.deleteEnabled;
    _initialSnackBarSeconds = config.snackBarSeconds;
    _snackBarSeconds = config.snackBarSeconds;
    _rotateSaveMode = config.rotateSaveMode;
    _autoCheckUpdates = config.autoCheckUpdates;
    widget.updateController?.addListener(_updateChanged);
    unawaited(_loadCacheSize());
  }

  @override
  void dispose() {
    if (!_settingsSaved) {
      _appState.previewSnackBarSeconds(_initialSnackBarSeconds);
    }
    _ssidController.dispose();
    _baseUrlController.dispose();
    _outputDirController.dispose();
    widget.updateController?.removeListener(_updateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final canCheckUpload =
        state.connection == ConnectionStatus.connected && !_checkingUpload;

    return AlertDialog(
      title: const Text('Configurações'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'Rede Wi-Fi',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        key: ValueKey<String>(
                          '${_networks.join('|')}|$_selectedNetwork',
                        ),
                        initialValue: _selectedNetwork,
                        decoration: const InputDecoration(
                          labelText: 'Redes encontradas',
                          border: OutlineInputBorder(),
                        ),
                        hint: const Text('Busque redes disponíveis'),
                        isExpanded: true,
                        items: _networks
                            .map(
                              (network) => DropdownMenuItem<String>(
                                value: network,
                                child: Text(
                                  network,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: _networks.isEmpty
                            ? null
                            : (network) {
                                if (network == null) {
                                  return;
                                }
                                setState(() => _selectedNetwork = network);
                                _ssidController.text = network;
                              },
                      ),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.tonalIcon(
                      onPressed: _searchingNetworks ? null : _searchNetworks,
                      icon: _searchingNetworks
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_find),
                      label: const Text('Buscar redes'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _ssidController,
                  decoration: const InputDecoration(
                    labelText: 'SSID manual',
                    hintText: 'Nome da rede Wi-Fi do cartão',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    final match = _networks.contains(value) ? value : null;
                    if (match != _selectedNetwork) {
                      setState(() => _selectedNetwork = match);
                    }
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _baseUrlController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: 'URL base do cartão',
                    hintText: 'http://flashair',
                    border: OutlineInputBorder(),
                  ),
                  validator: validateBaseUrl,
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: TextFormField(
                        controller: _outputDirController,
                        readOnly: true,
                        decoration: const InputDecoration(
                          labelText: 'Pasta de saída padrão',
                          hintText: 'Escolher ao salvar',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Escolher pasta',
                      onPressed: _selectingDirectory ? null : _chooseDirectory,
                      icon: _selectingDirectory
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.folder_open),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Desconectar ao fechar o app'),
                  value: _disconnectOnClose,
                  onChanged: (value) {
                    setState(() => _disconnectOnClose = value);
                  },
                ),
                const Divider(),
                Text(
                  'Atualizações',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Verificar atualizações automaticamente'),
                  value: _autoCheckUpdates,
                  onChanged: (value) =>
                      setState(() => _autoCheckUpdates = value),
                ),
                Text(
                  'Versão instalada: ${widget.updateController?.currentVersion ?? '—'}',
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed:
                          widget.updateController?.status ==
                              UpdateStatus.checking
                          ? null
                          : _checkForUpdates,
                      icon:
                          widget.updateController?.status ==
                              UpdateStatus.checking
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.system_update),
                      label: const Text('Verificar agora'),
                    ),
                    if (state.config.skippedVersion case final version?)
                      TextButton(
                        onPressed: _stopIgnoring,
                        child: Text('Parar de ignorar v$version'),
                      ),
                  ],
                ),
                const Divider(),
                Text(
                  'Ao salvar fotos giradas',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                RadioGroup<String>(
                  groupValue: _rotateSaveMode,
                  onChanged: (value) {
                    setState(() => _rotateSaveMode = value ?? 'exif');
                  },
                  child: const Column(
                    children: <Widget>[
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        value: 'exif',
                        title: Text('Ajustar a orientação (EXIF)'),
                        subtitle: Text(
                          'Sem perda e instantâneo; alguns programas podem ignorar.',
                        ),
                      ),
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        value: 'pixels',
                        title: Text('Regravar os pixels'),
                        subtitle: Text(
                          'Funciona em qualquer programa, mas recompacta o JPEG.',
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                Text(
                  'Duração das mensagens (segundos): $_snackBarSeconds',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Row(
                  children: <Widget>[
                    const Text('3 s'),
                    Expanded(
                      child: Slider(
                        value: _snackBarSeconds.toDouble(),
                        min: 3,
                        max: 60,
                        divisions: 57,
                        label: '$_snackBarSeconds s',
                        onChanged: (value) {
                          final seconds = value.round();
                          setState(() => _snackBarSeconds = seconds);
                          context.read<AppState>().previewSnackBarSeconds(
                            seconds,
                          );
                        },
                      ),
                    ),
                    const Text('60 s'),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () => showAppSnackBar(
                        context,
                        'Esta mensagem ficará visível por '
                        '$_snackBarSeconds segundos.',
                      ),
                      child: const Text('Testar'),
                    ),
                  ],
                ),
                const Divider(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Permitir apagar fotos do cartão'),
                  subtitle: const Text(
                    'Exige UPLOAD=1 no arquivo SD_WLAN/CONFIG do cartão. '
                    'Apagar é irreversível.',
                  ),
                  value: _deleteEnabled,
                  onChanged: _changeDeleteEnabled,
                ),
                Row(
                  children: <Widget>[
                    OutlinedButton.icon(
                      onPressed: canCheckUpload ? _verifyUploadSupport : null,
                      icon: _checkingUpload
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.verified_outlined),
                      label: const Text('Verificar suporte'),
                    ),
                    const SizedBox(width: 12),
                    if (_uploadChecked)
                      Flexible(
                        child: Text(
                          _uploadAvailable == true
                              ? 'Disponível'
                              : 'Indisponível: habilite UPLOAD=1 no cartão',
                          style: TextStyle(
                            color: _uploadAvailable == true
                                ? Colors.green
                                : Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
                const Divider(height: 32),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        _loadingCache
                            ? 'Cache: calculando…'
                            : 'Cache: ${formatFileSize(_cacheSize ?? 0)}',
                      ),
                    ),
                    OutlinedButton.icon(
                      onPressed: _clearingCache ? null : _clearCache,
                      icon: _clearingCache
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.cleaning_services_outlined),
                      label: const Text('Limpar cache'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _saving ? null : _cancel,
          child: const Text('Cancelar'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Salvar'),
        ),
      ],
    );
  }

  Future<void> _searchNetworks() async {
    setState(() => _searchingNetworks = true);
    final networks = await context.read<AppState>().listWifiNetworks();
    if (!mounted) {
      return;
    }
    final currentSsid = _ssidController.text.trim();
    setState(() {
      _networks = networks;
      _selectedNetwork = networks.contains(currentSsid) ? currentSsid : null;
      _searchingNetworks = false;
    });
  }

  Future<void> _chooseDirectory() async {
    setState(() => _selectingDirectory = true);
    try {
      final selected = await getDirectoryPath(
        initialDirectory: _outputDirController.text.trim().isEmpty
            ? null
            : _outputDirController.text.trim(),
        confirmButtonText: 'Selecionar pasta',
      );
      if (mounted && selected != null) {
        _outputDirController.text = selected;
      }
    } finally {
      if (mounted) {
        setState(() => _selectingDirectory = false);
      }
    }
  }

  Future<void> _changeDeleteEnabled(bool enabled) async {
    if (!enabled) {
      setState(() => _deleteEnabled = false);
      return;
    }
    if (!_deleteConfirmed) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Permitir exclusão?'),
          content: const Text(
            'Apagar fotos do cartão é irreversível. Os arquivos não poderão '
            'ser recuperados pelo aplicativo.',
          ),
          actions: <Widget>[
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancelar'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError,
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Entendo, permitir'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) {
        return;
      }
      _deleteConfirmed = true;
    }
    setState(() => _deleteEnabled = true);
  }

  Future<void> _verifyUploadSupport() async {
    setState(() => _checkingUpload = true);
    final result = await context.read<AppState>().verifyUploadSupport();
    if (!mounted) {
      return;
    }
    setState(() {
      _checkingUpload = false;
      _uploadChecked = true;
      _uploadAvailable = result;
    });
  }

  Future<void> _loadCacheSize() async {
    final size = await context.read<AppState>().cacheSizeOnDisk();
    if (!mounted) {
      return;
    }
    setState(() {
      _cacheSize = size;
      _loadingCache = false;
    });
  }

  Future<void> _clearCache() async {
    setState(() => _clearingCache = true);
    final cleared = await context.read<AppState>().clearCache();
    if (!mounted) {
      return;
    }
    setState(() {
      if (cleared) {
        _cacheSize = 0;
      }
      _loadingCache = false;
      _clearingCache = false;
    });
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    final state = context.read<AppState>();
    final ssid = _ssidController.text.trim();
    final outputDir = _outputDirController.text.trim();
    final saved = await state.updateConfig(
      state.config.copyWith(
        ssid: ssid.isEmpty ? null : ssid,
        baseUrl: _baseUrlController.text.trim(),
        outputDir: outputDir.isEmpty ? null : outputDir,
        disconnectOnClose: _disconnectOnClose,
        deleteEnabled: _deleteEnabled,
        snackBarSeconds: _snackBarSeconds,
        rotateSaveMode: _rotateSaveMode,
        autoCheckUpdates: _autoCheckUpdates,
      ),
    );
    if (!mounted) {
      return;
    }
    if (saved) {
      _settingsSaved = true;
      Navigator.of(context).pop();
    } else {
      setState(() => _saving = false);
    }
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _checkForUpdates() async {
    final controller = widget.updateController;
    if (controller == null) return;
    await controller.checkNow();
    if (!mounted) return;
    final message = switch (controller.status) {
      UpdateStatus.available =>
        'Atualização v${controller.availableUpdate!.version} disponível.',
      UpdateStatus.upToDate => 'Você já está usando a versão mais recente.',
      UpdateStatus.error =>
        controller.errorMessage ?? 'Falha ao verificar atualizações.',
      _ => null,
    };
    if (message != null) {
      showAppSnackBar(
        context,
        message,
        isError: controller.status == UpdateStatus.error,
      );
    }
  }

  Future<void> _stopIgnoring() async {
    await widget.updateController?.stopIgnoring();
    if (mounted) setState(() {});
  }

  void _cancel() {
    context.read<AppState>().previewSnackBarSeconds(_initialSnackBarSeconds);
    _settingsSaved = true;
    Navigator.of(context).pop();
  }
}

String? validateBaseUrl(String? value) {
  final uri = Uri.tryParse(value?.trim() ?? '');
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return 'Informe uma URL HTTP válida, como http://flashair.';
  }
  return null;
}
