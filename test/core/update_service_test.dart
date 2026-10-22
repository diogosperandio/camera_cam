import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera_cam/core/update_service.dart';
import 'package:camera_cam/models/update_info.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('fetchLatest', () {
    for (final platform in <String>['linux', 'windows']) {
      test('selects the exact $platform asset and checksum', () async {
        final service = UpdateService(
          MockClient((request) async {
            expect(request.headers['accept'], 'application/vnd.github+json');
            return http.Response(jsonEncode(_releaseJson()), 200);
          }),
          repo: 'OWNER/REPO',
          platform: platform,
        );
        final info = await service.fetchLatest('1.0.0+2');
        expect(info?.version, '1.0.3');
        expect(info?.assetName, contains(platform));
        expect(
          info?.assetUrl,
          endsWith(platform == 'linux' ? '.tar.gz' : '.zip'),
        );
        expect(info?.sha256Url, endsWith('.sha256'));
      });
    }

    test('returns null for equal, older or prerelease tags', () async {
      for (final tag in <String>['v1.0.3', 'v1.0.2', 'v1.2.3-beta']) {
        final service = UpdateService(
          MockClient(
            (_) async => http.Response(jsonEncode(_releaseJson(tag: tag)), 200),
          ),
          platform: 'linux',
        );
        expect(await service.fetchLatest('1.0.3'), isNull);
      }
    });

    test(
      'returns page-only information when platform asset is absent',
      () async {
        final json = _releaseJson()..['assets'] = <Object>[];
        final service = UpdateService(
          MockClient((_) async => http.Response(jsonEncode(json), 200)),
          platform: 'linux',
        );
        final info = await service.fetchLatest('1.0.0');
        expect(info?.assetUrl, isNull);
        expect(info?.pageUrl, contains('/releases/tag/'));
      },
    );

    test('maps rate limiting and network failures', () async {
      final limited = UpdateService(
        MockClient((_) async => http.Response('API rate limit exceeded', 403)),
        platform: 'linux',
      );
      expect(
        limited.fetchLatest('1.0.0'),
        throwsA(isA<UpdateRateLimitException>()),
      );
      final offline = UpdateService(
        MockClient((_) async => throw const SocketException('offline')),
        platform: 'linux',
      );
      expect(
        offline.fetchLatest('1.0.0'),
        throwsA(isA<UpdateNetworkException>()),
      );
      final timedOut = UpdateService(
        MockClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          return http.Response('{}', 200);
        }),
        platform: 'linux',
        fetchTimeout: const Duration(milliseconds: 1),
      );
      expect(
        timedOut.fetchLatest('1.0.0'),
        throwsA(isA<UpdateNetworkException>()),
      );
    });
  });

  group('download', () {
    late Directory directory;
    setUp(
      () async =>
          directory = await Directory.systemTemp.createTemp('update_test_'),
    );
    tearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test('keeps a download with a matching checksum', () async {
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final service = UpdateService(
        MockClient(
          (request) async => request.url.path.endsWith('.sha256')
              ? http.Response('${sha256.convert(bytes)}  update.tar.gz', 200)
              : http.Response.bytes(bytes, 200),
        ),
        platform: 'linux',
      );
      final file = await service.download(_info(), directory);
      expect(await file.readAsBytes(), bytes);
    });

    test('deletes a download with a wrong checksum', () async {
      final service = UpdateService(
        MockClient(
          (request) async => request.url.path.endsWith('.sha256')
              ? http.Response(
                  '${List<String>.filled(64, '0').join()}  update.tar.gz',
                  200,
                )
              : http.Response.bytes(<int>[1, 2, 3], 200),
        ),
        platform: 'linux',
      );
      await expectLater(
        service.download(_info(), directory),
        throwsA(isA<UpdateIntegrityException>()),
      );
      expect(await File('${directory.path}/update.tar.gz').exists(), isFalse);
    });

    test(
      'rejects missing checksum and untrusted URLs before requesting',
      () async {
        var requests = 0;
        final service = UpdateService(
          MockClient((_) async {
            requests++;
            return http.Response('', 200);
          }),
        );
        await expectLater(
          service.download(_info(sha256Url: null), directory),
          throwsA(isA<UpdateIntegrityException>()),
        );
        await expectLater(
          service.download(
            _info(assetUrl: 'http://evil.example/update'),
            directory,
          ),
          throwsA(isA<UpdateIntegrityException>()),
        );
        expect(requests, 0);
      },
    );
  });
}

Map<String, Object> _releaseJson({String tag = 'v1.0.3'}) => <String, Object>{
  'tag_name': tag,
  'name': 'EZ Share Viewer $tag',
  'html_url': 'https://github.com/OWNER/REPO/releases/tag/$tag',
  'body': '## Novidades\n- Girar foto 90 graus',
  'draft': false,
  'prerelease': false,
  'assets': <Object>[
    for (final name in <String>[
      'ezshare_viewer-v1.0.3-linux-x64.tar.gz',
      'ezshare_viewer-v1.0.3-linux-x64.tar.gz.sha256',
      'ezshare_viewer-v1.0.3-windows-x64.zip',
      'ezshare_viewer-v1.0.3-windows-x64.zip.sha256',
    ])
      <String, Object>{
        'name': name,
        'size': 100,
        'browser_download_url':
            'https://github.com/OWNER/REPO/releases/download/v1.0.3/$name',
      },
  ],
};

UpdateInfo _info({
  String? assetUrl =
      'https://github.com/OWNER/REPO/releases/download/v1/update.tar.gz',
  String? sha256Url =
      'https://github.com/OWNER/REPO/releases/download/v1/update.tar.gz.sha256',
}) => UpdateInfo(
  version: '1.0.3',
  tag: 'v1.0.3',
  notes: '',
  pageUrl: 'https://github.com/OWNER/REPO/releases/tag/v1.0.3',
  assetName: 'update.tar.gz',
  assetUrl: assetUrl,
  assetSize: 3,
  sha256Url: sha256Url,
);
