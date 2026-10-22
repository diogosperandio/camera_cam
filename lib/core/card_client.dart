import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:toshiba_flashair_wifi_viewer/models/card_item.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final Logger _cardLog = Logger('CardClient');

typedef DownloadProgress = void Function(int receivedBytes, int? totalBytes);

List<CardItem> parseFileList(String body, String requestedDir) {
  final lines = body.split(RegExp(r'\r?\n'));
  final firstContentLine = lines
      .map((line) => line.replaceFirst('\uFEFF', '').trim())
      .where((line) => line.isNotEmpty)
      .firstOrNull;

  if (firstContentLine != 'WLANSD_FILELIST') {
    throw const CardParseException(
      'A resposta não contém o cabeçalho WLANSD_FILELIST.',
    );
  }

  final items = <CardItem>[];
  for (final rawLine in lines) {
    final line = rawLine.replaceFirst('\uFEFF', '').trim();
    if (line.isEmpty || line == 'WLANSD_FILELIST') {
      continue;
    }

    final fields = line.split(',');
    if (fields.length < 6) {
      throw CardParseException('Linha inválida na lista de arquivos: $line');
    }

    try {
      final trailingFieldsStart = fields.length - 4;
      final directory = fields.first.trim();
      final name = fields.sublist(1, trailingFieldsStart).join(',').trim();
      if (name.isEmpty) {
        throw const FormatException('O nome do item está vazio.');
      }

      final size = int.parse(fields[trailingFieldsStart].trim());
      final attribute = int.parse(fields[trailingFieldsStart + 1].trim());
      final fatDate = int.parse(fields[trailingFieldsStart + 2].trim());
      final fatTime = int.parse(fields[trailingFieldsStart + 3].trim());
      items.add(
        CardItem(
          name: name,
          parentPath: directory.isEmpty ? requestedDir : directory,
          size: size,
          isDir: attribute & 0x10 != 0,
          dateTime: _decodeFatDateTime(fatDate, fatTime),
        ),
      );
    } on FormatException catch (error) {
      throw CardParseException(
        'Linha inválida na lista de arquivos: $line (${error.message})',
      );
    }
  }

  items.sort((first, second) {
    if (first.isDir != second.isDir) {
      return first.isDir ? -1 : 1;
    }
    final comparison = first.name.toLowerCase().compareTo(
      second.name.toLowerCase(),
    );
    return comparison != 0 ? comparison : first.name.compareTo(second.name);
  });
  return items;
}

class CardClient {
  CardClient(String baseUrl, this._httpClient, {int maxConcurrent = 2})
    : _baseUri = Uri.parse(baseUrl),
      _requestQueue = _RequestQueue(maxConcurrent);

  static const Duration _requestTimeout = Duration(seconds: 8);
  static const Duration _deleteTimeout = Duration(seconds: 10);
  static const Duration _downloadTimeout = Duration(seconds: 60);

  Uri _baseUri;
  final http.Client _httpClient;
  final _RequestQueue _requestQueue;

  void updateBaseUrl(String baseUrl) {
    _baseUri = Uri.parse(baseUrl);
  }

  Future<List<CardItem>> listDir(String path) {
    return _requestQueue.schedule(
      () => _listDir(path),
      priority: _RequestPriority.normal,
    );
  }

  Future<Uint8List> download(String path, {DownloadProgress? onProgress}) {
    return _requestQueue.schedule(
      () => _download(path, onProgress),
      priority: _RequestPriority.high,
    );
  }

  Future<Uint8List?> thumbnail(
    String path, {
    CancellationToken? cancellationToken,
  }) {
    return _requestQueue.schedule<Uint8List?>(
      () => _thumbnail(path),
      priority: _RequestPriority.low,
      cancellationToken: cancellationToken,
      onCancelled: () => null,
    );
  }

  Future<bool> ping() async {
    try {
      await listDir('/');
      return true;
    } on CardException {
      return false;
    }
  }

  Future<bool?> isUploadEnabled() {
    return _requestQueue.schedule(
      _isUploadEnabled,
      priority: _RequestPriority.normal,
    );
  }

  Future<int> countFiles(String dir) {
    return _requestQueue.schedule(
      () => _countFiles(dir),
      priority: _RequestPriority.high,
    );
  }

  Future<void> deleteEmptyFolder(String path) {
    _validateFolderDeletePath(path);
    return _requestQueue.schedule(
      () => _deleteEmptyFolder(path),
      priority: _RequestPriority.high,
    );
  }

  Future<void> deleteFile(String path, {bool writeProtect = true}) {
    _validateDeletePath(path);
    return _requestQueue.schedule(() async {
      try {
        await _deleteFile(path, writeProtect);
      } catch (error) {
        _cardLog.severe(
          'Resultado da exclusão: caminho=$path; falha; '
          'resposta indisponível ou inválida',
          error,
        );
        rethrow;
      }
    }, priority: _RequestPriority.high);
  }

  Future<List<CardItem>> _listDir(String path) async {
    final encodedPath = _encodePath(path);
    final uri = Uri.parse(
      '${_endpoint('/command.cgi')}?op=100&DIR=$encodedPath',
    );
    final response = await _get(uri, _requestTimeout);
    if (response.statusCode != HttpStatus.ok) {
      throw CardHttpException(response.statusCode, uri);
    }
    return parseFileList(response.body, path);
  }

  Future<Uint8List> _download(String path, DownloadProgress? onProgress) async {
    final uri = _cardPathUri(path);
    final stopwatch = Stopwatch()..start();
    _cardLog.info('HTTP GET $uri');

    try {
      final response = await _httpClient
          .send(http.Request('GET', uri))
          .timeout(_downloadTimeout);
      if (response.statusCode != HttpStatus.ok) {
        _cardLog.warning(
          'HTTP GET $uri -> ${response.statusCode} em ${stopwatch.elapsed}',
        );
        throw CardHttpException(response.statusCode, uri);
      }

      final remaining = _downloadTimeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Tempo limite de download excedido.');
      }
      final bytes = await _readDownload(
        response,
        onProgress,
      ).timeout(remaining);
      _cardLog.info(
        'HTTP GET $uri -> ${response.statusCode}, ${bytes.length} bytes '
        'em ${stopwatch.elapsed}',
      );
      return bytes;
    } on TimeoutException catch (error) {
      _cardLog.warning('Timeout HTTP GET $uri', error);
      throw CardUnreachableException(uri, error);
    } on SocketException catch (error) {
      _cardLog.warning('Socket indisponível em HTTP GET $uri', error);
      throw CardUnreachableException(uri, error);
    } on http.ClientException catch (error) {
      _cardLog.warning('Falha de cliente em HTTP GET $uri', error);
      throw CardUnreachableException(uri, error);
    }
  }

  Future<Uint8List?> _thumbnail(String path) async {
    final uri = Uri.parse(
      '${_endpoint('/thumbnail.cgi')}?${_encodePath(path)}',
    );
    final response = await _get(uri, _requestTimeout);
    if (response.statusCode != HttpStatus.ok) {
      return null;
    }

    final bytes = response.bodyBytes;
    if (bytes.length < 2 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
      return null;
    }
    return bytes;
  }

  Future<bool?> _isUploadEnabled() async {
    final uri = Uri.parse('${_endpoint('/command.cgi')}?op=118');
    try {
      final response = await _get(uri, _requestTimeout);
      if (response.statusCode != HttpStatus.ok) {
        throw CardHttpException(response.statusCode, uri);
      }
      return response.body.trim() == '1';
    } on CardUnreachableException {
      return null;
    }
  }

  Future<int> _countFiles(String dir) async {
    final uri = Uri.parse(
      '${_endpoint('/command.cgi')}?op=101&DIR=${_encodePath(dir)}',
    );
    final response = await _get(uri, _requestTimeout);
    if (response.statusCode != HttpStatus.ok) {
      throw CardHttpException(response.statusCode, uri);
    }
    final count = int.tryParse(response.body.trim());
    if (count == null || count < 0) {
      throw CardParseException(
        'Contagem de arquivos inválida para "$dir": "${response.body.trim()}".',
      );
    }
    return count;
  }

  Future<void> _deleteEmptyFolder(String path) async {
    _cardLog.info('Verificando pasta antes da exclusão: caminho=$path');
    final items = await _listDir(path);
    if (items.isNotEmpty) {
      _cardLog.info(
        'Exclusão de pasta recusada: caminho=$path; '
        'contagem=${items.length}; origem=listDir',
      );
      throw FolderNotEmptyException(path, items.length);
    }

    final count = await _countFiles(path);
    _cardLog.info(
      'Contagem verificada para exclusão de pasta: caminho=$path; contagem=$count',
    );
    if (count != 0) {
      throw FolderNotEmptyException(path, count);
    }

    try {
      await _deleteFile(path, true);
      _cardLog.info('Exclusão de pasta concluída: caminho=$path; contagem=0');
    } catch (error) {
      _cardLog.severe(
        'Exclusão de pasta falhou: caminho=$path; contagem=0',
        error,
      );
      rethrow;
    }
  }

  Future<void> _deleteFile(String path, bool writeProtect) async {
    _cardLog.info('Tentativa de exclusão: caminho=$path');
    if (writeProtect) {
      final protectUri = Uri.parse(
        '${_endpoint('/upload.cgi')}?WRITEPROTECT=ON',
      );
      final protectResponse = await _get(protectUri, _deleteTimeout);
      _cardLog.info(
        'Preparação da exclusão: caminho=$path; '
        'status=${protectResponse.statusCode}; resposta=${protectResponse.body}',
      );
      if (protectResponse.statusCode != HttpStatus.ok) {
        _cardLog.warning(
          'Exclusão recusada na proteção: caminho=$path; '
          'status=${protectResponse.statusCode}; resposta=${protectResponse.body}',
        );
        throw CardHttpException(protectResponse.statusCode, protectUri);
      }
    }

    final deleteUri = Uri.parse(
      '${_endpoint('/upload.cgi')}?DEL=${_encodePath(path)}',
    );
    final response = await _get(deleteUri, _deleteTimeout);
    _cardLog.info(
      'Resposta da exclusão: caminho=$path; status=${response.statusCode}; '
      'resposta=${response.body}',
    );
    if (response.statusCode != HttpStatus.ok ||
        !response.body.toUpperCase().contains('SUCCESS')) {
      _cardLog.warning(
        'Exclusão falhou: caminho=$path; status=${response.statusCode}; '
        'resposta=${response.body}',
      );
      throw CardDeleteException(
        statusCode: response.statusCode,
        body: response.body,
      );
    }
    _cardLog.info(
      'Exclusão concluída: caminho=$path; status=${response.statusCode}; '
      'resposta=${response.body}',
    );
  }

  Future<http.Response> _get(Uri uri, Duration timeout) async {
    final stopwatch = Stopwatch()..start();
    _cardLog.info('HTTP GET $uri');
    try {
      final response = await _httpClient.get(uri).timeout(timeout);
      _cardLog.info(
        'HTTP GET $uri -> ${response.statusCode} em ${stopwatch.elapsed}',
      );
      return response;
    } on TimeoutException catch (error) {
      _cardLog.warning('Timeout HTTP GET $uri', error);
      throw CardUnreachableException(uri, error);
    } on SocketException catch (error) {
      _cardLog.warning('Socket indisponível em HTTP GET $uri', error);
      throw CardUnreachableException(uri, error);
    } on http.ClientException catch (error) {
      _cardLog.warning('Falha de cliente em HTTP GET $uri', error);
      throw CardUnreachableException(uri, error);
    }
  }

  Uri _endpoint(String path) => _baseUri.resolve(path);

  Uri _cardPathUri(String path) => _baseUri.resolve(_encodePath(path));
}

typedef CancelToken = CancellationToken;

class CancellationToken {
  bool get isCancelled => _isCancelled;

  bool _isCancelled = false;
  final Set<void Function()> _listeners = <void Function()>{};

  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    for (final listener in _listeners.toList()) {
      listener();
    }
    _listeners.clear();
  }

  void _addListener(void Function() listener) {
    if (_isCancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void _removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

sealed class CardException implements Exception {
  const CardException(this.message);

  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

class CardUnreachableException extends CardException {
  CardUnreachableException(this.uri, this.cause)
    : super('Não foi possível acessar o cartão em $uri.');

  final Uri uri;
  final Object cause;
}

class CardParseException extends CardException {
  const CardParseException(super.message);
}

class CardHttpException extends CardException {
  CardHttpException(this.statusCode, this.uri)
    : super('O cartão respondeu com HTTP $statusCode em $uri.');

  final int statusCode;
  final Uri uri;
}

class CardDeleteException extends CardException {
  CardDeleteException({required this.statusCode, required this.body})
    : super(
        statusCode == null
            ? body
            : 'Falha ao excluir o arquivo: HTTP $statusCode, resposta "$body".',
      );

  final int? statusCode;
  final String body;
}

class FolderNotEmptyException extends CardException {
  FolderNotEmptyException(this.path, this.count)
    : super('A pasta "$path" não está vazia ($count itens).');

  final String path;
  final int count;
}

enum _RequestPriority { high, normal, low }

class _RequestQueue {
  _RequestQueue(this.maxConcurrent) {
    if (maxConcurrent < 1) {
      throw ArgumentError.value(
        maxConcurrent,
        'maxConcurrent',
        'Deve ser maior que zero.',
      );
    }
  }

  final int maxConcurrent;
  final List<_QueuedRequest> _pending = <_QueuedRequest>[];
  int _inFlight = 0;

  Future<T> schedule<T>(
    Future<T> Function() operation, {
    required _RequestPriority priority,
    CancellationToken? cancellationToken,
    T Function()? onCancelled,
  }) {
    if (cancellationToken?.isCancelled ?? false) {
      return Future<T>.value(onCancelled!());
    }

    final completer = Completer<T>();
    late final _QueuedRequest request;

    void cancelPending() {
      if (request.started || !_pending.remove(request)) {
        return;
      }
      cancellationToken?._removeListener(cancelPending);
      completer.complete(onCancelled!());
    }

    request = _QueuedRequest(
      priority: priority,
      start: () {
        request.started = true;
        cancellationToken?._removeListener(cancelPending);
        _inFlight++;
        _run(operation, completer);
      },
    );
    _pending.add(request);
    cancellationToken?._addListener(cancelPending);
    _drain();
    return completer.future;
  }

  Future<void> _run<T>(
    Future<T> Function() operation,
    Completer<T> completer,
  ) async {
    try {
      completer.complete(await operation());
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    } finally {
      _inFlight--;
      _drain();
    }
  }

  void _drain() {
    while (_inFlight < maxConcurrent && _pending.isNotEmpty) {
      var nextIndex = 0;
      for (var index = 1; index < _pending.length; index++) {
        if (_pending[index].priority.index <
            _pending[nextIndex].priority.index) {
          nextIndex = index;
        }
      }
      _pending.removeAt(nextIndex).start();
    }
  }
}

class _QueuedRequest {
  _QueuedRequest({required this.priority, required this.start});

  final _RequestPriority priority;
  final void Function() start;
  bool started = false;
}

void _validateDeletePath(String path) {
  final segments = path.split('/').where((segment) => segment.isNotEmpty);
  if (segments.length < 2) {
    throw CardDeleteException(
      statusCode: null,
      body: 'O caminho deve identificar um arquivo dentro de uma pasta.',
    );
  }
}

void _validateFolderDeletePath(String path) {
  final segments = path
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .toList();
  if (segments.length < 2) {
    throw ArgumentError.value(
      path,
      'path',
      'Não é permitido apagar a raiz nem a pasta /DCIM.',
    );
  }
}

DateTime? _decodeFatDateTime(int date, int time) {
  final year = (date >> 9) + 1980;
  final month = (date >> 5) & 15;
  final day = date & 31;
  if (month == 0 || day == 0 || month > 12) {
    return null;
  }

  final hour = time >> 11;
  final minute = (time >> 5) & 63;
  final second = (time & 31) * 2;
  if (hour > 23 || minute > 59 || second > 59) {
    return null;
  }

  final result = DateTime(year, month, day, hour, minute, second);
  if (result.year != year ||
      result.month != month ||
      result.day != day ||
      result.hour != hour ||
      result.minute != minute ||
      result.second != second) {
    return null;
  }
  return result;
}

Future<Uint8List> _readDownload(
  http.StreamedResponse response,
  DownloadProgress? onProgress,
) async {
  final bytes = BytesBuilder(copy: false);
  var receivedBytes = 0;
  await for (final chunk in response.stream) {
    bytes.add(chunk);
    receivedBytes += chunk.length;
    onProgress?.call(receivedBytes, response.contentLength);
  }
  return bytes.takeBytes();
}

String _encodePath(String path) {
  final segments = path
      .split('/')
      .where((segment) => segment.isNotEmpty)
      .map(Uri.encodeComponent)
      .join('/');
  return '/$segments';
}
