import 'dart:async';
import 'dart:typed_data';

import 'package:camera_cam/core/card_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:logging/logging.dart';

const fixtureA = '''WLANSD_FILELIST
,DCIM,0,16,19011,0
''';

const fixtureB = '''WLANSD_FILELIST
/DCIM,100__TSB,0,16,19011,0
/DCIM,101NC1J1,0,16,20050,18930
/DCIM,199NC1J1,0,16,15775,43008
''';

const fixtureC = '''WLANSD_FILELIST
/DCIM/199NC1J1,DSC_0333.JPG,2837744,32,15775,43008
/DCIM/199NC1J1,DSC_0242.JPG,2847636,32,15775,43008
/DCIM/199NC1J1,DSC_0554.JPG,2536962,32,15775,43008
/DCIM/199NC1J1,DSC_0247.JPG,2633774,32,15775,43008
''';

void main() {
  group('parseFileList', () {
    test('parses fixture A', () {
      final items = parseFileList(fixtureA, '/');

      expect(items, hasLength(1));
      expect(items.single.name, 'DCIM');
      expect(items.single.fullPath, '/DCIM');
      expect(items.single.isDir, isTrue);
      expect(items.single.dateTime, DateTime(2017, 2, 3));
    });

    test('parses fixture B with its real FAT dates', () {
      final items = parseFileList(fixtureB, '/DCIM');

      expect(items.map((item) => item.name), <String>[
        '100__TSB',
        '101NC1J1',
        '199NC1J1',
      ]);
      expect(items[0].dateTime, DateTime(2017, 2, 3));
      expect(items[1].dateTime, DateTime(2019, 2, 18, 9, 15, 36));
    });

    test('sorts fixture C and preserves sizes and dates', () {
      final items = parseFileList(fixtureC, '/DCIM/199NC1J1');

      expect(items.map((item) => item.name), <String>[
        'DSC_0242.JPG',
        'DSC_0247.JPG',
        'DSC_0333.JPG',
        'DSC_0554.JPG',
      ]);
      expect(items.map((item) => item.size), <int>[
        2847636,
        2633774,
        2837744,
        2536962,
      ]);
      expect(
        items.every((item) => item.dateTime == DateTime(2010, 12, 31, 21)),
        isTrue,
      );
    });

    test(
      'preserves commas, accepts a blank final line and a zero FAT date',
      () {
        const body = '''WLANSD_FILELIST
/DCIM/100CANON,IMG,WITH,COMMAS.JPG,123,32,0,0

''';

        final item = parseFileList(body, '/DCIM/100CANON').single;

        expect(item.name, 'IMG,WITH,COMMAS.JPG');
        expect(item.size, 123);
        expect(item.dateTime, isNull);
      },
    );

    test('returns an empty list when the response only has the header', () {
      expect(parseFileList('WLANSD_FILELIST\n', '/'), isEmpty);
    });

    test('rejects a response without the FlashAir header', () {
      expect(
        () => parseFileList('<html>offline</html>', '/'),
        throwsA(isA<CardParseException>()),
      );
    });
  });

  group('CardClient requests', () {
    test('listDir sends the command and parses the response', () async {
      final client = CardClient(
        'http://flashair',
        MockClient((request) async {
          expect(
            request.url.toString(),
            'http://flashair/command.cgi?op=100&DIR=/',
          );
          return http.Response(fixtureA, 200);
        }),
      );

      expect((await client.listDir('/')).single.name, 'DCIM');
    });

    test('download encodes segments and reports progress', () async {
      final progress = <int>[];
      final client = CardClient(
        'http://flashair',
        MockClient.streaming((request, _) async {
          expect(
            request.url.toString(),
            'http://flashair/DCIM/100%20CANON/IMG%2C0001.JPG',
          );
          return http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              <int>[1, 2],
              <int>[3],
            ]),
            200,
            contentLength: 3,
          );
        }),
      );

      final result = await client.download(
        '/DCIM/100 CANON/IMG,0001.JPG',
        onProgress: (received, _) => progress.add(received),
      );

      expect(result, Uint8List.fromList(<int>[1, 2, 3]));
      expect(progress, <int>[2, 3]);
    });

    test('thumbnail returns null for HTTP 500 or non-JPEG bytes', () async {
      final client = CardClient(
        'http://flashair',
        MockClient((request) async {
          if (request.url.query.contains('HTTP_500')) {
            return http.Response('', 500);
          }
          return http.Response.bytes(<int>[0x89, 0x50, 0x4E, 0x47], 200);
        }),
      );

      expect(await client.thumbnail('/DCIM/HTTP_500.JPG'), isNull);
      expect(await client.thumbnail('/DCIM/NOT_JPEG.JPG'), isNull);
    });

    test('thumbnail accepts bytes beginning with the JPEG signature', () async {
      final client = CardClient(
        'http://flashair',
        MockClient((request) async {
          expect(
            request.url.toString(),
            'http://flashair/thumbnail.cgi?/DCIM/IMG%200001.JPG',
          );
          return http.Response.bytes(<int>[0xFF, 0xD8, 0xFF], 200);
        }),
      );

      expect(await client.thumbnail('/DCIM/IMG 0001.JPG'), <int>[
        0xFF,
        0xD8,
        0xFF,
      ]);
    });

    test('never runs more requests than maxConcurrent', () async {
      var inFlight = 0;
      var maximumInFlight = 0;
      final release = Completer<void>();
      final client = CardClient(
        'http://flashair',
        MockClient((_) async {
          inFlight++;
          maximumInFlight = inFlight > maximumInFlight
              ? inFlight
              : maximumInFlight;
          await release.future;
          inFlight--;
          return http.Response.bytes(<int>[0xFF, 0xD8], 200);
        }),
      );

      final requests = List<Future<Uint8List?>>.generate(
        5,
        (index) => client.thumbnail('/DCIM/$index.JPG'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(maximumInFlight, 2);
      release.complete();
      await Future.wait(requests);
      expect(maximumInFlight, 2);
    });

    test('runs a queued download before queued thumbnails', () async {
      final firstRequestStarted = Completer<void>();
      final releaseFirstRequest = Completer<void>();
      final requestOrder = <String>[];
      final client = CardClient(
        'http://flashair',
        MockClient((request) async {
          requestOrder.add(request.url.toString());
          if (requestOrder.length == 1) {
            firstRequestStarted.complete();
            await releaseFirstRequest.future;
          }
          if (request.url.path.endsWith('.JPG')) {
            return http.Response.bytes(<int>[1, 2, 3], 200);
          }
          return http.Response.bytes(<int>[0xFF, 0xD8], 200);
        }),
        maxConcurrent: 1,
      );
      final firstThumbnail = client.thumbnail('/DCIM/FIRST.THUMB');
      await firstRequestStarted.future;
      final pendingThumbnail = client.thumbnail('/DCIM/SECOND.THUMB');
      final download = client.download('/DCIM/SELECTED.JPG');

      releaseFirstRequest.complete();
      await Future.wait<Object?>(<Future<Object?>>[
        firstThumbnail,
        pendingThumbnail,
        download,
      ]);

      expect(requestOrder, <String>[
        'http://flashair/thumbnail.cgi?/DCIM/FIRST.THUMB',
        'http://flashair/DCIM/SELECTED.JPG',
        'http://flashair/thumbnail.cgi?/DCIM/SECOND.THUMB',
      ]);
    });

    test('a cancellation token removes a pending thumbnail', () async {
      final firstRequestStarted = Completer<void>();
      final releaseFirstRequest = Completer<void>();
      var requestCount = 0;
      final client = CardClient(
        'http://flashair',
        MockClient((_) async {
          requestCount++;
          firstRequestStarted.complete();
          await releaseFirstRequest.future;
          return http.Response.bytes(<int>[0xFF, 0xD8], 200);
        }),
        maxConcurrent: 1,
      );
      final first = client.thumbnail('/DCIM/FIRST.JPG');
      await firstRequestStarted.future;
      final token = CancellationToken();
      final pending = client.thumbnail(
        '/DCIM/PENDING.JPG',
        cancellationToken: token,
      );

      token.cancel();

      expect(await pending, isNull);
      expect(requestCount, 1);
      releaseFirstRequest.complete();
      await first;
    });

    test('isUploadEnabled maps response bodies and network errors', () async {
      final enabled = CardClient(
        'http://flashair',
        MockClient((_) async => http.Response(' 1\n', 200)),
      );
      final disabled = CardClient(
        'http://flashair',
        MockClient((_) async => http.Response('0', 200)),
      );
      final unreachable = CardClient(
        'http://flashair',
        MockClient((_) async => throw http.ClientException('offline')),
      );

      expect(await enabled.isUploadEnabled(), isTrue);
      expect(await disabled.isUploadEnabled(), isFalse);
      expect(await unreachable.isUploadEnabled(), isNull);
    });
  });

  group('deleteFile', () {
    test(
      'enables write protection before deleting and accepts SUCCESS',
      () async {
        final urls = <String>[];
        final client = CardClient(
          'http://flashair',
          MockClient((request) async {
            urls.add(request.url.toString());
            return http.Response(
              request.url.query == 'WRITEPROTECT=ON' ? '' : 'Success',
              200,
            );
          }),
        );

        await client.deleteFile('/DCIM/IMG 0001.JPG');

        expect(urls, <String>[
          'http://flashair/upload.cgi?WRITEPROTECT=ON',
          'http://flashair/upload.cgi?DEL=/DCIM/IMG%200001.JPG',
        ]);
      },
    );

    test('throws CardDeleteException for an ERROR response', () async {
      final client = CardClient(
        'http://flashair',
        MockClient((_) async => http.Response('ERROR', 200)),
      );

      expect(
        client.deleteFile('/DCIM/IMG.JPG', writeProtect: false),
        throwsA(isA<CardDeleteException>()),
      );
    });

    test('turns a network error into CardUnreachableException', () async {
      final client = CardClient(
        'http://flashair',
        MockClient((_) async => throw http.ClientException('offline')),
      );

      expect(
        client.deleteFile('/DCIM/IMG.JPG', writeProtect: false),
        throwsA(isA<CardUnreachableException>()),
      );
    });

    test('rejects /DCIM without making a request', () async {
      var requestCount = 0;
      final client = CardClient(
        'http://flashair',
        MockClient((_) async {
          requestCount++;
          return http.Response('SUCCESS', 200);
        }),
      );

      expect(
        () => client.deleteFile('/DCIM'),
        throwsA(isA<CardDeleteException>()),
      );
      expect(requestCount, 0);
    });

    test('logs the path, result and response of a deletion', () async {
      final records = <LogRecord>[];
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(subscription.cancel);
      final client = CardClient(
        'http://flashair',
        MockClient((request) async {
          if (request.url.queryParameters.containsKey('WRITEPROTECT')) {
            return http.Response('SUCCESS', 200);
          }
          return http.Response('ERROR', 200);
        }),
      );

      await expectLater(
        client.deleteFile('/DCIM/PHOTO.JPG'),
        throwsA(isA<CardDeleteException>()),
      );

      final messages = records.map((record) => record.message).join('\n');
      expect(messages, contains('caminho=/DCIM/PHOTO.JPG'));
      expect(messages, contains('resposta=ERROR'));
      expect(messages, contains('Exclusão falhou'));
    });
  });

  group('countFiles', () {
    for (final entry in <(String, int)>[('0', 0), ('12', 12), (' 3\n', 3)]) {
      test('parses "${entry.$1.replaceAll('\n', r'\n')}"', () async {
        final client = CardClient(
          'http://flashair',
          MockClient((request) async {
            expect(request.url.queryParameters['op'], '101');
            expect(request.url.queryParameters['DIR'], '/DCIM/EMPTY');
            return http.Response(entry.$1, 200);
          }),
        );

        expect(await client.countFiles('/DCIM/EMPTY'), entry.$2);
      });
    }

    test('rejects an invalid response body', () async {
      final client = CardClient(
        'http://flashair',
        MockClient((_) async => http.Response('not-a-number', 200)),
      );

      expect(
        client.countFiles('/DCIM/EMPTY'),
        throwsA(isA<CardParseException>()),
      );
    });
  });

  group('deleteEmptyFolder', () {
    test('rejects root and /DCIM without making a request', () async {
      var requests = 0;
      final client = CardClient(
        'http://flashair',
        MockClient((_) async {
          requests++;
          return http.Response('', 200);
        }),
      );

      expect(() => client.deleteEmptyFolder('/'), throwsArgumentError);
      expect(() => client.deleteEmptyFolder('/DCIM'), throwsArgumentError);
      expect(requests, 0);
    });

    test('does not send DEL when listDir contains an item', () async {
      final urls = <String>[];
      final client = CardClient(
        'http://flashair',
        MockClient((request) async {
          urls.add(request.url.toString());
          return http.Response(
            'WLANSD_FILELIST\n/DCIM/EMPTY,PHOTO.JPG,1,32,0,0\n',
            200,
          );
        }),
      );

      await expectLater(
        client.deleteEmptyFolder('/DCIM/EMPTY'),
        throwsA(
          isA<FolderNotEmptyException>().having(
            (error) => error.count,
            'count',
            1,
          ),
        ),
      );
      expect(urls.where((url) => url.contains('DEL=')), isEmpty);
    });

    test('does not send DEL when countFiles is greater than zero', () async {
      final urls = <String>[];
      final client = CardClient(
        'http://flashair',
        MockClient((request) async {
          urls.add(request.url.toString());
          if (request.url.queryParameters['op'] == '100') {
            return http.Response('WLANSD_FILELIST\n', 200);
          }
          return http.Response('2', 200);
        }),
      );

      await expectLater(
        client.deleteEmptyFolder('/DCIM/EMPTY'),
        throwsA(isA<FolderNotEmptyException>()),
      );
      expect(urls.where((url) => url.contains('DEL=')), isEmpty);
    });

    test('checks twice and sends WRITEPROTECT before DEL', () async {
      final urls = <String>[];
      final client = CardClient(
        'http://flashair',
        MockClient((request) async {
          urls.add(request.url.toString());
          if (request.url.queryParameters['op'] == '100') {
            return http.Response('WLANSD_FILELIST\n', 200);
          }
          if (request.url.queryParameters['op'] == '101') {
            return http.Response('0', 200);
          }
          return http.Response('SUCCESS', 200);
        }),
      );

      await client.deleteEmptyFolder('/DCIM/EMPTY');

      expect(urls, <String>[
        'http://flashair/command.cgi?op=100&DIR=/DCIM/EMPTY',
        'http://flashair/command.cgi?op=101&DIR=/DCIM/EMPTY',
        'http://flashair/upload.cgi?WRITEPROTECT=ON',
        'http://flashair/upload.cgi?DEL=/DCIM/EMPTY',
      ]);
    });

    test('turns ERROR into CardDeleteException', () async {
      final client = CardClient(
        'http://flashair',
        MockClient((request) async {
          if (request.url.queryParameters['op'] == '100') {
            return http.Response('WLANSD_FILELIST\n', 200);
          }
          if (request.url.queryParameters['op'] == '101') {
            return http.Response('0', 200);
          }
          if (request.url.queryParameters.containsKey('WRITEPROTECT')) {
            return http.Response('SUCCESS', 200);
          }
          return http.Response('ERROR', 200);
        }),
      );

      expect(
        client.deleteEmptyFolder('/DCIM/EMPTY'),
        throwsA(isA<CardDeleteException>()),
      );
    });

    test('turns a network error into CardUnreachableException', () async {
      final client = CardClient(
        'http://flashair',
        MockClient((_) async => throw http.ClientException('offline')),
      );

      expect(
        client.deleteEmptyFolder('/DCIM/EMPTY'),
        throwsA(isA<CardUnreachableException>()),
      );
    });
  });
}
