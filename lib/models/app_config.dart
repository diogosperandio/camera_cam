class AppConfig {
  const AppConfig({
    this.ssid,
    this.baseUrl = 'http://flashair',
    this.outputDir,
    this.disconnectOnClose = true,
    this.deleteEnabled = false,
    this.sortBy = SortBy.name,
    this.snackBarSeconds = 15,
  });

  static const Object _notProvided = Object();

  final String? ssid;
  final String baseUrl;
  final String? outputDir;
  final bool disconnectOnClose;
  final bool deleteEnabled;
  final SortBy sortBy;
  final int snackBarSeconds;

  AppConfig copyWith({
    Object? ssid = _notProvided,
    String? baseUrl,
    Object? outputDir = _notProvided,
    bool? disconnectOnClose,
    bool? deleteEnabled,
    SortBy? sortBy,
    int? snackBarSeconds,
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
    );
  }
}

int _clampSnackBarSeconds(Object? value) {
  final seconds = value is num ? value.toInt() : 15;
  return seconds.clamp(3, 60);
}

enum SortBy { name, date, size }
