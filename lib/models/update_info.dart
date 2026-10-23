class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.tag,
    required this.notes,
    required this.pageUrl,
    required this.assetName,
    required this.assetSize,
    this.assetUrl,
    this.digest,
    this.sha256Url,
  });

  final String version;
  final String tag;
  final String notes;
  final String pageUrl;
  final String assetName;
  final String? assetUrl;
  final int assetSize;
  final String? digest;
  final String? sha256Url;
}
