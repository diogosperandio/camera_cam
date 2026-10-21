import 'package:camera_cam/core/wifi_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseNmcliList', () {
    test('removes empty and duplicate SSIDs and sorts the result', () {
      const output = 'Studio WiFi\nCamera\n\nCamera\n';

      expect(parseNmcliList(output), <String>['Camera', 'Studio WiFi']);
    });

    test('unescapes colons and backslashes', () {
      const output = 'Camera\\:WiFi\nCasa\\\\Fundos\n';

      expect(parseNmcliList(output), <String>['Camera:WiFi', r'Casa\Fundos']);
    });
  });

  group('parseNetshNetworks', () {
    test('parses output in English', () {
      const output = '''
Interface name : Wi-Fi
There are 3 networks currently visible.

SSID 1 : Studio WiFi
    Network type            : Infrastructure
SSID 2 : Camera
    Network type            : Infrastructure
SSID 3 : Camera
''';

      expect(parseNetshNetworks(output), <String>['Camera', 'Studio WiFi']);
    });

    test('parses output in Portuguese using Nome labels', () {
      const output = '''
Nome da Interface : Wi-Fi
Há 2 redes visíveis no momento.

Nome 1 : FlashAir
    Tipo de rede            : Infraestrutura
Nome da rede 2 : Casa
    Tipo de rede            : Infraestrutura
''';

      expect(parseNetshNetworks(output), <String>['Casa', 'FlashAir']);
    });
  });

  group('parseNetshInterfaces', () {
    test('parses a connected interface in English', () {
      const output = '''
    Name                   : Wi-Fi
    State                  : connected
    SSID                   : Studio WiFi
    BSSID                  : 00:11:22:33:44:55
''';

      expect(parseNetshInterfaces(output), 'Studio WiFi');
    });

    test('parses a connected interface in Portuguese', () {
      const output = '''
    Nome                   : Wi-Fi
    Estado                 : conectado
    SSID                   : FlashAir
    BSSID                  : 00:11:22:33:44:55
''';

      expect(parseNetshInterfaces(output), 'FlashAir');
    });

    test('returns null when the interface is disconnected', () {
      const output = '''
    Name                   : Wi-Fi
    State                  : disconnected
''';

      expect(parseNetshInterfaces(output), isNull);
    });
  });
}
