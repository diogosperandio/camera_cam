import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path;
import 'package:toshiba_flashair_wifi_viewer/core/app_constants.dart';
import 'package:toshiba_flashair_wifi_viewer/core/version_utils.dart';
import 'package:toshiba_flashair_wifi_viewer/models/update_info.dart';

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
    Directory? cacheDirectory,
    this.fetchTimeout = const Duration(seconds: 10),
    this.downloadTimeout = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : platform = platform ?? Platform.operatingSystem,
       cacheDirectory = cacheDirectory ?? Directory.systemTemp,
       _now = now ?? DateTime.now;

  final http.Client client;
  final String repo;
  final String platform;
  final Directory cacheDirectory;
  final Duration fetchTimeout;
  final Duration downloadTimeout;
  final DateTime Function() _now;
  final Logger _log = Logger('UpdateService');

  File get markerFile => File(
    path.join(cacheDirectory.path, 'updates', 'data', 'just_updated.txt'),
  );

  @override
  Future<UpdateInfo?> fetchLatest(String currentVersion) async {
    final current = parseVersion(currentVersion);
    if (current == null) {
      throw const UpdateHttpException('A versão instalada é inválida.');
    }
    if (repo.trim().isEmpty) return null;
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
      if (!RegExp(r'^v\d+\.\d+\.\d+$').hasMatch(tag)) return null;
      final latest = parseVersion(tag)!;
      if (compareVersions(latest, current) <= 0 ||
          await _recentlyInstalled(tag)) {
        return null;
      }

      final expectedName = switch (platform) {
        'linux' => '$assetPrefix-$tag-linux-x64.tar.gz',
        'windows' => '$assetPrefix-$tag-windows-x64.zip',
        _ => '',
      };
      Map<String, dynamic>? asset;
      Map<String, dynamic>? checksum;
      for (final candidate
          in (decoded['assets'] as List? ?? const <Object>[])
              .whereType<Map<String, dynamic>>()) {
        if (candidate['name'] == expectedName) asset = candidate;
        if (candidate['name'] == '$expectedName.sha256') checksum = candidate;
      }
      final digestValue = asset?['digest'] as String?;
      final digest =
          digestValue != null &&
              RegExp(r'^sha256:[a-fA-F0-9]{64}$').hasMatch(digestValue)
          ? digestValue.substring(7).toLowerCase()
          : null;
      final plainNotes = _plainText(decoded['body'] as String? ?? '');
      final info = UpdateInfo(
        version: latest.toString(),
        tag: tag,
        notes: plainNotes.length > 2000
            ? plainNotes.substring(0, 2000)
            : plainNotes,
        pageUrl:
            decoded['html_url'] as String? ??
            'https://github.com/$repo/releases',
        assetName: expectedName,
        assetUrl: asset?['browser_download_url'] as String?,
        assetSize: (asset?['size'] as num?)?.toInt() ?? 0,
        digest: digest,
        sha256Url: checksum?['browser_download_url'] as String?,
      );
      _log.info(
        'Release $tag: asset=$expectedName; tamanho=${info.assetSize}; digest=${digest != null}',
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
    if (info.digest == null && info.sha256Url == null) {
      throw const UpdateIntegrityException('a release não publica checksum');
    }
    final checksumUri = info.digest == null
        ? _trustedUri(info.sha256Url)
        : null;
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
    Uri? checksumUri,
    File target,
    File partial,
    UpdateProgress? onProgress,
    UpdateCancelToken? cancelToken,
    UpdatePhaseCallback? onVerifying,
  ) async {
    String expected;
    var source = 'digest';
    if (info.digest case final digest?) {
      expected = digest;
    } else {
      source = '.sha256';
      final response = await _get(checksumUri!);
      final tokens = response.body.trim().split(RegExp(r'\s+'));
      final token = tokens.isEmpty ? '' : tokens.first;
      if (!RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(token)) {
        throw const UpdateIntegrityException('checksum inválido na release');
      }
      expected = token.toLowerCase();
    }

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
      _throwHttp(response.statusCode, await response.stream.bytesToString());
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
      await _deleteIfPresent(downloaded);
      throw const UpdateCancelledException();
    }
    final calculated = await Isolate.run(
      () async => (await sha256.bind(File(downloaded.path).openRead()).first)
          .toString(),
    );
    _log.info(
      'SHA-256 origem=$source; esperado=$expected; calculado=$calculated',
    );
    if (cancelToken?.isCancelled ?? false) {
      await _deleteIfPresent(downloaded);
      throw const UpdateCancelledException();
    }
    if (expected != calculated) {
      await _deleteIfPresent(downloaded);
      throw const UpdateIntegrityException(
        'O arquivo baixado falhou na verificação SHA-256.',
      );
    }
    return downloaded;
  }

  Future<http.Response> _get(Uri uri) async {
    try {
      final response = await client.get(uri, headers: _headers);
      if (response.statusCode != 200) {
        _throwHttp(response.statusCode, response.body);
      }
      return response;
    } on SocketException catch (error) {
      throw UpdateNetworkException(error);
    } on http.ClientException catch (error) {
      throw UpdateNetworkException(error);
    }
  }

  Future<bool> _recentlyInstalled(String tag) async {
    if (!await markerFile.exists()) return false;
    try {
      final lines = await markerFile.readAsLines();
      final timestamp = lines.length > 1 ? DateTime.tryParse(lines[1]) : null;
      return lines.isNotEmpty &&
          lines.first == tag &&
          timestamp != null &&
          _now().difference(timestamp) < const Duration(hours: 24);
    } catch (_) {
      return false;
    }
  }

  Uri _trustedUri(String? value) {
    final uri = Uri.tryParse(value ?? '');
    final host = uri?.host.toLowerCase() ?? '';
    final trusted =
        host == 'github.com' ||
        host == 'objects.githubusercontent.com' ||
        host == 'release-assets.githubusercontent.com' ||
        host.endsWith('.githubusercontent.com');
    if (uri == null || uri.scheme != 'https' || !trusted) {
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
    'User-Agent': appName,
  };
}

String _plainText(String value) => value
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll(RegExp(r'^[#>*+-]+\s*', multiLine: true), '')
    .replaceAll(RegExp(r'\[([^\]]+)\]\([^\)]+\)'), r'$1')
    .trim();

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
