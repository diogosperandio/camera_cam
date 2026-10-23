import 'dart:math' as math;

String formatExposure(double? seconds) {
  if (seconds == null || !seconds.isFinite || seconds <= 0) return '';
  if (seconds < 1) {
    final denominator = (1 / seconds).round();
    return '1/$denominator s';
  }
  return '${_decimal(seconds, maximumFractionDigits: 1)} s';
}

String formatAperture(double? aperture) => aperture == null || aperture <= 0
    ? ''
    : 'f/${_decimal(aperture, maximumFractionDigits: 1)}';

String formatFocalLength(
  double? focalLength, {
  int? equivalent35mm,
  String? model,
}) {
  if (focalLength == null || focalLength <= 0) return '';
  final focal = _decimal(focalLength, maximumFractionDigits: 1);
  if (equivalent35mm != null && equivalent35mm > 0) {
    return '$focal mm ($equivalent35mm mm equiv.)';
  }
  if ((model ?? '').toUpperCase().startsWith('NIKON 1')) {
    final approximate = (focalLength * 2.7).round();
    return '$focal mm ($approximate mm equiv. aprox.)';
  }
  return '$focal mm';
}

String formatExposureBias(double? value) {
  if (value == null || !value.isFinite) return '';
  if (value.abs() < 0.0005) return '0 EV';
  final prefix = value > 0 ? '+' : '−';
  return '$prefix${_fixed(value.abs(), 1)} EV';
}

String formatDimensions(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) return '';
  final megapixels = width * height / 1000000;
  return '$width × $height (${_fixed(megapixels, 1)} MP)';
}

String formatOrientation(int? orientation, {int manualQuarterTurns = 0}) {
  final base = switch (orientation) {
    1 => 'Normal',
    2 => 'Espelhada horizontalmente',
    3 => 'Girada 180°',
    4 => 'Espelhada verticalmente',
    5 => 'Espelhada e girada 90° à esquerda',
    6 => 'Girada 90° à direita',
    7 => 'Espelhada e girada 90° à direita',
    8 => 'Girada 90° à esquerda',
    _ => '',
  };
  final turns = ((manualQuarterTurns % 4) + 4) % 4;
  if (turns == 0) return base;
  final manual = switch (turns) {
    1 => '90° à direita',
    2 => '180°',
    _ => '90° à esquerda',
  };
  return '${base.isEmpty ? '' : '$base · '}girada no app: $manual';
}

String formatGps(double latitude, double longitude) =>
    '${_fixed(latitude, 4)}, ${_fixed(longitude, 4)}';

String formatDateTime(DateTime? value) {
  if (value == null) return '';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${two(local.day)}/${two(local.month)}/${local.year.toString().padLeft(4, '0')} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

bool hasSuspiciousCameraClock(DateTime? value, {DateTime? now}) {
  if (value == null) return false;
  final today = now ?? DateTime.now();
  return value.isBefore(DateTime(2011)) || value.isAfter(today);
}

String formatExposureProgram(int? value) => switch (value) {
  null => '',
  0 => 'Não definido',
  1 => 'Manual',
  2 => 'Programa normal',
  3 => 'Prioridade de abertura',
  4 => 'Prioridade de velocidade',
  5 => 'Programa criativo',
  6 => 'Programa de ação',
  7 => 'Retrato',
  8 => 'Paisagem',
  _ => value.toString(),
};

String formatMeteringMode(int? value) => switch (value) {
  null => '',
  0 => 'Desconhecida',
  1 => 'Média',
  2 => 'Média ponderada ao centro',
  3 => 'Pontual',
  4 => 'Multipontual',
  5 => 'Matricial',
  6 => 'Parcial',
  255 => 'Outra',
  _ => value.toString(),
};

String formatWhiteBalance(int? value) => switch (value) {
  null => '',
  0 => 'Automático',
  1 => 'Manual',
  _ => value.toString(),
};

String formatFlash(int? value) {
  if (value == null) return '';
  final fired = value & 1 != 0;
  final mode = (value >> 3) & 3;
  final returnStatus = (value >> 1) & 3;
  final parts = <String>[fired ? 'Disparou' : 'Não disparou'];
  if (mode == 1) parts.add('forçado');
  if (mode == 2) parts.add('suprimido');
  if (mode == 3) parts.add('automático');
  if (returnStatus == 2) parts.add('retorno não detectado');
  if (returnStatus == 3) parts.add('retorno detectado');
  if (value & 0x40 != 0) parts.add('olhos vermelhos');
  return parts.join(', ');
}

String formatColorSpace(int? value) => switch (value) {
  null => '',
  1 => 'sRGB',
  0xFFFF => 'Não calibrado',
  _ => value.toString(),
};

String _decimal(double value, {required int maximumFractionDigits}) {
  final rounded = value.toStringAsFixed(maximumFractionDigits);
  final trimmed = rounded.replaceFirst(RegExp(r'([.,]0+)$'), '');
  return trimmed.replaceAll('.', ',');
}

String _fixed(double value, int digits) {
  if (value.abs() < math.pow(10, -digits) / 2) value = 0;
  return value.toStringAsFixed(digits).replaceAll('.', ',');
}
