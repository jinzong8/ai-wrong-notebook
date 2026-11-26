import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/data/repositories/question_repository.dart';
import 'package:smart_wrong_notebook/src/data/repositories/settings_repository.dart';
import 'package:smart_wrong_notebook/src/features/settings/presentation/settings_screen.dart';
import 'package:smart_wrong_notebook/src/features/update/application/apk_integrity_verifier.dart';
import 'package:smart_wrong_notebook/src/features/update/data/app_update_service.dart';
import 'package:smart_wrong_notebook/src/features/update/domain/app_update_models.dart';
import 'package:smart_wrong_notebook/src/features/update/presentation/app_update_dialog.dart';

/// Builds a synthetic valid APK byte payload starting with ZIP magic `PK\x03\x04`.
Uint8List _buildFakeApkBytes(int length, {int seed = 7}) {
  final bytes = Uint8List(length);
  bytes[0] = 0x50; // 'P'
  bytes[1] = 0x4B; // 'K'
  bytes[2] = 0x03;
  bytes[3] = 0x04;
  for (var i = 4; i < length; i++) {
    bytes[i] = (i * 31 + seed) & 0xFF;
  }
  return bytes;
}

class _FakeUpdatePlatformBridge implements AppUpdatePlatformBridge {
  _FakeUpdatePlatformBridge({
    required this.updatesDirPath,
    this.versionName = '1.0.11',
  });

  String versionName;
  final String updatesDirPath;
  final List<String> installedPaths = <String>[];

  @override
  bool get isSupportedPlatform => true;

  @override
  Future<InstalledAppInfo> getInstalledAppInfo() async {
    return InstalledAppInfo(
      versionName: versionName,
      updatesDirPath: updatesDirPath,
    );
  }

  @override
  Future<String> installApk(String apkPath) async {
    installedPaths.add(apkPath);
    return 'launched';
  }
}

class _FakeUpdateHttpClient implements AppUpdateHttpClient {
  _FakeUpdateHttpClient({
    this.latestRelease,
    this.throwOnFetch = false,
  });

  RemoteReleaseInfo? latestRelease;
  bool throwOnFetch;

  final List<int> requestedResumeOffsets = <int>[];
  final List<String?> requestedIfRangeEtags = <String?>[];
  Future<ApkHttpStreamResponse> Function(int resumeFromByte, String? etag)?
      onOpenStream;

  @override
  Future<RemoteReleaseInfo?> fetchLatestRelease() async {
    if (throwOnFetch) {
      throw const SocketException('GitHub unreachable');
    }
    return latestRelease;
  }

  @override
  Future<ApkHttpStreamResponse> openApkStream({
    required String url,
    required int resumeFromByte,
    String? ifRangeEtag,
  }) async {
    requestedResumeOffsets.add(resumeFromByte);
    requestedIfRangeEtags.add(ifRangeEtag);
    if (onOpenStream == null) {
      throw const SocketException('Stream unavailable');
    }
    return onOpenStream!(resumeFromByte, ifRangeEtag);
  }
}

void main() {
  group('Version & GitHub Release JSON parsing', () {
    test(
        'compareAppVersions handles v-prefix, +build metadata, and multi-digit segments',
        () {
      expect(compareAppVersions('1.0.9', '1.0.10'), lessThan(0));
      expect(compareAppVersions('v1.0.11+12', '1.0.11'), 0);
      expect(compareAppVersions('v1.0.12', '1.0.11+99'), greaterThan(0));
      expect(compareAppVersions('1.1.0', '1.0.99'), greaterThan(0));
    });

    test(
        'tryParseGitHubReleaseJson extracts official APK asset and sha256 digest',
        () {
      final parsed = RemoteReleaseInfo.tryParseGitHubReleaseJson(
        <String, dynamic>{
          'tag_name': 'v1.0.12',
          'draft': false,
          'prerelease': false,
          'published_at': '2026-11-26T00:00:00Z',
          'body': '## 更新内容\n- 新增静默断点续传更新',
          'assets': <Map<String, dynamic>>[
            <String, dynamic>{
              'name': 'ai-wrong-notebook-v1.0.12.zip',
              'size': 38000000,
              'content_type': 'application/zip',
              'browser_download_url':
                  'https://github.com/jinzong8/ai-wrong-notebook/releases/download/v1.0.12/ai-wrong-notebook-v1.0.12.zip',
            },
            <String, dynamic>{
              'name': 'app-release.apk',
              'size': 77172608,
              'digest':
                  'sha256:7ab67058a81a25f459892f496dfec1f6358952c2561c1081f304f2e8b5327432',
              'content_type': 'application/vnd.android.package-archive',
              'browser_download_url':
                  'https://github.com/jinzong8/ai-wrong-notebook/releases/download/v1.0.12/app-release.apk',
            },
          ],
        },
      );

      expect(parsed, isNotNull);
      expect(parsed!.version, '1.0.12');
      expect(parsed.apkSize, 77172608);
      expect(
        parsed.sha256Hex,
        '7ab67058a81a25f459892f496dfec1f6358952c2561c1081f304f2e8b5327432',
      );
      expect(parsed.apkDownloadUrl, endsWith('/app-release.apk'));
    });
  });

  group('Silent resumable staging, integrity verification & cleanup', () {
    test(
        'resumes interrupted .apk.part via HTTP 206 Range and only marks ready after full SHA-256 match',
        () async {
      final tempDir = Directory.systemTemp.createTempSync('app_update_resume_');
      try {
        final fullApk = _buildFakeApkBytes(2048);
        final expectedSha = sha256.convert(fullApk).toString();
        final settings = InMemorySettingsRepository();
        final bridge = _FakeUpdatePlatformBridge(
          updatesDirPath: '${tempDir.path}/app_updates',
          versionName: '1.0.11',
        );
        final release = RemoteReleaseInfo(
          tagName: 'v1.0.12',
          version: '1.0.12',
          releaseNotes: '修复若干体验细节',
          apkDownloadUrl:
              'https://github.com/jinzong8/ai-wrong-notebook/releases/download/v1.0.12/app-release.apk',
          apkSize: fullApk.length,
          sha256Hex: expectedSha,
        );

        final httpClient = _FakeUpdateHttpClient(latestRelease: release);

        // Attempt 1: stream drops after 700 bytes!
        httpClient.onOpenStream = (resumeFrom, etag) async {
          Stream<List<int>> brokenStream() async* {
            yield fullApk.sublist(0, 700);
            throw const SocketException('Connection reset by peer');
          }

          return ApkHttpStreamResponse(
            statusCode: 200,
            etag: '"etag-1012"',
            stream: brokenStream(),
          );
        };

        final service = AppUpdateService(
          settingsRepository: settings,
          platformBridge: bridge,
          httpClient: httpClient,
        );

        final firstTry = await service.stageLatestReleaseSilently();
        expect(firstTry, isNull);
        expect(httpClient.requestedResumeOffsets, <int>[0]);

        final partFile =
            File('${tempDir.path}/app_updates/update_v1.0.12.apk.part');
        expect(partFile.existsSync(), isTrue);
        expect(partFile.lengthSync(), 700);

        // Local state MUST NOT report ready while only partially downloaded!
        final midState = await service.loadLocalState();
        expect(midState.readyUpdate, isNull);

        // Attempt 2: server honors Range: bytes=700- with 206 Partial Content!
        httpClient.onOpenStream = (resumeFrom, etag) async {
          return ApkHttpStreamResponse(
            statusCode: 206,
            etag: '"etag-1012"',
            stream: Stream<List<int>>.value(fullApk.sublist(resumeFrom)),
          );
        };

        final secondTry = await service.stageLatestReleaseSilently();
        expect(httpClient.requestedResumeOffsets, <int>[0, 700]);
        expect(httpClient.requestedIfRangeEtags.last, '"etag-1012"');
        expect(secondTry, isNotNull);
        expect(secondTry!.version, '1.0.12');
        expect(secondTry.fileSize, 2048);
        expect(partFile.existsSync(), isFalse);
        expect(File(secondTry.apkPath).existsSync(), isTrue);

        // Post-upgrade cleanup: once user installs v1.0.12, startup cleans APK!
        bridge.versionName = '1.0.12';
        final postUpgrade = await service.loadLocalState();
        expect(postUpgrade.readyUpdate, isNull);
        expect(File(secondTry.apkPath).existsSync(), isFalse);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('rejects tampered SHA-256 or non-APK HTML payload silently', () async {
      final tempDir = Directory.systemTemp.createTempSync('app_update_tamper_');
      try {
        final htmlBytes =
            Uint8List.fromList('<html>Captive Portal</html>'.codeUnits);
        final htmlFile = File('${tempDir.path}/portal.apk')
          ..writeAsBytesSync(htmlBytes);
        expect(
          await verifyApkFileIntegrity(
            filePath: htmlFile.path,
            expectedSize: htmlBytes.length,
          ),
          isFalse,
        );

        final validApk = _buildFakeApkBytes(512);
        final settings = InMemorySettingsRepository();
        final bridge = _FakeUpdatePlatformBridge(
          updatesDirPath: '${tempDir.path}/app_updates',
          versionName: '1.0.11',
        );
        final httpClient = _FakeUpdateHttpClient(
          latestRelease: RemoteReleaseInfo(
            tagName: 'v1.0.12',
            version: '1.0.12',
            releaseNotes: 'test',
            apkDownloadUrl:
                'https://github.com/jinzong8/ai-wrong-notebook/releases/download/v1.0.12/app-release.apk',
            apkSize: validApk.length,
            sha256Hex:
                '0000000000000000000000000000000000000000000000000000000000000000',
          ),
        )..onOpenStream = (_, __) async => ApkHttpStreamResponse(
              statusCode: 200,
              stream: Stream<List<int>>.value(validApk),
            );

        final service = AppUpdateService(
          settingsRepository: settings,
          platformBridge: bridge,
          httpClient: httpClient,
        );
        final staged = await service.stageLatestReleaseSilently();
        expect(staged, isNull);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('UI prompt rules (startup & Settings 检查更新)', () {
    testWidgets(
        'stays completely silent when GitHub is unreachable, and prompts only when verified APK is ready',
        (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('app_update_ui_');
      try {
        final settings = InMemorySettingsRepository();
        final bridge = _FakeUpdatePlatformBridge(
          updatesDirPath: '${tempDir.path}/app_updates',
          versionName: '1.0.11',
        );
        final httpClient = _FakeUpdateHttpClient(throwOnFetch: true);

        // 1. Cold start while GitHub is unreachable -> zero dialog, zero error!
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              questionRepositoryProvider
                  .overrideWithValue(InMemoryQuestionRepository()),
              settingsRepositoryProvider.overrideWithValue(settings),
              appUpdatePlatformBridgeProvider.overrideWithValue(bridge),
              appUpdateHttpClientProvider.overrideWithValue(httpClient),
            ],
            child: const MaterialApp(
              home: AppUpdateStartupListener(
                child: SettingsScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('已准备就绪'), findsNothing);

        // 2. Now stage a verified v1.0.12 APK in the background while in-session:
        // must NOT pop a surprise dialog mid-session, but tapping '检查更新'
        // in Settings immediately opens the zero-wait install dialog!
        final apkBytes = _buildFakeApkBytes(1024, seed: 42);
        final shaHex = sha256.convert(apkBytes).toString();
        httpClient
          ..throwOnFetch = false
          ..latestRelease = RemoteReleaseInfo(
            tagName: 'v1.0.12',
            version: '1.0.12',
            releaseNotes: '- 支持多边形无痕框选\n- 支持静默断点续传升级',
            apkDownloadUrl:
                'https://github.com/jinzong8/ai-wrong-notebook/releases/download/v1.0.12/app-release.apk',
            apkSize: apkBytes.length,
            sha256Hex: shaHex,
          )
          ..onOpenStream = (_, __) async => ApkHttpStreamResponse(
                statusCode: 200,
                stream: Stream<List<int>>.value(apkBytes),
              );

        final element = tester.element(find.byType(SettingsScreen));
        final container = ProviderScope.containerOf(element);
        await tester.runAsync(() async {
          await container
              .read(appUpdateControllerProvider.notifier)
              .triggerSilentBackgroundStage();
        });
        await tester.pumpAndSettle();

        // Still no unsolicited popup mid-session!
        expect(find.byKey(const Key('update-install-now')), findsNothing);

        // Scroll to '检查更新' in Settings -> shows green '已就绪' pill!
        await tester.scrollUntilVisible(
          find.byKey(const Key('settings-check-update')),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(find.text('已就绪'), findsOneWidget);

        await tester.tap(find.byKey(const Key('settings-check-update')));
        await tester.pumpAndSettle();

        expect(find.text('新版本 v1.0.12 已准备就绪'), findsOneWidget);
        expect(find.textContaining('支持多边形无痕框选'), findsOneWidget);

        // Tap '立即安装' -> launches native APK installer immediately!
        await tester.runAsync(() async {
          await tester.tap(find.byKey(const Key('update-install-now')));
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pumpAndSettle();
        expect(bridge.installedPaths, hasLength(1));

        // 3. Simulate next cold start with the staged APK already waiting on disk
        // -> automatically pops up the ready-to-install dialog on startup!
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();

        await tester.runAsync(() async {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                questionRepositoryProvider
                    .overrideWithValue(InMemoryQuestionRepository()),
                settingsRepositoryProvider.overrideWithValue(settings),
                appUpdatePlatformBridgeProvider.overrideWithValue(bridge),
                appUpdateHttpClientProvider.overrideWithValue(httpClient),
              ],
              child: const MaterialApp(
                home: AppUpdateStartupListener(
                  child: Scaffold(body: Text('HOME_READY')),
                ),
              ),
            ),
          );
          await tester.pump();
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await tester.pumpAndSettle();

        expect(find.text('新版本 v1.0.12 已准备就绪'), findsOneWidget);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
