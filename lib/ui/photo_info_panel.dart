import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:toshiba_flashair_wifi_viewer/core/metadata/metadata_format.dart';
import 'package:toshiba_flashair_wifi_viewer/core/metadata/photo_metadata.dart';
import 'package:toshiba_flashair_wifi_viewer/models/card_item.dart';
import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';
import 'package:toshiba_flashair_wifi_viewer/ui/app_snackbar.dart';
import 'package:toshiba_flashair_wifi_viewer/ui/file_tree.dart';

class PhotoInfoPanel extends StatefulWidget {
  const PhotoInfoPanel({required this.state, required this.item, super.key});

  final AppState state;
  final CardItem item;

  @override
  State<PhotoInfoPanel> createState() => _PhotoInfoPanelState();
}

class _PhotoInfoPanelState extends State<PhotoInfoPanel> {
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final item = widget.item;
    final metadata = state.photoMetadata;
    final sections = _sections(state, item, metadata);

    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
            child: Row(
              children: <Widget>[
                const Icon(Icons.info_outline, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Informações',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _copySections(context, sections),
                  icon: const Icon(Icons.copy_outlined, size: 17),
                  label: const Text('Copiar'),
                ),
                IconButton(
                  tooltip: 'Fechar painel (I)',
                  onPressed: () => unawaited(state.setInfoPanelVisible(false)),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
              children: <Widget>[
                for (final section in sections) _InfoSection(section: section),
                if (state.metadataStatus == MetadataLoadStatus.loading)
                  const _LoadingMetadata()
                else if (state.metadataStatus == MetadataLoadStatus.noExif)
                  const _MetadataMessage('Esta foto não contém dados EXIF.')
                else if (state.metadataStatus == MetadataLoadStatus.unsupported)
                  const _MetadataMessage(
                    'Metadados indisponíveis para este formato.',
                  )
                else if (state.metadataStatus ==
                    MetadataLoadStatus.rangeUnsupported)
                  _MetadataAction(
                    message:
                        'O cartão não oferece leitura parcial nesta sessão.',
                    label: 'Carregar',
                    onPressed: state.loadFullPhotoForMetadata,
                  )
                else if (state.metadataStatus == MetadataLoadStatus.removed)
                  const _MetadataMessage(
                    'O arquivo foi removido do cartão.',
                    icon: Icons.delete_outline,
                  )
                else if (state.metadataStatus == MetadataLoadStatus.error)
                  _MetadataAction(
                    message:
                        state.metadataError ??
                        'Não foi possível ler os metadados.',
                    label: 'Tentar de novo',
                    onPressed: () => state.loadSelectedMetadata(force: true),
                  ),
                if (metadata != null &&
                    hasSuspiciousCameraClock(metadata.dateOriginal))
                  const Card(
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.warning_amber_rounded),
                      title: Text(
                        'O relógio da câmera provavelmente estava desacertado',
                      ),
                    ),
                  ),
                if (metadata?.hasGps == true)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => unawaited(state.openMetadataMap()),
                      icon: const Icon(Icons.map_outlined),
                      label: const Text('Abrir no mapa'),
                    ),
                  ),
                if (metadata?.rawTags.isNotEmpty == true)
                  _AllFields(
                    tags: metadata!.rawTags,
                    controller: _searchController,
                    onSearchChanged: () => setState(() {}),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoSectionData {
  const _InfoSectionData(this.title, this.lines);
  final String title;
  final List<(String, String)> lines;
}

List<_InfoSectionData> _sections(
  AppState state,
  CardItem item,
  PhotoMetadata? metadata,
) {
  final camera = <String>[
    if ((metadata?.make ?? '').isNotEmpty) metadata!.make!,
    if ((metadata?.model ?? '').isNotEmpty) metadata!.model!,
  ].join(' · ');
  final dimensions = formatDimensions(
    metadata?.width ?? state.thumbnailWidth,
    metadata?.height ?? state.thumbnailHeight,
  );
  final orientation = formatOrientation(
    metadata?.orientation ?? state.thumbnailOrientation,
    manualQuarterTurns: state.manualQuarterTurns,
  );
  final sections = <_InfoSectionData>[
    _InfoSectionData('Arquivo', <(String, String)>[
      ('Nome', item.name),
      ('Pasta no cartão', item.parentPath),
      ('Tamanho', '${formatFileSize(item.size)} (${item.size} bytes)'),
      ('Data no cartão', formatDateTime(item.dateTime)),
    ]),
  ];
  if (metadata != null) {
    sections.addAll(<_InfoSectionData>[
      _InfoSectionData('Captura', <(String, String)>[
        ('Data/hora original', formatDateTime(metadata.dateOriginal)),
        ('Câmera', camera),
        ('Lente', metadata.lensModel ?? ''),
        ('Software', metadata.software ?? ''),
      ]),
      _InfoSectionData('Exposição', <(String, String)>[
        ('Exposição', formatExposure(metadata.exposureTime)),
        ('Abertura', formatAperture(metadata.aperture)),
        ('ISO', metadata.iso?.toString() ?? ''),
        (
          'Focal',
          formatFocalLength(
            metadata.focalLength,
            equivalent35mm: metadata.focalLength35mm,
            model: metadata.model,
          ),
        ),
        ('Compensação', formatExposureBias(metadata.exposureBias)),
        ('Programa', formatExposureProgram(metadata.exposureProgram)),
        ('Medição', formatMeteringMode(metadata.meteringMode)),
        ('Flash', formatFlash(metadata.flash)),
        ('Balanço de branco', formatWhiteBalance(metadata.whiteBalance)),
      ]),
      _InfoSectionData('Imagem', <(String, String)>[
        ('Dimensões', dimensions),
        ('Orientação', orientation),
        ('Espaço de cor', formatColorSpace(metadata.colorSpace)),
      ]),
      if (metadata.hasGps)
        _InfoSectionData('Local', <(String, String)>[
          ('Coordenadas', formatGps(metadata.latitude!, metadata.longitude!)),
          if (metadata.altitude != null)
            (
              'Altitude',
              '${metadata.altitude!.toStringAsFixed(1).replaceAll('.', ',')} m',
            ),
        ]),
    ]);
  } else if (dimensions.isNotEmpty || orientation.isNotEmpty) {
    sections.add(
      _InfoSectionData('Imagem', <(String, String)>[
        ('Dimensões', dimensions),
        ('Orientação', orientation),
      ]),
    );
  }
  return sections
      .map(
        (section) => _InfoSectionData(
          section.title,
          section.lines.where((line) => line.$2.isNotEmpty).toList(),
        ),
      )
      .where((section) => section.lines.isNotEmpty)
      .toList();
}

class _InfoSection extends StatelessWidget {
  const _InfoSection({required this.section});
  final _InfoSectionData section;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(section.title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          for (final line in section.lines)
            _MetadataLine(label: line.$1, value: line.$2),
        ],
      ),
    );
  }
}

class _MetadataLine extends StatelessWidget {
  const _MetadataLine({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: (details) => _showCopyMenu(context, details),
      onLongPress: () => _copyValue(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: Theme.of(context).textTheme.labelSmall),
            SelectableText(value),
          ],
        ),
      ),
    );
  }

  Future<void> _showCopyMenu(
    BuildContext context,
    TapDownDetails details,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final selected = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(details.globalPosition, details.globalPosition),
        Offset.zero & overlay.size,
      ),
      items: const <PopupMenuEntry<bool>>[
        PopupMenuItem<bool>(value: true, child: Text('Copiar valor')),
      ],
    );
    if (selected == true && context.mounted) await _copyValue(context);
  }

  Future<void> _copyValue(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (context.mounted) showAppSnackBar(context, 'Valor copiado');
  }
}

class _AllFields extends StatelessWidget {
  const _AllFields({
    required this.tags,
    required this.controller,
    required this.onSearchChanged,
  });
  final List<RawMetadataTag> tags;
  final TextEditingController controller;
  final VoidCallback onSearchChanged;

  @override
  Widget build(BuildContext context) {
    final query = controller.text.trim().toLowerCase();
    final filtered = tags.where((tag) {
      return query.isEmpty ||
          tag.group.toLowerCase().contains(query) ||
          tag.name.toLowerCase().contains(query) ||
          tag.value.toLowerCase().contains(query);
    }).toList();
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: EdgeInsets.zero,
      title: const Text('Todos os campos'),
      children: <Widget>[
        TextField(
          controller: controller,
          onChanged: (_) => onSearchChanged(),
          decoration: const InputDecoration(
            prefixIcon: Icon(Icons.search),
            labelText: 'Buscar campos',
            isDense: true,
          ),
        ),
        const SizedBox(height: 8),
        for (final tag in filtered)
          _MetadataLine(label: '${tag.group} · ${tag.name}', value: tag.value),
        if (filtered.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Nenhum campo encontrado.'),
          ),
      ],
    );
  }
}

class _LoadingMetadata extends StatelessWidget {
  const _LoadingMetadata();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LinearProgressIndicator(),
          SizedBox(height: 8),
          Text('Lendo metadados…'),
        ],
      ),
    );
  }
}

class _MetadataMessage extends StatelessWidget {
  const _MetadataMessage(this.message, {this.icon = Icons.info_outline});
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(icon),
    title: Text(message),
  );
}

class _MetadataAction extends StatelessWidget {
  const _MetadataAction({
    required this.message,
    required this.label,
    required this.onPressed,
  });
  final String message;
  final String label;
  final Future<void> Function() onPressed;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      _MetadataMessage(message, icon: Icons.error_outline),
      TextButton(onPressed: () => unawaited(onPressed()), child: Text(label)),
    ],
  );
}

Future<void> _copySections(
  BuildContext context,
  List<_InfoSectionData> sections,
) async {
  final text = sections
      .map(
        (section) => <String>[
          section.title,
          for (final line in section.lines) '${line.$1}: ${line.$2}',
        ].join('\n'),
      )
      .join('\n\n');
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showAppSnackBar(context, 'Informações copiadas');
}
