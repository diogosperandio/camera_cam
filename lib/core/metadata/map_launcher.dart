import 'dart:io';

abstract interface class MapLauncher {
  Future<void> open(double latitude, double longitude);
}

class SystemMapLauncher implements MapLauncher {
  const SystemMapLauncher();

  @override
  Future<void> open(double latitude, double longitude) async {
    final lat = latitude.toStringAsFixed(6);
    final lon = longitude.toStringAsFixed(6);
    final url =
        'https://www.openstreetmap.org/?mlat=$lat&mlon=$lon#map=16/$lat/$lon';
    final result = Platform.isWindows
        ? await Process.run('cmd', <String>['/c', 'start', '', url])
        : await Process.run('xdg-open', <String>[url]);
    if (result.exitCode != 0) {
      throw MapLaunchException(result.stderr.toString().trim());
    }
  }
}

class MapLaunchException implements Exception {
  const MapLaunchException(this.message);
  final String message;
  @override
  String toString() =>
      message.isEmpty ? 'Não foi possível abrir o mapa.' : message;
}
