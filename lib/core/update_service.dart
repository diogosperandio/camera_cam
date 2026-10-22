import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:toshiba_flashair_wifi_viewer/core/app_constants.dart';
import 'package:toshiba_flashair_wifi_viewer/core/version_utils.dart';
import 'package:toshiba_flashair_wifi_viewer/models/update_info.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;

typedef UpdateProgress = void Function(int received, int? total);
typedef UpdatePhaseCallback = void Function();

abstract interface class UpdateRepository {
  Future<UpdateInfo?> fetchLatest(String currentVersion);
  Future<File> download(
    UpdateInfo info,
    Directory directory, {
    UpdateProgress? onProgress,
    UpdateCancelToken? cancelToken,
    UpdatePhaseCallback? onVerifying,
  });
}

class UpdateCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

class UpdateService implements UpdateRepository {
  UpdateService(
    this.client, {
    this.repo = githubRepo,
    String? platform,
    this.fetchTimeout = const Duration(seconds: 10),
    this.downloadTimeout = const Duration(minutes: 5),
  }) : platform = platform ?? Platform.operatingSystem;

  final http.Client client;
  final String repo;
  final String platform;
  final Duration fetchTimeout;
  final Duration downloadTimeout;
  final Logger _log = Logger('UpdateService');

  @override
  Future<UpdateInfo?> fetchLatest(String currentVersion) async {
    final current = parseVersion(currentVersion);
    if (current == null) {
      throw const UpdateHttpException('A versão instalada é inválida.');
    }
    final uri = Uri.parse('https://api.github.com/repos/$repo/releases/latest');
    try {
      final response = await client
          .get(uri, headers: _headers)
          .timeout(fetchTimeout);
      if (response.statusCode != 200) {
        _throwHttp(response.statusCode, response.body);
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const UpdateHttpException('Resposta inválida do GitHub.');
      }
      final tag = decoded['tag_name'] as String? ?? '';
      final latest = parseVersion(tag);
      if (latest == null || compareVersions(latest, current) <= 0) return null;

      final version = latest.toString();
      final expectedName = switch (platform) {
        'linux' => 'ezshare_viewer-v$version-linux-x64.tar.gz',
        'windows' => 'ezshare_viewer-v$version-windows-x64.zip',
        _ => '',
      };
      Map<String, dynamic>? asset;
      Map<String, dynamic>? checksum;
      final assets = decoded['assets'];
      if (assets is List) {
        for (final candidate in assets.whereType<Map<String, dynamic>>()) {
          if (candidate['name'] == expectedName) asset = candidate;
          if (candidate['name'] == '$expectedName.sha256') checksum = candidate;
        }
      }
      final notes = decoded['body'] as String? ?? '';
      final info = UpdateInfo(
        version: version,
        tag: tag,
        notes: notes.length > 2000 ? notes.substring(0, 2000) : notes,
        pageUrl:
            decoded['html_url'] as String? ??
            'https://github.com/$repo/releases',
        assetName: expectedName,
        assetUrl: asset?['browser_download_url'] as String?,
        assetSize: (asset?['size'] as num?)?.toInt() ?? 0,
        sha256Url: checksum?['browser_download_url'] as String?,
      );
      _log.info(
        'Release ${info.tag}: asset=${info.assetName}; tamanho=${info.assetSize}',
      );
      return info;
    } on UpdateException {
      rethrow;
    } on TimeoutException catch (error) {
      throw UpdateNetworkException(error);
    } on SocketException catch (error) {
      throw UpdateNetworkException(error);
    } on http.ClientException catch (error) {
      throw UpdateNetworkException(error);
    } on FormatException catch (error) {
      throw UpdateHttpException('Resposta inválida do GitHub.', error);
    }
  }

  @override
  Future<File> download(
    UpdateInfo info,
    Directory directory, {
    UpdateProgress? onProgress,
    UpdateCancelToken? cancelToken,
    UpdatePhaseCallback? onVerifying,
  }) async {
    final assetUri = _trustedUri(info.assetUrl);
    if (info.sha256Url == null) {
      throw const UpdateIntegrityException('release sem checksum');
    }
    final checksumUri = _trustedUri(info.sha256Url);
    await directory.create(recursive: true);
    final target = File(path.join(directory.path, info.assetName));
    final partial = File('${target.path}.part');
    try {
      return await _downloadAndVerify(
        info,
        assetUri,
        checksumUri,
        target,
        partial,
        onProgress,
        cancelToken,
        onVerifying,
      ).timeout(downloadTimeout);
    } on TimeoutException catch (error) {
      await _deleteIfPresent(partial);
      await _deleteIfPresent(target);
      throw UpdateNetworkException(error);
    } catch (_) {
      await _deleteIfPresent(partial);
      rethrow;
    }
  }

  Future<File> _downloadAndVerify(
    UpdateInfo info,
    Uri assetUri,
    Uri checksumUri,
    File target,
    File partial,
    UpdateProgress? onProgress,
    UpdateCancelToken? cancelToken,
    UpdatePhaseCallback? onVerifying,
  ) async {
    await _deleteIfPresent(partial);
    final request = http.Request('GET', assetUri)..headers.addAll(_headers);
    http.StreamedResponse response;
    try {
      response = await client.send(request);
    } on SocketException catch (error) {
      throw UpdateNetworkException(error);
    } on http.ClientException catch (error) {
      throw UpdateNetworkException(error);
    }
    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      _throwHttp(response.statusCode, body);
    }
    final sink = partial.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream) {
        if (cancelToken?.isCancelled ?? false) {
          throw const UpdateCancelledException();
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, response.contentLength);
      }
      await sink.close();
    } catch (_) {
      await sink.close();
      rethrow;
    }
    if (cancelToken?.isCancelled ?? false) {
      throw const UpdateCancelledException();
    }
    await _deleteIfPresent(target);
    final downloaded = await partial.rename(target.path);
    onVerifying?.call();
    if (cancelToken?.isCancelled ?? false) {
      throw const UpdateCancelledException();
    }

    http.Response checksumResponse;
    try {
      checksumResponse = await client.get(checksumUri, headers: _headers);
    } on SocketException catch (error) {
      throw UpdateNetworkException(error);
    } on http.ClientException catch (error) {
      throw UpdateNetworkException(error);
    }
    if (checksumResponse.statusCode != 200) {
      _throwHttp(checksumResponse.statusCode, checksumResponse.body);
    }
    if (cancelToken?.isCancelled ?? false) {
      throw const UpdateCancelledException();
    }
    final match = RegExp(r'^\s*([a-fA-F0-9]{64})(?:\s|$)')
        .firstMatch(checksumResponse.body);
    if (match == null) {
      await _deleteIfPresent(downloaded);
      throw const UpdateIntegrityException('checksum inválido na release');
    }
    final expected = match.group(1)!.toLowerCase();
    final calculated = (await sha256.bind(downloaded.openRead()).first)
        .toString();
    _log.info('SHA-256 esperado=$expected; calculado=$calculated');
    if (expected != calculated) {
      await _deleteIfPresent(downloaded);
      throw const UpdateIntegrityException(
        'O arquivo baixado falhou na verificação SHA-256.',
      );
    }
    return downloaded;
  }

  Uri _trustedUri(String? value) {
    final uri = Uri.tryParse(value ?? '');
    final host = uri?.host.toLowerCase() ?? '';
    if (uri == null ||
        uri.scheme != 'https' ||
        !(host == 'github.com' ||
            host.endsWith('.github.com') ||
            host == 'githubusercontent.com' ||
            host.endsWith('.githubusercontent.com'))) {
      throw const UpdateIntegrityException('URL de atualização não confiável.');
    }
    return uri;
  }

  Never _throwHttp(int status, String body) {
    if ((status == 403 || status == 429) &&
        body.toLowerCase().contains('rate limit')) {
      throw UpdateRateLimitException(status);
    }
    throw UpdateHttpException('GitHub respondeu com HTTP $status.');
  }

  Map<String, String> get _headers => const <String, String>{
    'Accept': 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
    'User-Agent': 'ezshare-viewer-update-client',
  };
}

Future<void> _deleteIfPresent(File file) async {
  if (await file.exists()) await file.delete();
}

sealed class UpdateException implements Exception {
  const UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

class UpdateNetworkException extends UpdateException {
  UpdateNetworkException(this.cause) : super('Sem acesso à internet.');
  final Object cause;
}

class UpdateRateLimitException extends UpdateException {
  UpdateRateLimitException(this.status)
    : super('Limite de consultas do GitHub atingido.');
  final int status;
}

class UpdateHttpException extends UpdateException {
  const UpdateHttpException(super.message, [this.cause]);
  final Object? cause;
}

class UpdateIntegrityException extends UpdateException {
  const UpdateIntegrityException(super.message);
}

class UpdateCancelledException extends UpdateException {
  const UpdateCancelledException() : super('Atualização cancelada.');
}
