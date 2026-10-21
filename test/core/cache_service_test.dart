import 'dart:io';
import 'dart:typed_data';

import 'package:camera_cam/core/cache_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory cacheDirectory;

  setUp(() async {
    cacheDirectory = await Directory.systemTemp.createTemp('camera_cam_cache_');
  });

  tearDown(() async {
    if (await cacheDirectory.exists()) {
      await cacheDirectory.delete(recursive: true);
    }
  });

  test('puts and gets photos and thumbnails in separate caches', () async {
    final service = CacheService(cacheDirectory: cacheDirectory);
    final photo = Uint8List.fromList(<int>[1, 2, 3]);
    final thumbnail = Uint8List.fromList(<int>[0xFF, 0xD8]);

    await service.put('/DCIM/PHOTO.JPG', photo, fileSize: 3);
    await service.putThumb('/DCIM/PHOTO.JPG', thumbnail, fileSize: 3);

    expect(await service.get('/DCIM/PHOTO.JPG', fileSize: 3), photo);
    expect(await service.getThumb('/DCIM/PHOTO.JPG', fileSize: 3), thumbnail);
    expect(await Directory('${cacheDirectory.path}/photos').exists(), isTrue);
    expect(await Directory('${cacheDirectory.path}/thumbs').exists(), isTrue);
  });

  test('invalidates cached data when the card file size changes', () async {
    final service = CacheService(cacheDirectory: cacheDirectory);
    await service.put(
      '/DCIM/PHOTO.JPG',
      Uint8List.fromList(<int>[1, 2, 3]),
      fileSize: 3,
    );

    expect(await service.get('/DCIM/PHOTO.JPG', fileSize: 4), isNull);
    expect(await service.get('/DCIM/PHOTO.JPG', fileSize: 3), isNull);
  });

  test('remove deletes both the photo and its thumbnail', () async {
    final service = CacheService(cacheDirectory: cacheDirectory);
    await service.put(
      '/DCIM/PHOTO.JPG',
      Uint8List.fromList(<int>[1, 2, 3]),
      fileSize: 3,
    );
    await service.putThumb(
      '/DCIM/PHOTO.JPG',
      Uint8List.fromList(<int>[0xFF, 0xD8]),
      fileSize: 3,
    );

    await service.remove('/DCIM/PHOTO.JPG');

    expect(await service.get('/DCIM/PHOTO.JPG', fileSize: 3), isNull);
    expect(await service.getThumb('/DCIM/PHOTO.JPG', fileSize: 3), isNull);
    expect(await service.sizeOnDisk(), 0);
  });

  test('removes the oldest files when the size limit is exceeded', () async {
    final service = CacheService(
      cacheDirectory: cacheDirectory,
      maxSizeBytes: 5,
    );
    await service.put(
      '/DCIM/OLD.JPG',
      Uint8List.fromList(<int>[1, 2, 3]),
      fileSize: 3,
    );
    final oldFile = await Directory('${cacheDirectory.path}/photos')
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .single;
    await oldFile.setLastModified(DateTime(2000));

    await service.put(
      '/DCIM/NEW.JPG',
      Uint8List.fromList(<int>[4, 5, 6]),
      fileSize: 3,
    );

    expect(await service.get('/DCIM/OLD.JPG', fileSize: 3), isNull);
    expect(
      await service.get('/DCIM/NEW.JPG', fileSize: 3),
      Uint8List.fromList(<int>[4, 5, 6]),
    );
    expect(await service.sizeOnDisk(), 3);
  });

  test('clear removes all cached data', () async {
    final service = CacheService(cacheDirectory: cacheDirectory);
    await service.put('/DCIM/PHOTO.JPG', Uint8List.fromList(<int>[1, 2, 3]));
    await service.putThumb(
      '/DCIM/OTHER.JPG',
      Uint8List.fromList(<int>[0xFF, 0xD8]),
    );

    await service.clear();

    expect(await service.sizeOnDisk(), 0);
  });
}
