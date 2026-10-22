class AppConfig {
  const AppConfig({
    this.ssid,
    this.baseUrl = 'http://flashair',
    this.outputDir,
    this.disconnectOnClose = true,
    this.deleteEnabled = false,
    this.sortBy = SortBy.name,
    this.snackBarSeconds = 15,
    this.rotateSaveMode = 'exif',
    this.autoCheckUpdates = true,
    this.lastUpdateCheck,
    this.skippedVersion,
  });

  static const Object _notProvided = Object();

  final String? ssid;
  final String baseUrl;
  final String? outputDir;
  final bool disconnectOnClose;
  final bool deleteEnabled;
  final SortBy sortBy;
  final int snackBarSeconds;
  final String rotateSaveMode;
  final bool autoCheckUpdates;
  final DateTime? lastUpdateCheck;
  final String? skippedVersion;

  AppConfig copyWith({
    Object? ssid = _notProvided,
    String? baseUrl,
    Object? outputDir = _notProvided,
    bool? disconnectOnClose,
    bool? deleteEnabled,
    SortBy? sortBy,
    int? snackBarSeconds,
    String? rotateSaveMode,
    bool? autoCheckUpdates,
    Object? lastUpdateCheck = _notProvided,
    Object? skippedVersion = _notProvided,
  }) {
    return AppConfig(
      ssid: identical(ssid, _notProvided) ? this.ssid : ssid as String?,
      baseUrl: baseUrl ?? this.baseUrl,
      outputDir: identical(outputDir, _notProvided)
          ? this.outputDir
          : outputDir as String?,
      disconnectOnClose: disconnectOnClose ?? this.disconnectOnClose,
      deleteEnabled: deleteEnabled ?? this.deleteEnabled,
      sortBy: sortBy ?? this.sortBy,
      snackBarSeconds: snackBarSeconds ?? this.snackBarSeconds,
      rotateSaveMode: _validRotateSaveMode(
        rotateSaveMode ?? this.rotateSaveMode,
      ),
      autoCheckUpdates: autoCheckUpdates ?? this.autoCheckUpdates,
      lastUpdateCheck: identical(lastUpdateCheck, _notProvided)
          ? this.lastUpdateCheck
          : lastUpdateCheck as DateTime?,
      skippedVersion: identical(skippedVersion, _notProvided)
          ? this.skippedVersion
          : skippedVersion as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'ssid': ssid,
      'baseUrl': baseUrl,
      'outputDir': outputDir,
      'disconnectOnClose': disconnectOnClose,
      'deleteEnabled': deleteEnabled,
      'sortBy': sortBy.name,
      'snackBarSeconds': snackBarSeconds,
      'rotateSaveMode': rotateSaveMode,
      'autoCheckUpdates': autoCheckUpdates,
      'lastUpdateCheck': lastUpdateCheck?.toIso8601String(),
      'skippedVersion': skippedVersion,
    };
  }

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    return AppConfig(
      ssid: json['ssid'] as String?,
      baseUrl: json['baseUrl'] as String? ?? 'http://flashair',
      outputDir: json['outputDir'] as String?,
      disconnectOnClose: json['disconnectOnClose'] as bool? ?? true,
      deleteEnabled: json['deleteEnabled'] as bool? ?? false,
      sortBy: SortBy.values.firstWhere(
        (value) => value.name == json['sortBy'],
        orElse: () => SortBy.name,
      ),
      snackBarSeconds: _clampSnackBarSeconds(json['snackBarSeconds']),
      rotateSaveMode: _validRotateSaveMode(json['rotateSaveMode']),
      autoCheckUpdates: json['autoCheckUpdates'] as bool? ?? true,
      lastUpdateCheck: _parseDate(json['lastUpdateCheck']),
      skippedVersion: json['skippedVersion'] as String?,
    );
  }
}

DateTime? _parseDate(Object? value) {
  return value is String ? DateTime.tryParse(value) : null;
}

String _validRotateSaveMode(Object? value) {
  return value == 'pixels' ? 'pixels' : 'exif';
}

int _clampSnackBarSeconds(Object? value) {
  final seconds = value is num ? value.toInt() : 15;
  return seconds.clamp(3, 60);
}

enum SortBy { name, date, size }
