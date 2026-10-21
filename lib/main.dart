import 'dart:async';

import 'package:camera_cam/core/cache_service.dart';
import 'package:camera_cam/core/card_client.dart';
import 'package:camera_cam/core/config_service.dart';
import 'package:camera_cam/core/file_saver.dart';
import 'package:camera_cam/core/log_service.dart';
import 'package:camera_cam/core/wifi_manager.dart';
import 'package:camera_cam/state/app_state.dart';
import 'package:camera_cam/ui/main_page.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await AppLog.initialize();
  } catch (error) {
    debugPrint('Não foi possível iniciar o log em arquivo: $error');
  }
  final state = AppState(
    configService: ConfigService(),
    wifiManager: WifiManager(),
    cardClient: CardClient('http://flashair', http.Client()),
    cacheService: CacheService(),
    fileSaver: FileSelectorFileSaver(),
  );
  runApp(CameraCamApp(appState: state));
  unawaited(state.init());
}

class CameraCamApp extends StatefulWidget {
  const CameraCamApp({required this.appState, super.key});

  final AppState appState;

  @override
  State<CameraCamApp> createState() => _CameraCamAppState();
}

class _CameraCamAppState extends State<CameraCamApp> {
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(onDetach: _disconnectOnClose);
  }

  void _disconnectOnClose() {
    unawaited(_finishShutdown());
  }

  Future<void> _finishShutdown() async {
    await widget.appState.disconnectOnAppClose();
    await AppLog.close();
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<AppState>.value(
      value: widget.appState,
      child: MaterialApp(
        title: 'EZ Share Viewer',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
          useMaterial3: true,
        ),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.indigo,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        themeMode: ThemeMode.system,
        home: const MainPage(),
      ),
    );
  }
}
