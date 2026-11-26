import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:smart_wrong_notebook/src/data/repositories/settings_repository.dart';
import 'package:smart_wrong_notebook/src/features/update/application/apk_integrity_verifier.dart';
import 'package:smart_wrong_notebook/src/features/update/domain/app_update_models.dart';

const String kStagedUpdateSettingsKey = 'staged_app_update_v1';
const String kIgnoredUpdateVersionSettingsKey = 'ignored_update_version_v1';

class InstalledAppInfo {
  const InstalledAppInfo({
    required this.versionName,
    required this.updatesDirPath,
  });

  final String versionName;
  final String updatesDirPath;
}

abstract class AppUpdatePlatformBridge {
  bool get isSupportedPlatform;
  Future<InstalledAppInfo> getInstalledAppInfo();
  Future<String> installApk(String apkPath);
}

class MethodChannelAppUpdatePlatformBridge implements AppUpdatePlatformBridge {
  MethodChannelAppUpdatePlatformBridge();

  static const MethodChannel _channel =
      MethodChannel('smart_wrong_notebook/app_updater');

  @override
  bool get isSupportedPlatform => Platform.isAndroid;

  @override
  Future<InstalledAppInfo> getInstalledAppInfo() async {
    if (Platform.isAndroid) {
      try {
        final raw = await _channel.invokeMapMethod<String, dynamic>(
          'getAppInfo',
        );
        if (raw != null) {
          final versionName = normalizeVersionString(
            (raw['versionName'] as String?) ?? kDefaultFallbackAppVersion,
          );
          final dirPath = (raw['updatesDir'] as String?)?.trim() ?? '';
          if (dirPath.isNotEmpty) {
            return InstalledAppInfo(
              versionName: versionName.isEmpty
                  ? kDefaultFallbackAppVersion
                  : versionName,
              updatesDirPath: dirPath,
            );
          }
        }
      } catch (_) {}
    }

    Directory baseDir;
    try {
      baseDir = await getApplicationSupportDirectory();
    } catch (_) {
      baseDir = Directory.systemTemp;
    }
    return InstalledAppInfo(
      versionName: kDefaultFallbackAppVersion,
      updatesDirPath: p.join(baseDir.path, 'app_updates'),
    );
  }

  @override
  Future<String> installApk(String apkPath) async {
    final status = await _channel.invokeMethod<String>(
      'installApk',
      <String, dynamic>{'apkPath': apkPath},
    );
    return status ?? 'launched';
  }
}

class ApkHttpStreamResponse {
  const ApkHttpStreamResponse({
    required this.statusCode,
    required this.stream,
    this.etag,
  });

  final int statusCode;
  final Stream<List<int>> stream;
  final String? etag;
}

abstract class AppUpdateHttpClient {
  Future<RemoteReleaseInfo?> fetchLatestRelease();

  Future<ApkHttpStreamResponse> openApkStream({
    required String url,
    required int resumeFromByte,
    String? ifRangeEtag,
  });
}

class DioAppUpdateHttpClient implements AppUpdateHttpClient {
  DioAppUpdateHttpClient({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 45),
                sendTimeout: const Duration(seconds: 10),
                followRedirects: true,
                maxRedirects: 6,
              ),
            );

  final Dio _dio;

  @override
  Future<RemoteReleaseInfo?> fetchLatestRelease() async {
    final response = await _dio.get<Map<String, dynamic>>(
      kGitHubLatestReleaseApiUrl,
      options: Options(
        headers: const <String, String>{
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
        },
        receiveTimeout: const Duration(seconds: 12),
      ),
    );
    final data = response.data;
    if (response.statusCode != 200 || data == null) {
      return null;
    }
    return RemoteReleaseInfo.tryParseGitHubReleaseJson(data);
  }

  @override
  Future<ApkHttpStreamResponse> openApkStream({
    required String url,
    required int resumeFromByte,
    String? ifRangeEtag,
  }) async {
    final headers = <String, String>{
      'Accept': 'application/octet-stream',
    };
    if (resumeFromByte > 0) {
      headers['Range'] = 'bytes=$resumeFromByte-';
      if (ifRangeEtag != null && ifRangeEtag.trim().isNotEmpty) {
        headers['If-Range'] = ifRangeEtag.trim();
      }
    }

    final response = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        headers: headers,
        // Accept both 200 (full stream from 0) and 206 (resumed partial range).
        validateStatus: (code) => code == 200 || code == 206,
      ),
    );
    final body = response.data;
    if (body == null) {
      throw StateError('Empty response stream');
    }
    final etag = response.headers.value('etag');
    return ApkHttpStreamResponse(
      statusCode: response.statusCode ?? 200,
      stream: body.stream,
      etag: etag,
    );
  }
}

/// Silent background update stager with HTTP Range resume (`断点续传`),
/// strict size + ZIP magic + SHA-256 verification, and post-upgrade cleanup.
///
/// Never throws network/IO errors to callers during silent checks so unreachable
/// GitHub or half-downloaded packages never interrupt normal app usage.
class AppUpdateService {
  AppUpdateService({
    required this.settingsRepository,
    required this.platformBridge,
    required this.httpClient,
  });

  final SettingsRepository settingsRepository;
  final AppUpdatePlatformBridge platformBridge;
  final AppUpdateHttpClient httpClient;

  Future<StagedAppUpdate?>? _inFlightStaging;

  static String _sanitizeTag(String tag) {
    return tag.replaceAll(RegExp(r'[^A-Za-z0-9._\-]'), '_');
  }

  /// Inspects local disk for an already-staged, verified APK newer than the
  /// installed version, and cleans up obsolete APKs if the user already upgraded.
  Future<
      ({
        String currentVersion,
        StagedAppUpdate? readyUpdate,
        String? ignoredVersion,
      })> loadLocalState() async {
    InstalledAppInfo appInfo;
    try {
      appInfo = await platformBridge.getInstalledAppInfo();
    } catch (_) {
      appInfo = const InstalledAppInfo(
        versionName: kDefaultFallbackAppVersion,
        updatesDirPath: '',
      );
    }

    final currentVersion = appInfo.versionName;
    String? ignoredVersion;
    StagedAppUpdate? stored;
    try {
      ignoredVersion =
          await settingsRepository.getString(kIgnoredUpdateVersionSettingsKey);
      final rawStaged =
          await settingsRepository.getString(kStagedUpdateSettingsKey);
      stored = StagedAppUpdate.tryFromJsonString(rawStaged);
    } catch (_) {}

    if (stored == null) {
      return (
        currentVersion: currentVersion,
        readyUpdate: null,
        ignoredVersion: ignoredVersion,
      );
    }

    // Post-upgrade cleanup: if installed version >= staged version, reclaim disk!
    if (compareAppVersions(stored.version, currentVersion) <= 0) {
      await _cleanupAllFilesInDir(appInfo.updatesDirPath);
      await _clearPersistedStagedUpdate(clearIgnored: true);
      return (
        currentVersion: currentVersion,
        readyUpdate: null,
        ignoredVersion: null,
      );
    }

    // Verify the staged APK file still exists on disk and matches size + header.
    final stillValid = await verifyApkFileIntegrity(
      filePath: stored.apkPath,
      expectedSize: stored.fileSize,
      expectedSha256Hex: stored.sha256Hex,
    );
    if (!stillValid) {
      try {
        final f = File(stored.apkPath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      await _clearPersistedStagedUpdate(clearIgnored: false);
      return (
        currentVersion: currentVersion,
        readyUpdate: null,
        ignoredVersion: ignoredVersion,
      );
    }

    return (
      currentVersion: currentVersion,
      readyUpdate: stored,
      ignoredVersion: ignoredVersion,
    );
  }

  /// Silently checks GitHub Releases and downloads/resumes any newer APK in the
  /// background. Returns a [StagedAppUpdate] ONLY when the complete package has
  /// been downloaded and cryptographically verified; returns `null` on any
  /// network failure, incomplete transfer, or when already up-to-date.
  Future<StagedAppUpdate?> stageLatestReleaseSilently() {
    if (!platformBridge.isSupportedPlatform) {
      return Future<StagedAppUpdate?>.value(null);
    }
    final existing = _inFlightStaging;
    if (existing != null) return existing;

    final future = _runSilentStageInternal();
    _inFlightStaging = future;
    return future.whenComplete(() {
      if (identical(_inFlightStaging, future)) {
        _inFlightStaging = null;
      }
    });
  }

  Future<StagedAppUpdate?> _runSilentStageInternal() async {
    try {
      final appInfo = await platformBridge.getInstalledAppInfo();
      if (appInfo.updatesDirPath.isEmpty) return null;

      final updatesDir = Directory(appInfo.updatesDirPath);
      if (!updatesDir.existsSync()) {
        updatesDir.createSync(recursive: true);
      }

      final remote = await httpClient.fetchLatestRelease();
      if (remote == null) return null;

      if (compareAppVersions(remote.version, appInfo.versionName) <= 0) {
        await _cleanupAllFilesInDir(updatesDir.path);
        await _clearPersistedStagedUpdate(clearIgnored: true);
        return null;
      }

      final safeTag = _sanitizeTag(remote.tagName);
      final finalApkPath = p.join(updatesDir.path, 'update_$safeTag.apk');
      final partApkPath = p.join(updatesDir.path, 'update_$safeTag.apk.part');
      final metaPath = p.join(updatesDir.path, 'update_$safeTag.meta.json');

      // Remove obsolete partial/staged files belonging to older tags first.
      await _cleanupStaleTagFiles(
        updatesDir: updatesDir,
        keepPrefix: 'update_$safeTag.',
      );

      // Fast path: already completely staged and verified on disk!
      if (File(finalApkPath).existsSync()) {
        final valid = await verifyApkFileIntegrity(
          filePath: finalApkPath,
          expectedSize: remote.apkSize,
          expectedSha256Hex: remote.sha256Hex,
        );
        if (valid) {
          final staged = StagedAppUpdate(
            tagName: remote.tagName,
            version: remote.version,
            releaseNotes: remote.releaseNotes,
            apkPath: finalApkPath,
            fileSize: File(finalApkPath).lengthSync(),
            sha256Hex: remote.sha256Hex,
            stagedAt: DateTime.now(),
          );
          await _persistStagedUpdate(staged);
          return staged;
        } else {
          try {
            File(finalApkPath).deleteSync();
          } catch (_) {}
        }
      }

      final partFile = File(partApkPath);
      final metaFile = File(metaPath);

      var resumeOffset = 0;
      String? savedEtag;

      if (partFile.existsSync()) {
        final partLen = partFile.lengthSync();
        final meta = _readPartMeta(metaFile);
        final sameAsset = meta != null &&
            meta['url'] == remote.apkDownloadUrl &&
            (remote.apkSize <= 0 || meta['expectedSize'] == remote.apkSize) &&
            (remote.sha256Hex == null || meta['sha256Hex'] == remote.sha256Hex);

        if (!sameAsset ||
            (remote.apkSize > 0 && partLen > remote.apkSize) ||
            partLen < 0) {
          _safeDelete(partFile);
          _safeDelete(metaFile);
          resumeOffset = 0;
        } else if (remote.apkSize > 0 && partLen == remote.apkSize) {
          resumeOffset = partLen;
        } else {
          resumeOffset = partLen;
          savedEtag = meta['etag'] as String?;
        }
      }

      // Download or resume `.apk.part` if not already at full expected length.
      if (remote.apkSize <= 0 || resumeOffset < remote.apkSize) {
        final streamResp = await httpClient.openApkStream(
          url: remote.apkDownloadUrl,
          resumeFromByte: resumeOffset,
          ifRangeEtag: savedEtag,
        );

        final isPartialAppend =
            resumeOffset > 0 && streamResp.statusCode == 206;
        if (!isPartialAppend && partFile.existsSync()) {
          // Server ignored Range or asset changed (200 OK) -> restart cleanly at 0.
          _safeDelete(partFile);
        }

        _writePartMeta(
          metaFile,
          url: remote.apkDownloadUrl,
          expectedSize: remote.apkSize,
          sha256Hex: remote.sha256Hex,
          etag: streamResp.etag ?? savedEtag,
        );

        final sink = partFile.openWrite(
          mode: isPartialAppend ? FileMode.append : FileMode.write,
        );
        try {
          await for (final chunk in streamResp.stream) {
            if (chunk.isNotEmpty) {
              sink.add(chunk);
            }
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
      }

      // Verify full integrity (exact byte size + ZIP header + SHA-256).
      final verified = await verifyApkFileIntegrity(
        filePath: partFile.path,
        expectedSize: remote.apkSize,
        expectedSha256Hex: remote.sha256Hex,
      );
      if (!verified) {
        // Corrupted or truncated transfer: if larger/equal to expectedSize it
        // is corrupt so delete it; if smaller (truncated stream without error),
        // keep `.part` for next resume!
        final currentLen = partFile.existsSync() ? partFile.lengthSync() : 0;
        if (remote.apkSize <= 0 || currentLen >= remote.apkSize) {
          _safeDelete(partFile);
          _safeDelete(metaFile);
        }
        return null;
      }

      // Atomic promotion from `.apk.part` -> `.apk`.
      final finalFile = await partFile.rename(finalApkPath);
      _safeDelete(metaFile);

      final staged = StagedAppUpdate(
        tagName: remote.tagName,
        version: remote.version,
        releaseNotes: remote.releaseNotes,
        apkPath: finalFile.path,
        fileSize: finalFile.lengthSync(),
        sha256Hex: remote.sha256Hex,
        stagedAt: DateTime.now(),
      );
      await _persistStagedUpdate(staged);
      return staged;
    } catch (_) {
      // Silent by design: keep `.apk.part` intact on disk for next Range resume!
      return null;
    }
  }

  Future<void> setIgnoredVersion(String version) async {
    try {
      await settingsRepository.setString(
        kIgnoredUpdateVersionSettingsKey,
        normalizeVersionString(version),
      );
    } catch (_) {}
  }

  Future<String> installStagedUpdate(StagedAppUpdate update) async {
    final valid = await verifyApkFileIntegrity(
      filePath: update.apkPath,
      expectedSize: update.fileSize,
      expectedSha256Hex: update.sha256Hex,
    );
    if (!valid) {
      await _clearPersistedStagedUpdate(clearIgnored: false);
      throw StateError('更新安装包已失效，将在后台重新准备');
    }
    return platformBridge.installApk(update.apkPath);
  }

  Future<void> _persistStagedUpdate(StagedAppUpdate staged) async {
    try {
      await settingsRepository.setString(
        kStagedUpdateSettingsKey,
        jsonEncode(staged.toJson()),
      );
    } catch (_) {}
  }

  Future<void> _clearPersistedStagedUpdate({required bool clearIgnored}) async {
    try {
      await settingsRepository.setString(kStagedUpdateSettingsKey, '');
      if (clearIgnored) {
        await settingsRepository.setString(
          kIgnoredUpdateVersionSettingsKey,
          '',
        );
      }
    } catch (_) {}
  }

  static Map<String, dynamic>? _readPartMeta(File metaFile) {
    if (!metaFile.existsSync()) return null;
    try {
      final decoded = jsonDecode(metaFile.readAsStringSync());
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  static void _writePartMeta(
    File metaFile, {
    required String url,
    required int expectedSize,
    String? sha256Hex,
    String? etag,
  }) {
    try {
      metaFile.writeAsStringSync(
        jsonEncode(<String, dynamic>{
          'url': url,
          'expectedSize': expectedSize,
          if (sha256Hex != null) 'sha256Hex': sha256Hex,
          if (etag != null && etag.isNotEmpty) 'etag': etag,
        }),
        flush: true,
      );
    } catch (_) {}
  }

  static void _safeDelete(File file) {
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  static Future<void> _cleanupStaleTagFiles({
    required Directory updatesDir,
    required String keepPrefix,
  }) async {
    try {
      if (!updatesDir.existsSync()) return;
      for (final entity in updatesDir.listSync()) {
        if (entity is File) {
          final base = p.basename(entity.path);
          if (!base.startsWith(keepPrefix)) {
            _safeDelete(entity);
          }
        }
      }
    } catch (_) {}
  }

  static Future<void> _cleanupAllFilesInDir(String dirPath) async {
    if (dirPath.isEmpty) return;
    try {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) return;
      for (final entity in dir.listSync()) {
        if (entity is File) {
          _safeDelete(entity);
        }
      }
    } catch (_) {}
  }
}

class AppUpdateController extends StateNotifier<AppUpdateState> {
  AppUpdateController(this._service) : super(const AppUpdateState());

  final AppUpdateService _service;
  bool _initialized = false;

  /// Called once at app startup: checks whether a previously downloaded APK is
  /// already verified & waiting on disk (for instant prompt), then silently
  /// kicks off background check/resumable download for future launches.
  Future<void> initializeOnStartup() async {
    if (_initialized) return;
    _initialized = true;

    final local = await _service.loadLocalState();
    if (!mounted) return;
    state = state.copyWith(
      currentVersion: local.currentVersion,
      readyUpdate: local.readyUpdate,
      clearReadyUpdate: local.readyUpdate == null,
      ignoredStartupVersion:
          (local.ignoredVersion != null && local.ignoredVersion!.isNotEmpty)
              ? local.ignoredVersion
              : null,
      clearIgnoredStartupVersion:
          local.ignoredVersion == null || local.ignoredVersion!.isEmpty,
    );

    unawaited(triggerSilentBackgroundStage());
  }

  /// Refreshes local disk state and triggers/continues silent background
  /// staging. Returns the verified [StagedAppUpdate] ONLY if it is already
  /// 100% ready on disk right now.
  Future<StagedAppUpdate?> checkReadyOrContinueStaging() async {
    final local = await _service.loadLocalState();
    if (!mounted) return null;
    state = state.copyWith(
      currentVersion: local.currentVersion,
      readyUpdate: local.readyUpdate,
      clearReadyUpdate: local.readyUpdate == null,
    );
    if (local.readyUpdate != null) {
      return local.readyUpdate;
    }
    unawaited(triggerSilentBackgroundStage());
    return null;
  }

  Future<void> triggerSilentBackgroundStage() async {
    if (!mounted || !_service.platformBridge.isSupportedPlatform) return;
    state = state.copyWith(isStagingSilently: true);
    final staged = await _service.stageLatestReleaseSilently();
    if (!mounted) return;
    if (staged != null) {
      // Mark startupPromptHandled = true when staged mid-session so we NEVER
      // interrupt the user in the middle of taking photos or studying; it will
      // prompt on next app launch or when tapping '检查更新' in Settings!
      state = state.copyWith(
        readyUpdate: staged,
        startupPromptHandled: true,
        isStagingSilently: false,
      );
    } else {
      state = state.copyWith(isStagingSilently: false);
    }
  }

  void markStartupPromptHandled() {
    if (!mounted) return;
    state = state.copyWith(startupPromptHandled: true);
  }

  Future<void> ignoreStartupPromptFor(String version) async {
    await _service.setIgnoredVersion(version);
    if (!mounted) return;
    state = state.copyWith(
      ignoredStartupVersion: normalizeVersionString(version),
      startupPromptHandled: true,
    );
  }

  Future<String> installReadyUpdate(StagedAppUpdate update) async {
    try {
      return await _service.installStagedUpdate(update);
    } catch (_) {
      if (mounted) {
        state = state.copyWith(clearReadyUpdate: true);
        unawaited(triggerSilentBackgroundStage());
      }
      rethrow;
    }
  }
}
