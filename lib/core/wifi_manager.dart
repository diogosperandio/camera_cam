import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

final Logger _wifiLog = Logger('WifiManager');

abstract class WifiManager {
  factory WifiManager() {
    if (Platform.isLinux) {
      return LinuxWifiManager();
    }
    if (Platform.isWindows) {
      return WindowsWifiManager();
    }
    throw const WifiException(
      'Sistema operacional não suportado. Use Linux ou Windows.',
    );
  }

  Future<List<String>> listNetworks();

  Future<String?> currentSsid();

  Future<void> connect(String ssid);

  Future<void> disconnect(String ssid);
}

class LinuxWifiManager implements WifiManager {
  @override
  Future<List<String>> listNetworks() async {
    final result = await _run('nmcli', const <String>[
      '--terse',
      '--fields',
      'SSID',
      'device',
      'wifi',
      'list',
      '--rescan',
      'yes',
    ]);
    _ensureSuccess(result, 'Não foi possível listar as redes Wi-Fi.');
    return parseNmcliList(result.stdout as String);
  }

  @override
  Future<String?> currentSsid() async {
    final result = await _run('nmcli', const <String>[
      '--terse',
      '--fields',
      'ACTIVE,SSID',
      'device',
      'wifi',
      'list',
    ]);
    _ensureSuccess(result, 'Não foi possível consultar a conexão Wi-Fi atual.');
    return _parseNmcliCurrentSsid(result.stdout as String);
  }

  @override
  Future<void> connect(String ssid) async {
    _validateSsid(ssid);
    final profilesResult = await _run('nmcli', const <String>[
      '--terse',
      '--fields',
      'NAME',
      'connection',
      'show',
    ]);
    _ensureSuccess(
      profilesResult,
      'Não foi possível consultar os perfis Wi-Fi salvos.',
    );

    final profiles = parseNmcliList(profilesResult.stdout as String);
    if (!profiles.contains(ssid)) {
      throw WifiException(_missingProfileMessage(ssid));
    }

    final result = await _run('nmcli', <String>[
      'connection',
      'up',
      'id',
      ssid,
    ]);
    _ensureSuccess(result, 'Não foi possível conectar à rede "$ssid".');
  }

  @override
  Future<void> disconnect(String ssid) async {
    _validateSsid(ssid);
    final result = await _run('nmcli', <String>[
      'connection',
      'down',
      'id',
      ssid,
    ]);
    _ensureSuccess(result, 'Não foi possível desconectar da rede "$ssid".');
  }

  Future<ProcessResult> _run(String executable, List<String> arguments) async {
    final command = '$executable ${arguments.join(' ')}';
    _wifiLog.info('Executando comando Wi-Fi: $command');
    try {
      final result = await Process.run(
        executable,
        arguments,
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      ).timeout(_commandTimeout);
      _wifiLog.info(
        'Comando Wi-Fi concluído: $command; exitCode=${result.exitCode}',
      );
      return result;
    } on ProcessException catch (error) {
      _wifiLog.warning('Falha no comando Wi-Fi: $command', error);
      if (error.errorCode == 2) {
        throw const WifiException(
          'O comando nmcli não está instalado ou não está disponível no PATH.',
        );
      }
      throw WifiException('Falha ao executar nmcli: ${error.message}');
    } on TimeoutException {
      _wifiLog.warning('Timeout no comando Wi-Fi: $command');
      throw const WifiException(
        'O comando nmcli excedeu o tempo limite de 15 segundos.',
      );
    }
  }
}

class WindowsWifiManager implements WifiManager {
  @override
  Future<List<String>> listNetworks() async {
    final result = await _run(const <String>[
      'wlan',
      'show',
      'networks',
      'mode=bssid',
    ]);
    _ensureSuccess(result, 'Não foi possível listar as redes Wi-Fi.');
    return parseNetshNetworks(result.stdout as String);
  }

  @override
  Future<String?> currentSsid() async {
    final result = await _run(const <String>['wlan', 'show', 'interfaces']);
    _ensureSuccess(result, 'Não foi possível consultar a conexão Wi-Fi atual.');
    return parseNetshInterfaces(result.stdout as String);
  }

  @override
  Future<void> connect(String ssid) async {
    _validateSsid(ssid);
    final profilesResult = await _run(const <String>[
      'wlan',
      'show',
      'profiles',
    ]);
    _ensureSuccess(
      profilesResult,
      'Não foi possível consultar os perfis Wi-Fi salvos.',
    );

    final normalizedSsid = ssid.toLowerCase();
    final hasProfile = _parseNetshProfiles(profilesResult.stdout as String)
        .any((profile) => profile.toLowerCase() == normalizedSsid);
    if (!hasProfile) {
      throw WifiException(_missingProfileMessage(ssid));
    }

    final result = await _run(<String>[
      'wlan',
      'connect',
      'name=$ssid',
      'ssid=$ssid',
    ]);
    _ensureNetshSuccess(result, 'Não foi possível conectar à rede "$ssid".');
  }

  @override
  Future<void> disconnect(String ssid) async {
    _validateSsid(ssid);
    if (await currentSsid() != ssid) {
      return;
    }

    final result = await _run(const <String>['wlan', 'disconnect']);
    _ensureNetshSuccess(
      result,
      'Não foi possível desconectar da rede "$ssid".',
    );
  }

  Future<ProcessResult> _run(List<String> arguments) async {
    final command = 'netsh ${arguments.join(' ')}';
    _wifiLog.info('Executando comando Wi-Fi: $command');
    try {
      final result = await Process.run(
        'netsh',
        arguments,
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      ).timeout(_commandTimeout);
      _wifiLog.info(
        'Comando Wi-Fi concluído: $command; exitCode=${result.exitCode}',
      );
      return result;
    } on ProcessException catch (error) {
      _wifiLog.warning('Falha no comando Wi-Fi: $command', error);
      throw WifiException('Falha ao executar netsh: ${error.message}');
    } on TimeoutException {
      _wifiLog.warning('Timeout no comando Wi-Fi: $command');
      throw const WifiException(
        'O comando netsh excedeu o tempo limite de 15 segundos.',
      );
    }
  }
}

List<String> parseNmcliList(String output) {
  return _sortedUnique(
    output
        .split(RegExp(r'\r?\n'))
        .map((line) => _unescapeNmcli(line.trim()))
        .where((ssid) => ssid.isNotEmpty),
  );
}

List<String> parseNetshNetworks(String output) {
  final networkPattern = RegExp(
    r'^\s*(?:SSID|Nome(?:\s+da\s+rede)?)\s+\d+\s*:\s*(.*?)\s*$',
    caseSensitive: false,
  );
  final networks = <String>[];

  for (final line in output.split(RegExp(r'\r?\n'))) {
    final match = networkPattern.firstMatch(line);
    if (match != null) {
      networks.add(match.group(1) ?? '');
    }
  }

  return _sortedUnique(networks);
}

String? parseNetshInterfaces(String output) {
  final interfacePattern = RegExp(
    r'^\s*(?:Name|Nome)\s*:\s*(.*?)\s*$',
    caseSensitive: false,
  );
  final statePattern = RegExp(
    r'^\s*(?:State|Estado)\s*:\s*(.*?)\s*$',
    caseSensitive: false,
  );
  final ssidPattern = RegExp(r'^\s*SSID\s*:\s*(.*?)\s*$', caseSensitive: false);
  var isConnected = false;
  String? ssid;

  String? connectedSsid() {
    if (isConnected && ssid != null && ssid.isNotEmpty) {
      return ssid;
    }
    return null;
  }

  for (final line in output.split(RegExp(r'\r?\n'))) {
    if (interfacePattern.hasMatch(line)) {
      final result = connectedSsid();
      if (result != null) {
        return result;
      }
      isConnected = false;
      ssid = null;
      continue;
    }

    final stateMatch = statePattern.firstMatch(line);
    if (stateMatch != null) {
      final state = (stateMatch.group(1) ?? '').trim().toLowerCase();
      isConnected = state == 'connected' || state.startsWith('conectad');
      continue;
    }

    final ssidMatch = ssidPattern.firstMatch(line);
    if (ssidMatch != null) {
      ssid = (ssidMatch.group(1) ?? '').trim();
    }
  }

  return connectedSsid();
}

class WifiException implements Exception {
  const WifiException(this.message);

  final String message;

  @override
  String toString() => 'WifiException: $message';
}

const Duration _commandTimeout = Duration(seconds: 15);

String? _parseNmcliCurrentSsid(String output) {
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final separatorIndex = _firstUnescapedColon(line);
    if (separatorIndex < 0) {
      continue;
    }
    final active = line.substring(0, separatorIndex).trim().toLowerCase();
    if (active == 'yes' || active == 'sim') {
      final ssid = _unescapeNmcli(line.substring(separatorIndex + 1).trim());
      return ssid.isEmpty ? null : ssid;
    }
  }
  return null;
}

List<String> _parseNetshProfiles(String output) {
  final profiles = <String>[];
  for (final line in output.split(RegExp(r'\r?\n'))) {
    final separatorIndex = line.indexOf(':');
    if (separatorIndex < 0) {
      continue;
    }
    final profile = line.substring(separatorIndex + 1).trim();
    if (profile.isNotEmpty) {
      profiles.add(profile);
    }
  }
  return profiles;
}

List<String> _sortedUnique(Iterable<String> values) {
  final result = values.toSet().toList()..sort();
  return result;
}

String _unescapeNmcli(String value) {
  final result = StringBuffer();
  var isEscaped = false;
  for (final codeUnit in value.codeUnits) {
    final character = String.fromCharCode(codeUnit);
    if (isEscaped) {
      result.write(character);
      isEscaped = false;
    } else if (character == r'\') {
      isEscaped = true;
    } else {
      result.write(character);
    }
  }
  if (isEscaped) {
    result.write(r'\');
  }
  return result.toString();
}

int _firstUnescapedColon(String value) {
  var isEscaped = false;
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    if (isEscaped) {
      isEscaped = false;
    } else if (character == r'\') {
      isEscaped = true;
    } else if (character == ':') {
      return index;
    }
  }
  return -1;
}

void _validateSsid(String ssid) {
  if (ssid.trim().isEmpty) {
    throw const WifiException('O nome da rede Wi-Fi não pode estar vazio.');
  }
}

String _missingProfileMessage(String ssid) {
  return 'Não existe um perfil salvo para a rede "$ssid". '
      'Conecte-se uma vez à rede pelo sistema para salvá-la.';
}

void _ensureSuccess(ProcessResult result, String message) {
  if (result.exitCode == 0) {
    return;
  }
  throw WifiException(_commandFailureMessage(message, result));
}

void _ensureNetshSuccess(ProcessResult result, String message) {
  _ensureSuccess(result, message);
  final output = '${result.stdout}\n${result.stderr}'.toLowerCase();
  const failureMarkers = <String>[
    'failed',
    'error',
    'não foi possível',
    'não pôde',
    'erro',
  ];
  if (failureMarkers.any(output.contains)) {
    throw WifiException(_commandFailureMessage(message, result));
  }
}

String _commandFailureMessage(String message, ProcessResult result) {
  final details = (result.stderr as String).trim().isNotEmpty
      ? (result.stderr as String).trim()
      : (result.stdout as String).trim();
  return details.isEmpty ? message : '$message $details';
}
