import 'package:camera_cam/models/card_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('fullPath', () {
    test('joins a name to the root path', () {
      const item = CardItem(
        name: 'photo.jpg',
        parentPath: '/',
        size: 1024,
        isDir: false,
      );

      expect(item.fullPath, '/photo.jpg');
    });

    test('joins a name to a nested path', () {
      const item = CardItem(
        name: 'IMG_0001.CR3',
        parentPath: '/DCIM/100CANON',
        size: 2048,
        isDir: false,
      );

      expect(item.fullPath, '/DCIM/100CANON/IMG_0001.CR3');
    });
  });

  test('identifies image and raw extensions without case sensitivity', () {
    const image = CardItem(
      name: 'preview.JPEG',
      parentPath: '/',
      size: 10,
      isDir: false,
    );
    const raw = CardItem(
      name: 'capture.NeF',
      parentPath: '/',
      size: 20,
      isDir: false,
    );

    expect(image.isImage, isTrue);
    expect(image.isRaw, isFalse);
    expect(raw.isImage, isFalse);
    expect(raw.isRaw, isTrue);
  });
}
