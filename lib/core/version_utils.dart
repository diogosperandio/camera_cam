class Version {
  const Version(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  @override
  String toString() => '$major.$minor.$patch';
}

Version? parseVersion(String value) {
  final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)(?:\+\d+)?$').firstMatch(value);
  if (match == null) return null;
  return Version(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
  );
}

int compareVersions(Version first, Version second) {
  for (final comparison in <int>[
    first.major.compareTo(second.major),
    first.minor.compareTo(second.minor),
    first.patch.compareTo(second.patch),
  ]) {
    if (comparison != 0) return comparison;
  }
  return 0;
}

bool isUpdateDue(
  DateTime? lastCheck,
  DateTime now, {
  Duration every = const Duration(hours: 24),
}) {
  return lastCheck == null || now.difference(lastCheck) >= every;
}
