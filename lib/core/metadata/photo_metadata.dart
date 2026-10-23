class PhotoMetadata {
  const PhotoMetadata({
    this.make,
    this.model,
    this.software,
    this.dateOriginal,
    this.width,
    this.height,
    this.orientation,
    this.exposureTime,
    this.aperture,
    this.iso,
    this.focalLength,
    this.focalLength35mm,
    this.exposureProgram,
    this.meteringMode,
    this.exposureBias,
    this.whiteBalance,
    this.flash,
    this.colorSpace,
    this.lensModel,
    this.latitude,
    this.longitude,
    this.altitude,
    this.rawTags = const <RawMetadataTag>[],
  });

  final String? make;
  final String? model;
  final String? software;
  final DateTime? dateOriginal;
  final int? width;
  final int? height;
  final int? orientation;
  final double? exposureTime;
  final double? aperture;
  final int? iso;
  final double? focalLength;
  final int? focalLength35mm;
  final int? exposureProgram;
  final int? meteringMode;
  final double? exposureBias;
  final int? whiteBalance;
  final int? flash;
  final int? colorSpace;
  final String? lensModel;
  final double? latitude;
  final double? longitude;
  final double? altitude;
  final List<RawMetadataTag> rawTags;

  bool get hasGps => latitude != null && longitude != null;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'make': make,
    'model': model,
    'software': software,
    'dateOriginal': dateOriginal?.toIso8601String(),
    'width': width,
    'height': height,
    'orientation': orientation,
    'exposureTime': exposureTime,
    'aperture': aperture,
    'iso': iso,
    'focalLength': focalLength,
    'focalLength35mm': focalLength35mm,
    'exposureProgram': exposureProgram,
    'meteringMode': meteringMode,
    'exposureBias': exposureBias,
    'whiteBalance': whiteBalance,
    'flash': flash,
    'colorSpace': colorSpace,
    'lensModel': lensModel,
    'latitude': latitude,
    'longitude': longitude,
    'altitude': altitude,
    'rawTags': rawTags.map((tag) => tag.toJson()).toList(),
  };

  factory PhotoMetadata.fromJson(Map<String, dynamic> json) => PhotoMetadata(
    make: json['make'] as String?,
    model: json['model'] as String?,
    software: json['software'] as String?,
    dateOriginal: _date(json['dateOriginal']),
    width: _integer(json['width']),
    height: _integer(json['height']),
    orientation: _integer(json['orientation']),
    exposureTime: _decimal(json['exposureTime']),
    aperture: _decimal(json['aperture']),
    iso: _integer(json['iso']),
    focalLength: _decimal(json['focalLength']),
    focalLength35mm: _integer(json['focalLength35mm']),
    exposureProgram: _integer(json['exposureProgram']),
    meteringMode: _integer(json['meteringMode']),
    exposureBias: _decimal(json['exposureBias']),
    whiteBalance: _integer(json['whiteBalance']),
    flash: _integer(json['flash']),
    colorSpace: _integer(json['colorSpace']),
    lensModel: json['lensModel'] as String?,
    latitude: _decimal(json['latitude']),
    longitude: _decimal(json['longitude']),
    altitude: _decimal(json['altitude']),
    rawTags: (json['rawTags'] as List? ?? const <Object>[])
        .whereType<Map>()
        .map((tag) => RawMetadataTag.fromJson(Map<String, dynamic>.from(tag)))
        .toList(growable: false),
  );
}

class RawMetadataTag {
  const RawMetadataTag({
    required this.group,
    required this.name,
    required this.value,
  });

  final String group;
  final String name;
  final String value;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'group': group,
    'name': name,
    'value': value,
  };

  factory RawMetadataTag.fromJson(Map<String, dynamic> json) => RawMetadataTag(
    group: json['group'] as String? ?? '',
    name: json['name'] as String? ?? '',
    value: json['value'] as String? ?? '',
  );
}

int? _integer(Object? value) => value is num ? value.toInt() : null;
double? _decimal(Object? value) => value is num ? value.toDouble() : null;
DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;
