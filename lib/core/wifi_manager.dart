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

  Future<WifiAdapterState> adapterState();

  Future<void> enableAdapter();

  Future<String?> currentSsid();

  Future<void> connect(String ssid);

  Future<void> disconnect(String ssid);
}

class LinuxWifiManager implements WifiManager {
  @override
  Future<WifiAdapterState> adapterState() async {
    final devices = await _run('nmcli', const <String>[
      '--terse',
      '--fields',
      'TYPE',
      'device',
      'status',
    ]);
    _ensureSuccess(devices, 'Não foi possível consultar o adaptador Wi-Fi.');
    if (!parseNmcliHasWifiDevice(devices.stdout as String)) {
      _wifiLog.info('Estado do adaptador Wi-Fi: unavailable');
      return WifiAdapterState.unavailable;
    }

    final result = await _run('nmcli', const <String>['radio', 'wifi']);
    _ensureSuccess(result, 'Não foi possível consultar o estado do Wi-Fi.');
    var state = parseNmcliRadioState(result.stdout as String);
    if (state == WifiAdapterState.disabled) {
      final rfkill = await _runOptional('rfkill', const <String>[
        'list',
        'wifi',
      ]);
      if (rfkill != null && parseRfkillHardBlocked(rfkill.stdout as String)) {
        state = WifiAdapterState.blocked;
      }
    }
    _wifiLog.info('Estado do adaptador Wi-Fi: ${state.name}');
    return state;
  }

  @override
  Future<void> enableAdapter() async {
    final result = await _run('nmcli', const <String>['radio', 'wifi', 'on']);
    if (result.exitCode != 0) {
      throw const WifiException(
        'Não foi possível ligar o Wi-Fi. Verifique a tecla de modo avião ou a chave física.',
      );
    }
    for (var attempt = 0; attempt < 10; attempt++) {
      final state = await adapterState();
      if (state == WifiAdapterState.enabled) {
        _wifiLog.info('Adaptador Wi-Fi ligado com sucesso.');
        return;
      }
      if (state == WifiAdapterState.blocked) {
        break;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw const WifiException(
      'Não foi possível ligar o Wi-Fi. Verifique a tecla de modo avião ou a chave física.',
    );
  }

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
        'Comando Wi-Fi concluído: $command; exitCode=${result.exitCode}; '
        'stdout=${result.stdout}; stderr=${result.stderr}',
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

  Future<ProcessResult?> _runOptional(
    String executable,
    List<String> arguments,
  ) async {
    try {
      return await Process.run(
        executable,
        arguments,
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      ).timeout(_commandTimeout);
    } on ProcessException catch (error) {
      if (error.errorCode == 2) {
        _wifiLog.info('Comando opcional $executable não está disponível.');
        return null;
      }
      rethrow;
    } on TimeoutException {
      _wifiLog.warning('Timeout no comando opcional $executable.');
      return null;
    }
  }
}

class WindowsWifiManager implements WifiManager {
  @override
  Future<WifiAdapterState> adapterState() async {
    try {
      final result = await _runPowerShell(_readRadioScript);
      if (result.exitCode == 0) {
        final state = parsePowerShellWifiRadio(result.stdout as String);
        if (state != WifiAdapterState.unknown) {
          _wifiLog.info('Estado do adaptador Wi-Fi: ${state.name}');
          return state;
        }
      }
    } catch (error) {
      _wifiLog.warning(
        'Consulta WinRT do adaptador falhou; usando netsh.',
        error,
      );
    }

    final result = await _run(const <String>['interface', 'show', 'interface']);
    _ensureSuccess(result, 'Não foi possível consultar o adaptador Wi-Fi.');
    final state = parseNetshAdapterState(result.stdout as String);
    _wifiLog.info('Estado do adaptador Wi-Fi: ${state.name}');
    return state;
  }

  @override
  Future<void> enableAdapter() async {
    try {
      final result = await _runPowerShell(_enableRadioScript);
      if (result.exitCode == 0 &&
          parsePowerShellWifiRadio(result.stdout as String) ==
              WifiAdapterState.enabled) {
        _wifiLog.info('Adaptador Wi-Fi ligado pelo PowerShell.');
        return;
      }
    } catch (error) {
      _wifiLog.warning('Não foi possível ligar o Wi-Fi via WinRT.', error);
    }

    final interfaces = await _run(const <String>[
      'interface',
      'show',
      'interface',
    ]);
    _ensureSuccess(interfaces, 'Não foi possível localizar o adaptador Wi-Fi.');
    final name = parseNetshWifiInterfaceName(interfaces.stdout as String);
    if (name == null) {
      throw const WifiException('Nenhum adaptador Wi-Fi foi encontrado.');
    }
    final result = await _run(<String>[
      'interface',
      'set',
      'interface',
      'name=$name',
      'admin=enabled',
    ]);
    try {
      _ensureNetshSuccess(result, 'Não foi possível ligar o adaptador Wi-Fi.');
    } on WifiException {
      throw const WifiException(
        'Não foi possível ligar o Wi-Fi. No Windows, esta ação pode exigir '
        'permissão de administrador; ligue o adaptador pelo sistema e tente novamente.',
      );
    }
    _wifiLog.info('Adaptador Wi-Fi ligado pelo netsh.');
  }

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
        'Comando Wi-Fi concluído: $command; exitCode=${result.exitCode}; '
        'stdout=${result.stdout}; stderr=${result.stderr}',
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

  Future<ProcessResult> _runPowerShell(String script) async {
    const executable = 'powershell.exe';
    _wifiLog.info('Executando comando Wi-Fi via PowerShell/WinRT.');
    try {
      final result = await Process.run(
        executable,
        <String>['-NoProfile', '-NonInteractive', '-Command', script],
        stdoutEncoding: systemEncoding,
        stderrEncoding: systemEncoding,
      ).timeout(_commandTimeout);
      _wifiLog.info(
        'Resposta PowerShell Wi-Fi: exitCode=${result.exitCode}; '
        'stdout=${result.stdout}; stderr=${result.stderr}',
      );
      return result;
    } on ProcessException catch (error) {
      throw WifiException('Falha ao executar PowerShell: ${error.message}');
    } on TimeoutException {
      throw const WifiException(
        'A consulta do adaptador Wi-Fi excedeu o limite de 15 segundos.',
      );
    }
  }
}

enum WifiAdapterState { enabled, disabled, blocked, unavailable, unknown }

WifiAdapterState parseNmcliRadioState(String output) {
  final value = output.trim().toLowerCase();
  if (<String>[
    'enabled',
    'ativado',
    'habilitado',
    'ligado',
    'on',
  ].contains(value)) {
    return WifiAdapterState.enabled;
  }
  if (<String>[
    'disabled',
    'desativado',
    'desabilitado',
    'desligado',
    'off',
  ].contains(value)) {
    return WifiAdapterState.disabled;
  }
  return WifiAdapterState.unknown;
}

bool parseNmcliHasWifiDevice(String output) {
  return output
      .split(RegExp(r'\r?\n'))
      .any((line) => line.trim().toLowerCase() == 'wifi');
}

bool parseRfkillHardBlocked(String output) {
  final pattern = RegExp(
    r'hard\s+blocked\s*:\s*(?:yes|sim)',
    caseSensitive: false,
  );
  return pattern.hasMatch(output);
}

WifiAdapterState parsePowerShellWifiRadio(String output) {
  final lines = output.split(RegExp(r'\r?\n'));
  for (final line in lines) {
    final parts = line.trim().split('|');
    if (parts.length < 2 || parts.first.trim().toLowerCase() != 'wifi') {
      continue;
    }
    return switch (parts.last.trim().toLowerCase()) {
      'on' => WifiAdapterState.enabled,
      'off' => WifiAdapterState.disabled,
      'disabled' => WifiAdapterState.blocked,
      _ => WifiAdapterState.unknown,
    };
  }
  return WifiAdapterState.unknown;
}

WifiAdapterState parseNetshAdapterState(String output) {
  final normalized = output.toLowerCase();
  if (normalized.contains('no wireless interface') ||
      normalized.contains('nenhuma interface sem fio')) {
    return WifiAdapterState.unavailable;
  }
  for (final line in output.split(RegExp(r'\r?\n'))) {
    if (!_looksLikeWifiInterface(line)) {
      continue;
    }
    if (RegExp(
      r'\b(disabled|desabilitado|desativado)\b',
      caseSensitive: false,
    ).hasMatch(line)) {
      return WifiAdapterState.disabled;
    }
    if (RegExp(
      r'\b(enabled|habilitado|ativado)\b',
      caseSensitive: false,
    ).hasMatch(line)) {
      return WifiAdapterState.enabled;
    }
    return WifiAdapterState.unknown;
  }
  return WifiAdapterState.unknown;
}

String? parseNetshWifiInterfaceName(String output) {
  for (final line in output.split(RegExp(r'\r?\n'))) {
    if (!_looksLikeWifiInterface(line)) {
      continue;
    }
    final match = RegExp(
      r'(wi-?fi|wireless|wlan|rede\s+sem\s+fio).*$',
      caseSensitive: false,
    ).firstMatch(line);
    return match?.group(0)?.trim();
  }
  return null;
}

bool _looksLikeWifiInterface(String line) {
  return RegExp(
    r'\b(wi-?fi|wireless|wlan|rede\s+sem\s+fio)\b',
    caseSensitive: false,
  ).hasMatch(line);
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

const String _readRadioScript = r'''
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime] > $null
$access = [Windows.Devices.Radios.Radio]::RequestAccessAsync()
while ($access.Status -eq 0) { Start-Sleep -Milliseconds 100 }
if ($access.GetResults().ToString() -ne 'Allowed') { exit 2 }
$operation = [Windows.Devices.Radios.Radio]::GetRadiosAsync()
while ($operation.Status -eq 0) { Start-Sleep -Milliseconds 100 }
$radios = $operation.GetResults()
$wifi = $radios | Where-Object { $_.Kind.ToString() -eq 'WiFi' } | Select-Object -First 1
if ($null -ne $wifi) { Write-Output ('WiFi|' + $wifi.State.ToString()) }
''';

const String _enableRadioScript = r'''
Add-Type -AssemblyName System.Runtime.WindowsRuntime
[Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime] > $null
$access = [Windows.Devices.Radios.Radio]::RequestAccessAsync()
while ($access.Status -eq 0) { Start-Sleep -Milliseconds 100 }
if ($access.GetResults().ToString() -ne 'Allowed') { exit 2 }
$operation = [Windows.Devices.Radios.Radio]::GetRadiosAsync()
while ($operation.Status -eq 0) { Start-Sleep -Milliseconds 100 }
$radios = $operation.GetResults()
$wifi = $radios | Where-Object { $_.Kind.ToString() -eq 'WiFi' } | Select-Object -First 1
if ($null -eq $wifi) { exit 3 }
$enable = $wifi.SetStateAsync([Windows.Devices.Radios.RadioState]::On)
while ($enable.Status -eq 0) { Start-Sleep -Milliseconds 100 }
$enable.GetResults() > $null
Write-Output ('WiFi|' + $wifi.State.ToString())
''';

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
