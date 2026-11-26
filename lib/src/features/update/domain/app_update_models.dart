import 'dart:convert';

const String kDefaultFallbackAppVersion = '1.0.12';
const String kGitHubLatestReleaseApiUrl =
    'https://api.github.com/repos/jinzong8/ai-wrong-notebook/releases/latest';

/// Normalizes a version or git tag like `v1.0.11+12` into `1.0.11`.
String normalizeVersionString(String raw) {
  var text = raw.trim();
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  final plusIdx = text.indexOf('+');
  if (plusIdx >= 0) {
    text = text.substring(0, plusIdx);
  }
  final dashIdx = text.indexOf('-');
  if (dashIdx >= 0) {
    text = text.substring(0, dashIdx);
  }
  return text.trim();
}

/// Compares two semantic version strings (e.g. `1.0.10` vs `v1.0.11`).
/// Returns `> 0` if `a > b`, `< 0` if `a < b`, and `0` if equal.
int compareAppVersions(String a, String b) {
  final partsA = normalizeVersionString(a)
      .split('.')
      .map((seg) => int.tryParse(seg) ?? 0)
      .toList();
  final partsB = normalizeVersionString(b)
      .split('.')
      .map((seg) => int.tryParse(seg) ?? 0)
      .toList();

  final maxLen = partsA.length > partsB.length ? partsA.length : partsB.length;
  for (var i = 0; i < maxLen; i++) {
    final va = i < partsA.length ? partsA[i] : 0;
    final vb = i < partsB.length ? partsB[i] : 0;
    if (va != vb) {
      return va.compareTo(vb);
    }
  }
  return 0;
}

/// Formats byte size into human-readable MB (e.g. `73.6 MB`).
String formatUpdateByteSize(int bytes) {
  if (bytes <= 0) return '';
  final mb = bytes / (1024 * 1024);
  if (mb >= 1.0) {
    return '${mb.toStringAsFixed(1)} MB';
  }
  final kb = bytes / 1024;
  return '${kb.toStringAsFixed(0)} KB';
}

/// Official GitHub Release metadata parsed from `/releases/latest`.
class RemoteReleaseInfo {
  const RemoteReleaseInfo({
    required this.tagName,
    required this.version,
    required this.releaseNotes,
    required this.apkDownloadUrl,
    required this.apkSize,
    this.sha256Hex,
    this.publishedAt,
  });

  final String tagName;
  final String version;
  final String releaseNotes;
  final String apkDownloadUrl;
  final int apkSize;
  final String? sha256Hex;
  final DateTime? publishedAt;

  static RemoteReleaseInfo? tryParseGitHubReleaseJson(
    Map<String, dynamic> json,
  ) {
    if (json['draft'] == true || json['prerelease'] == true) {
      return null;
    }

    final rawTag = (json['tag_name'] as String?)?.trim() ?? '';
    final version = normalizeVersionString(rawTag);
    if (version.isEmpty) return null;

    final assetsRaw = json['assets'];
    if (assetsRaw is! List) return null;

    Map<String, dynamic>? apkAsset;
    for (final item in assetsRaw) {
      if (item is! Map) continue;
      final map = Map<String, dynamic>.from(item);
      final name = ((map['name'] as String?) ?? '').toLowerCase();
      final contentType =
          ((map['content_type'] as String?) ?? '').toLowerCase();
      if (name.endsWith('.apk') ||
          contentType == 'application/vnd.android.package-archive') {
        apkAsset = map;
        break;
      }
    }
    if (apkAsset == null) return null;

    final downloadUrl =
        (apkAsset['browser_download_url'] as String?)?.trim() ?? '';
    if (!downloadUrl.startsWith('https://github.com/')) {
      return null;
    }

    final size = (apkAsset['size'] as num?)?.toInt() ?? 0;
    final rawDigest = (apkAsset['digest'] as String?)?.trim() ?? '';
    String? sha256Hex;
    if (rawDigest.toLowerCase().startsWith('sha256:')) {
      sha256Hex = rawDigest.substring('sha256:'.length).trim().toLowerCase();
    }

    final rawNotes = (json['body'] as String?)?.trim() ?? '';
    final publishedRaw = json['published_at'] as String?;

    return RemoteReleaseInfo(
      tagName: rawTag,
      version: version,
      releaseNotes: rawNotes,
      apkDownloadUrl: downloadUrl,
      apkSize: size,
      sha256Hex: (sha256Hex != null && sha256Hex.isNotEmpty) ? sha256Hex : null,
      publishedAt:
          publishedRaw != null ? DateTime.tryParse(publishedRaw) : null,
    );
  }
}

/// Verified `.apk` package already silently downloaded to local storage and
/// ready for zero-wait installation.
class StagedAppUpdate {
  const StagedAppUpdate({
    required this.tagName,
    required this.version,
    required this.releaseNotes,
    required this.apkPath,
    required this.fileSize,
    required this.stagedAt,
    this.sha256Hex,
  });

  final String tagName;
  final String version;
  final String releaseNotes;
  final String apkPath;
  final int fileSize;
  final String? sha256Hex;
  final DateTime stagedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'tagName': tagName,
        'version': version,
        'releaseNotes': releaseNotes,
        'apkPath': apkPath,
        'fileSize': fileSize,
        if (sha256Hex != null) 'sha256Hex': sha256Hex,
        'stagedAt': stagedAt.toIso8601String(),
      };

  static StagedAppUpdate? tryFromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      final version = (map['version'] as String?)?.trim() ?? '';
      final apkPath = (map['apkPath'] as String?)?.trim() ?? '';
      if (version.isEmpty || apkPath.isEmpty) return null;
      return StagedAppUpdate(
        tagName: (map['tagName'] as String?)?.trim() ?? 'v$version',
        version: version,
        releaseNotes: (map['releaseNotes'] as String?) ?? '',
        apkPath: apkPath,
        fileSize: (map['fileSize'] as num?)?.toInt() ?? 0,
        sha256Hex: (map['sha256Hex'] as String?)?.trim(),
        stagedAt: DateTime.tryParse((map['stagedAt'] as String?) ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Immutable UI state exposed by `AppUpdateController`.
class AppUpdateState {
  const AppUpdateState({
    this.currentVersion = kDefaultFallbackAppVersion,
    this.readyUpdate,
    this.ignoredStartupVersion,
    this.startupPromptHandled = false,
    this.isStagingSilently = false,
  });

  final String currentVersion;
  final StagedAppUpdate? readyUpdate;
  final String? ignoredStartupVersion;
  final bool startupPromptHandled;
  final bool isStagingSilently;

  bool get hasReadyUpdate =>
      readyUpdate != null &&
      compareAppVersions(readyUpdate!.version, currentVersion) > 0;

  bool get shouldAutoPromptOnStartup =>
      hasReadyUpdate &&
      !startupPromptHandled &&
      ignoredStartupVersion != readyUpdate!.version;

  AppUpdateState copyWith({
    String? currentVersion,
    StagedAppUpdate? readyUpdate,
    bool clearReadyUpdate = false,
    String? ignoredStartupVersion,
    bool clearIgnoredStartupVersion = false,
    bool? startupPromptHandled,
    bool? isStagingSilently,
  }) {
    return AppUpdateState(
      currentVersion: currentVersion ?? this.currentVersion,
      readyUpdate: clearReadyUpdate ? null : (readyUpdate ?? this.readyUpdate),
      ignoredStartupVersion: clearIgnoredStartupVersion
          ? null
          : (ignoredStartupVersion ?? this.ignoredStartupVersion),
      startupPromptHandled: startupPromptHandled ?? this.startupPromptHandled,
      isStagingSilently: isStagingSilently ?? this.isStagingSilently,
    );
  }
}
