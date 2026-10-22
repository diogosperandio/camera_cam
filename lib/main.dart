import 'dart:async';

import 'package:toshiba_flashair_wifi_viewer/core/cache_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/card_client.dart';
import 'package:toshiba_flashair_wifi_viewer/core/config_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/file_saver.dart';
import 'package:toshiba_flashair_wifi_viewer/core/log_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/app_constants.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update_installer.dart';
import 'package:toshiba_flashair_wifi_viewer/core/update_service.dart';
import 'package:toshiba_flashair_wifi_viewer/core/wifi_manager.dart';
import 'package:toshiba_flashair_wifi_viewer/state/app_state.dart';
import 'package:toshiba_flashair_wifi_viewer/state/update_controller.dart';
import 'package:toshiba_flashair_wifi_viewer/ui/main_page.dart';
import 'package:toshiba_flashair_wifi_viewer/ui/user_prompter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await AppLog.initialize();
  } catch (error) {
    debugPrint('Não foi possível iniciar o log em arquivo: $error');
  }
  final navigatorKey = GlobalKey<NavigatorState>();
  final state = AppState(
    configService: ConfigService(),
    wifiManager: WifiManager(),
    cardClient: CardClient('http://flashair', http.Client()),
    cacheService: CacheService(),
    fileSaver: FileSelectorFileSaver(),
    userPrompter: DialogUserPrompter(navigatorKey),
  );
  final installer = UpdateInstaller();
  final updateController = UpdateController(
    appState: state,
    service: UpdateService(http.Client(), repo: githubRepo),
    installer: installer,
    requestAppClose: () async {
      await state.disconnectOnAppClose();
      await AppLog.close();
      await SystemNavigator.pop();
    },
  );
  runApp(
    CameraCamApp(
      appState: state,
      updateController: updateController,
      navigatorKey: navigatorKey,
    ),
  );
  unawaited(() async {
    await state.init();
    await updateController.init();
  }());
}

class CameraCamApp extends StatefulWidget {
  const CameraCamApp({
    required this.appState,
    this.updateController,
    this.navigatorKey,
    super.key,
  });

  final AppState appState;
  final UpdateController? updateController;
  final GlobalKey<NavigatorState>? navigatorKey;

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
        navigatorKey: widget.navigatorKey,
        debugShowCheckedModeBanner: false,
        title: 'Toshiba FlashAir WiFi Viewer',
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
        home: MainPage(updateController: widget.updateController),
      ),
    );
  }
}
