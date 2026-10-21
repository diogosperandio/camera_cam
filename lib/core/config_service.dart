import 'dart:convert';

import 'package:camera_cam/models/app_config.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConfigService {
  ConfigService({this.timeout = const Duration(seconds: 5)});

  static const String _configKey = 'app_config';

  final Duration timeout;

  Future<AppConfig> load() async {
    try {
      final preferences = await SharedPreferences.getInstance().timeout(
        timeout,
      );
      final storedConfig = preferences.getString(_configKey);
      if (storedConfig == null) {
        return const AppConfig();
      }

      final decodedConfig = jsonDecode(storedConfig);
      if (decodedConfig is! Map<String, dynamic>) {
        throw const FormatException(
          'A configuração salva não é um objeto JSON.',
        );
      }
      return AppConfig.fromJson(decodedConfig);
    } on ConfigServiceException {
      rethrow;
    } catch (error) {
      throw ConfigServiceException(
        operation: ConfigServiceOperation.load,
        cause: error,
      );
    }
  }

  Future<void> save(AppConfig config) async {
    try {
      final preferences = await SharedPreferences.getInstance().timeout(
        timeout,
      );
      final wasSaved = await preferences
          .setString(_configKey, jsonEncode(config.toJson()))
          .timeout(timeout);
      if (!wasSaved) {
        throw const ConfigServiceException(
          operation: ConfigServiceOperation.save,
          cause: 'SharedPreferences não confirmou a gravação.',
        );
      }
    } on ConfigServiceException {
      rethrow;
    } catch (error) {
      throw ConfigServiceException(
        operation: ConfigServiceOperation.save,
        cause: error,
      );
    }
  }
}

enum ConfigServiceOperation { load, save }

class ConfigServiceException implements Exception {
  const ConfigServiceException({required this.operation, required this.cause});

  final ConfigServiceOperation operation;
  final Object cause;

  @override
  String toString() => 'ConfigServiceException($operation): $cause';
}
