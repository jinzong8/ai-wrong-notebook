import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/data/files/image_storage_service.dart';
import 'package:smart_wrong_notebook/src/data/repositories/question_repository.dart';
import 'package:smart_wrong_notebook/src/data/repositories/settings_repository.dart';
import 'package:smart_wrong_notebook/src/data/services/capture_service.dart';
import 'package:smart_wrong_notebook/src/domain/models/ai_provider_config.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/camera_capture_session.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/camera_capture_crop_screen.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/capture_entry_sheet.dart';
import 'package:smart_wrong_notebook/src/features/home/presentation/home_screen.dart';
import 'package:smart_wrong_notebook/src/features/notebook/presentation/notebook_screen.dart';

class _TempImageStorageService extends ImageStorageService {
  _TempImageStorageService(this.outputDir);

  final Directory outputDir;
  String? lastSavedPath;
  int saveCount = 0;

  @override
  Future<String> saveImage(File source) async {
    saveCount++;
    final targetPath =
        '${outputDir.path}/saved_${saveCount}_${DateTime.now().microsecondsSinceEpoch}.jpg';
    await source.copy(targetPath);
    lastSavedPath = targetPath;
    return targetPath;
  }
}

class _FakeCameraCaptureSession implements CameraCaptureSession {
  _FakeCameraCaptureSession({
    this.photoFactory,
    this.initError,
  });

  final File Function()? photoFactory;
  final Object? initError;

  bool _initialized = false;
  bool disposed = false;
  CaptureFlashMode _flashMode = CaptureFlashMode.off;

  int initializeCount = 0;
  int takePictureCount = 0;
  int pausePreviewCount = 0;
  int resumePreviewCount = 0;
  Offset? lastFocusPoint;
  File? lastTakenFile;
  final List<CaptureFlashMode> flashHistory = <CaptureFlashMode>[];

  @override
  bool get isInitialized => _initialized && !disposed;

  @override
  CaptureFlashMode get flashMode => _flashMode;

  @override
  double? get previewAspectRatio => isInitialized ? (9 / 16) : null;

  @override
  Future<void> initialize() async {
    initializeCount++;
    if (initError != null) {
      throw initError!;
    }
    _initialized = true;
  }

  @override
  Widget buildPreview() {
    return const AspectRatio(
      aspectRatio: 9 / 16,
      child: ColoredBox(
        key: Key('fake-camera-preview'),
        color: Color(0xFF1F2937),
      ),
    );
  }

  @override
  Future<File> takePicture() async {
    takePictureCount++;
    final file = photoFactory!();
    lastTakenFile = file;
    return file;
  }

  @override
  Future<CaptureFlashMode> cycleFlashMode() async {
    _flashMode = switch (_flashMode) {
      CaptureFlashMode.off => CaptureFlashMode.auto,
      CaptureFlashMode.auto => CaptureFlashMode.torch,
      CaptureFlashMode.torch => CaptureFlashMode.off,
    };
    flashHistory.add(_flashMode);
    return _flashMode;
  }

  @override
  Future<void> setFocusPoint(Offset normalizedPoint) async {
    lastFocusPoint = normalizedPoint;
  }

  @override
  Future<void> pausePreview() async {
    pausePreviewCount++;
  }

  @override
  Future<void> resumePreview() async {
    resumePreviewCount++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    _initialized = false;
  }
}

class _FakeCaptureService extends CaptureService {
  _FakeCaptureService({
    this.cameraResult,
    this.galleryResult,
  });

  final CaptureResult? cameraResult;
  final CaptureResult? galleryResult;
  int cameraCalls = 0;
  int galleryCalls = 0;

  @override
  Future<CaptureResult> pickFromCamera() async {
    cameraCalls++;
    return cameraResult ?? CaptureResult.cancel();
  }

  @override
  Future<CaptureResult> pickFromGallery() async {
    galleryCalls++;
    return galleryResult ?? CaptureResult.cancel();
  }
}

class _ConfiguredSettingsRepository implements SettingsRepository {
  @override
  Future<AiProviderConfig?> getAiProviderConfig() async {
    return const AiProviderConfig(
      id: 'openai',
      displayName: 'OpenAI',
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'sk-test-key',
      model: 'gpt-5',
    );
  }

  @override
  Future<void> saveAiProviderConfig(AiProviderConfig config) async {}

  @override
  Future<String?> getString(String key) async => null;

  @override
  Future<void> setString(String key, String value) async {}
}

/// Creates a synthetic 3-band portrait worksheet image:
/// - Top 40%: red (question above)
/// - Middle 20%: green (target single horizontal question)
/// - Bottom 40%: blue (question below)
File _createThreeBandWorksheetPng(
  Directory dir, {
  String name = 'captured.png',
  int width = 300,
  int height = 600,
}) {
  final canvas = img.Image(width: width, height: height);
  final band1End = (height * 0.4).round();
  final band2End = (height * 0.6).round();
  for (var y = 0; y < height; y++) {
    final r = y < band1End ? 220 : 20;
    final g = (y >= band1End && y < band2End) ? 210 : 20;
    final b = y >= band2End ? 220 : 20;
    for (var x = 0; x < width; x++) {
      canvas.setPixelRgb(x, y, r, g, b);
    }
  }
  final file = File('${dir.path}/$name');
  file.writeAsBytesSync(img.encodePng(canvas));
  return file;
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  int maxSteps = 80,
}) async {
  for (var i = 0; i < maxSteps && finder.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
}

void main() {
  group('CameraCaptureCropScreen', () {
    testWidgets(
      'capturing transitions directly into full-width in-place crop with aimed framing and manual adjustment',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync('camera_crop_');
        final storage = _TempImageStorageService(tempDir);
        var shotIndex = 0;
        final session = _FakeCameraCaptureSession(
          photoFactory: () => _createThreeBandWorksheetPng(
            tempDir,
            name: 'shot_${++shotIndex}.png',
            width: 300,
            height: 600,
          ),
        );

        final router = GoRouter(
          initialLocation: '/capture/camera',
          routes: <RouteBase>[
            GoRoute(
              path: '/',
              builder: (_, __) => const Scaffold(body: Text('HOME_ROUTE')),
            ),
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) => const CameraCaptureCropScreen(),
            ),
            GoRoute(
              path: '/analysis/loading',
              builder: (_, __) => const Scaffold(body: Text('LOADING_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        late ProviderContainer container;
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                cameraCaptureSessionFactoryProvider
                    .overrideWithValue(() => session),
                imageStorageServiceProvider.overrideWithValue(storage),
              ],
              child: Consumer(
                builder: (context, ref, _) {
                  container = ProviderScope.containerOf(context);
                  return MaterialApp.router(routerConfig: router);
                },
              ),
            ),
          );
          await tester.pumpAndSettle();

          // Live viewfinder is active before taking a photo.
          expect(
              find.byKey(const Key('camera-preview-surface')), findsOneWidget);
          expect(
              find.byKey(const Key('camera-shutter-button')), findsOneWidget);
          expect(find.byKey(const Key('crop-canvas')), findsNothing);
          expect(session.initializeCount, 1);

          final scaffoldWidth = tester.getRect(find.byType(Scaffold)).width;

          // Press shutter -> stays on /capture/camera and immediately freezes into full-width crop canvas.
          await tester.tap(find.byKey(const Key('camera-shutter-button')));
          await tester.pump();
          await _pumpUntilFound(tester, find.byKey(const Key('crop-canvas')));
          await tester.pumpAndSettle();

          expect(router.routeInformationProvider.value.uri.path,
              '/capture/camera');
          expect(session.takePictureCount, 1);
          expect(session.pausePreviewCount, 1);
          expect(find.byKey(const Key('crop-canvas')), findsOneWidget);
          expect(find.byKey(const Key('crop-retake-button')), findsOneWidget);
          expect(find.byKey(const Key('crop-confirm')), findsOneWidget);
          expect(find.byKey(const Key('crop-auto-select')), findsNothing);
          expect(find.byKey(const Key('camera-shutter-button')), findsNothing);
          expect(
            find.text('双指放大可触发多边形节点，轻松绕开相邻题目'),
            findsOneWidget,
          );

          // Frozen photo preserves the exact 100% viewport width (no narrowing).
          final imageRect = tester.getRect(find.byType(RawImage));
          expect(imageRect.width, closeTo(scaffoldWidth, 0.5));

          // Manually trim the right edge inward slightly to verify free drag
          // works directly from the aimed 4:1 box.
          final canvasRect =
              tester.getRect(find.byKey(const Key('crop-canvas')));
          await tester.dragFrom(
            Offset(canvasRect.right - 4, canvasRect.center.dy),
            Offset(-canvasRect.width * 0.25, 0),
          );
          await tester.pump();

          // Confirm crop -> encodes cropped JPEG and proceeds directly to analysis loading.
          await tester.tap(find.byKey(const Key('crop-confirm')));
          await tester.pump();
          await _pumpUntilFound(tester, find.text('LOADING_ROUTE'));
          await tester.pumpAndSettle();

          expect(find.text('LOADING_ROUTE'), findsOneWidget);
          expect(session.disposed, isTrue);
          expect(storage.lastSavedPath, isNotNull);

          final savedFile = File(storage.lastSavedPath!);
          expect(savedFile.existsSync(), isTrue);
          final cropped = img.decodeJpg(savedFile.readAsBytesSync())!;

          // Cropped width trimmed (~75% of 300px) and still a thin horizontal strip
          // centered strictly on the aimed middle green band.
          expect(cropped.width, inInclusiveRange(190, 250));
          expect(cropped.width / cropped.height, greaterThan(2.5));
          final center = cropped.getPixel(
            cropped.width ~/ 2,
            cropped.height ~/ 2,
          );
          expect(center.g, greaterThan(170));
          expect(center.r, lessThan(60));
          expect(center.b, lessThan(60));

          final updatedRecord = container.read(currentQuestionProvider);
          expect(updatedRecord, isNotNull);
          expect(updatedRecord!.imagePath, storage.lastSavedPath);
          expect(updatedRecord.contentStatus, ContentStatus.processing);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'retake button discards temp capture and immediately returns to live viewfinder',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync('camera_retake_');
        final session = _FakeCameraCaptureSession(
          photoFactory: () => _createThreeBandWorksheetPng(
            tempDir,
            name: 'retake_shot.png',
          ),
        );

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                cameraCaptureSessionFactoryProvider
                    .overrideWithValue(() => session),
              ],
              child: const MaterialApp(home: CameraCaptureCropScreen()),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('camera-shutter-button')));
          await tester.pump();
          await _pumpUntilFound(tester, find.byKey(const Key('crop-canvas')));
          await tester.pumpAndSettle();

          final tempShot = session.lastTakenFile!;
          expect(tempShot.existsSync(), isTrue);

          await tester.tap(find.byKey(const Key('crop-retake-button')));
          await tester.pumpAndSettle();

          expect(
              find.byKey(const Key('camera-shutter-button')), findsOneWidget);
          expect(find.byKey(const Key('crop-canvas')), findsNothing);
          expect(session.resumePreviewCount, 1);
          expect(tempShot.existsSync(), isFalse);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets('flash toggle cycles modes and tap-to-focus forwards point',
        (tester) async {
      final session = _FakeCameraCaptureSession();

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            cameraCaptureSessionFactoryProvider
                .overrideWithValue(() => session),
          ],
          child: const MaterialApp(home: CameraCaptureCropScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('camera-flash-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('camera-flash-button')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('camera-flash-button')));
      await tester.pump();

      expect(session.flashHistory, <CaptureFlashMode>[
        CaptureFlashMode.auto,
        CaptureFlashMode.torch,
        CaptureFlashMode.off,
      ]);

      await tester.tap(find.byKey(const Key('camera-preview-surface')));
      await tester.pump();

      expect(session.lastFocusPoint, isNotNull);
      expect(session.lastFocusPoint!.dx, closeTo(0.5, 0.05));
      expect(session.lastFocusPoint!.dy, closeTo(0.5, 0.05));

      // Advance past focus indicator timer so no pending timers remain.
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets(
      'camera init error shows fallback actions and system camera enters in-place crop',
      (tester) async {
        final tempDir = Directory.systemTemp.createTempSync('camera_fallback_');
        final existingFile = _createThreeBandWorksheetPng(
          tempDir,
          name: 'system_camera.png',
        );
        final fallbackDraft = QuestionRecord.draft(
          id: 'q-system-1',
          imagePath: existingFile.path,
          subject: Subject.math,
          recognizedText: '',
        );
        final fakeCapture = _FakeCaptureService(
          cameraResult: CaptureResult.success(fallbackDraft),
        );
        final failingSession = _FakeCameraCaptureSession(
          initError: Exception('CameraAccessDenied: permission denied'),
        );

        final router = GoRouter(
          initialLocation: '/capture/camera',
          routes: <RouteBase>[
            GoRoute(
              path: '/',
              builder: (_, __) => const Scaffold(body: Text('HOME_ROUTE')),
            ),
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) => const CameraCaptureCropScreen(),
            ),
            GoRoute(
              path: '/analysis/loading',
              builder: (_, __) => const Scaffold(body: Text('LOADING_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        late ProviderContainer container;
        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                cameraCaptureSessionFactoryProvider
                    .overrideWithValue(() => failingSession),
                captureServiceProvider.overrideWithValue(fakeCapture),
              ],
              child: Consumer(
                builder: (context, ref, _) {
                  container = ProviderScope.containerOf(context);
                  return MaterialApp.router(routerConfig: router);
                },
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.textContaining('相机权限未开启'), findsOneWidget);
          expect(find.byKey(const Key('camera-error-system-camera')),
              findsOneWidget);
          expect(find.byKey(const Key('camera-error-gallery')), findsOneWidget);
          expect(find.byKey(const Key('camera-retry-button')), findsOneWidget);

          // Fall back to system camera -> enters crop mode directly on this screen.
          await tester.tap(find.byKey(const Key('camera-error-system-camera')));
          await tester.pump();
          await _pumpUntilFound(tester, find.byKey(const Key('crop-canvas')));
          await tester.pumpAndSettle();

          expect(fakeCapture.cameraCalls, 1);
          expect(find.byKey(const Key('crop-canvas')), findsOneWidget);

          // Use original -> preserves existing path and navigates to /analysis/loading.
          await tester.tap(find.byKey(const Key('crop-use-original')));
          await tester.pumpAndSettle();

          expect(find.text('LOADING_ROUTE'), findsOneWidget);
          final record = container.read(currentQuestionProvider);
          expect(record, isNotNull);
          expect(record!.id, 'q-system-1');
          expect(record.imagePath, existingFile.path);
          expect(existingFile.existsSync(), isTrue);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'WYSIWYG aimed framing preserves 100% width on 9:16 portrait capture and crops exact 4:1 aimed strip',
      (tester) async {
        tester.view.physicalSize = const Size(412, 892);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tempDir =
            Directory.systemTemp.createTempSync('camera_wysiwyg_crop_');
        final storage = _TempImageStorageService(tempDir);
        final session = _FakeCameraCaptureSession(
          photoFactory: () => _createThreeBandWorksheetPng(
            tempDir,
            name: 'portrait_9_16.png',
            width: 360,
            height: 640,
          ),
        );

        final router = GoRouter(
          initialLocation: '/capture/camera',
          routes: <RouteBase>[
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) => const CameraCaptureCropScreen(),
            ),
            GoRoute(
              path: '/analysis/loading',
              builder: (_, __) => const Scaffold(body: Text('LOADING_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                cameraCaptureSessionFactoryProvider
                    .overrideWithValue(() => session),
                imageStorageServiceProvider.overrideWithValue(storage),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('camera-shutter-button')));
          await tester.pump();
          await _pumpUntilFound(tester, find.byKey(const Key('crop-canvas')));
          await tester.pumpAndSettle();

          expect(
            find.text('双指放大可触发多边形节点，轻松绕开相邻题目'),
            findsOneWidget,
          );
          expect(find.byKey(const Key('crop-auto-select')), findsNothing);

          // Frozen 9:16 photo stays at full 100% viewport width (412px),
          // matching the live viewfinder scale without black sidebars.
          final imageRect = tester.getRect(find.byType(RawImage));
          expect(imageRect.width, closeTo(412.0, 0.5));
          expect(imageRect.left, closeTo(0.0, 0.5));

          // Confirm directly WITHOUT dragging -> outputs the exact aimed 4:1
          // strip covering the middle green band!
          await tester.tap(find.byKey(const Key('crop-confirm')));
          await tester.pump();
          await _pumpUntilFound(tester, find.text('LOADING_ROUTE'));
          await tester.pumpAndSettle();

          expect(storage.lastSavedPath, isNotNull);
          final cropped =
              img.decodeJpg(File(storage.lastSavedPath!).readAsBytesSync())!;
          expect(cropped.width, 360);
          expect(cropped.width / cropped.height, closeTo(4.0, 0.35));
          final center = cropped.getPixel(
            cropped.width ~/ 2,
            cropped.height ~/ 2,
          );
          expect(center.g, greaterThan(170));
          expect(center.r, lessThan(60));
          expect(center.b, lessThan(60));
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'manual handle adjustment expands aimed crop box and reset restores aimed 4:1 box',
      (tester) async {
        tester.view.physicalSize = const Size(412, 892);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tempDir =
            Directory.systemTemp.createTempSync('camera_aimed_adjust_');
        final storage = _TempImageStorageService(tempDir);
        final session = _FakeCameraCaptureSession(
          photoFactory: () => _createThreeBandWorksheetPng(
            tempDir,
            name: 'portrait_adjust.png',
            width: 360,
            height: 640,
          ),
        );

        final router = GoRouter(
          initialLocation: '/capture/camera',
          routes: <RouteBase>[
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) => const CameraCaptureCropScreen(),
            ),
            GoRoute(
              path: '/analysis/loading',
              builder: (_, __) => const Scaffold(body: Text('LOADING_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                cameraCaptureSessionFactoryProvider
                    .overrideWithValue(() => session),
                imageStorageServiceProvider.overrideWithValue(storage),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('camera-shutter-button')));
          await tester.pump();
          await _pumpUntilFound(tester, find.byKey(const Key('crop-canvas')));
          await tester.pumpAndSettle();

          final canvasRect =
              tester.getRect(find.byKey(const Key('crop-canvas')));
          final guideHeight = canvasRect.width / 4.0;

          // Expand bottom edge downward + tilt angle, then reset back to the
          // aimed 4:1 box and 0°.
          await tester.dragFrom(
            Offset(
                canvasRect.center.dx, canvasRect.center.dy + guideHeight / 2),
            const Offset(0, 140),
          );
          await tester.drag(
            find.byKey(const Key('crop-angle-slider')),
            const Offset(80, 0),
          );
          await tester.pumpAndSettle();
          expect(find.text('0°'), findsNothing);

          await tester.tap(find.byKey(const Key('crop-reset')));
          await tester.pumpAndSettle();
          expect(find.text('0°'), findsOneWidget);

          // Now drag bottom edge downward again and confirm -> output must be
          // substantially taller than the initial ~90px aimed 4:1 strip.
          await tester.dragFrom(
            Offset(
                canvasRect.center.dx, canvasRect.center.dy + guideHeight / 2),
            const Offset(0, 140),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('crop-confirm')));
          await tester.pump();
          await _pumpUntilFound(tester, find.text('LOADING_ROUTE'));
          await tester.pumpAndSettle();

          final cropped =
              img.decodeJpg(File(storage.lastSavedPath!).readAsBytesSync())!;
          expect(cropped.width, 360);
          expect(cropped.height, greaterThan(170));
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );
  });

  group('CaptureEntrySheet navigation', () {
    testWidgets(
      'tapping 拍照 opens /capture/camera directly without calling system pickFromCamera',
      (tester) async {
        final fakeCapture = _FakeCaptureService();
        final router = GoRouter(
          initialLocation: '/',
          routes: <RouteBase>[
            GoRoute(
              path: '/',
              builder: (_, __) => const Scaffold(body: CaptureEntrySheet()),
            ),
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) =>
                  const Scaffold(body: Text('CAMERA_CROP_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              settingsRepositoryProvider
                  .overrideWithValue(_ConfiguredSettingsRepository()),
              captureServiceProvider.overrideWithValue(fakeCapture),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('拍完直接自由框选错题'), findsOneWidget);

        await tester.tap(find.text('拍照'));
        await tester.pumpAndSettle();

        expect(find.text('CAMERA_CROP_ROUTE'), findsOneWidget);
        expect(fakeCapture.cameraCalls, 0);
      },
    );

    testWidgets(
      'tapping 相册 picks from gallery and navigates to /capture/crop',
      (tester) async {
        final draft = QuestionRecord.draft(
          id: 'q-gallery-1',
          imagePath: '/tmp/gallery.jpg',
          subject: Subject.unknown,
          recognizedText: '',
        );
        final fakeCapture = _FakeCaptureService(
          galleryResult: CaptureResult.success(draft),
        );
        final router = GoRouter(
          initialLocation: '/',
          routes: <RouteBase>[
            GoRoute(
              path: '/',
              builder: (_, __) => const Scaffold(body: CaptureEntrySheet()),
            ),
            GoRoute(
              path: '/capture/crop',
              builder: (_, __) => const Scaffold(body: Text('CROP_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              settingsRepositoryProvider
                  .overrideWithValue(_ConfiguredSettingsRepository()),
              captureServiceProvider.overrideWithValue(fakeCapture),
            ],
            child: Consumer(
              builder: (context, ref, _) {
                container = ProviderScope.containerOf(context);
                return MaterialApp.router(routerConfig: router);
              },
            ),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('相册'));
        await tester.pumpAndSettle();

        expect(find.text('CROP_ROUTE'), findsOneWidget);
        expect(fakeCapture.galleryCalls, 1);
        expect(container.read(currentQuestionProvider)?.id, 'q-gallery-1');
      },
    );
  });

  group('Direct capture entry & 100%-width 4:1 viewfinder guide', () {
    test('computeViewfinderGuideRect spans 100% width with 4:1 aspect ratio',
        () {
      const phoneViewport = Size(412, 700);
      final guide = computeViewfinderGuideRect(phoneViewport);

      expect(guide.left, 0);
      expect(guide.width, phoneViewport.width);
      expect(guide.width / guide.height, closeTo(4.0, 1e-6));
      expect(guide.center.dy, closeTo(phoneViewport.height / 2, 1e-6));
    });

    test('computeWidthFilledImageRect fills 100% width and centers vertically',
        () {
      const viewport = Size(412, 650);
      final tallRect = computeWidthFilledImageRect(
        viewportSize: viewport,
        imageSize: const Size(1080, 1920),
      );
      expect(tallRect.left, 0);
      expect(tallRect.width, closeTo(412.0, 1e-6));
      expect(tallRect.height, closeTo(412.0 * 16 / 9, 1e-4));
      expect(tallRect.center.dy, closeTo(viewport.height / 2, 1e-6));
      expect(tallRect.top, lessThan(0));
      expect(tallRect.bottom, greaterThan(viewport.height));

      final visibleBounds = computeVisibleNormalizedBounds(
        displayRect: tallRect,
        viewportSize: viewport,
        verticalInset: 10.0,
      );
      expect(visibleBounds.left, 0.0);
      expect(visibleBounds.right, 1.0);
      expect(visibleBounds.top, greaterThan(0.0));
      expect(visibleBounds.bottom, lessThan(1.0));
      final screenBounds = normalizedToDisplayRect(visibleBounds, tallRect);
      expect(screenBounds.top, closeTo(10.0, 1e-4));
      expect(screenBounds.bottom, closeTo(viewport.height - 10.0, 1e-4));
    });

    test(
        'computeAimedCropRect maps live 4:1 guide directly into photo coordinates',
        () {
      const previewViewport = Size(412, 700);
      const capturedImage = Size(1080, 1920);
      final aimed = computeAimedCropRect(
        previewViewportSize: previewViewport,
        capturedImageSize: capturedImage,
      );

      expect(aimed.left, 0.0);
      expect(aimed.right, 1.0);
      expect(aimed.center.dy, closeTo(0.5, 1e-6));
      final pixelW = aimed.width * capturedImage.width;
      final pixelH = aimed.height * capturedImage.height;
      expect(pixelW / pixelH, closeTo(4.0, 1e-4));

      // Projecting back onto a slightly shorter crop viewport preserves the
      // exact 4:1 box centered on the same question.
      final cropDisplay = computeWidthFilledImageRect(
        viewportSize: const Size(412, 640),
        imageSize: capturedImage,
      );
      final screenCrop = normalizedToDisplayRect(aimed, cropDisplay);
      expect(screenCrop.left, closeTo(0.0, 1e-4));
      expect(screenCrop.width, closeTo(412.0, 1e-4));
      expect(screenCrop.width / screenCrop.height, closeTo(4.0, 1e-4));
      expect(screenCrop.center.dy, closeTo(320.0, 1e-4));
    });

    testWidgets('live camera preview surface fills 100% viewport width',
        (tester) async {
      final session = _FakeCameraCaptureSession();

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            cameraCaptureSessionFactoryProvider
                .overrideWithValue(() => session),
          ],
          child: const MaterialApp(home: CameraCaptureCropScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final scaffoldRect = tester.getRect(find.byType(Scaffold));
      final surfaceRect =
          tester.getRect(find.byKey(const Key('camera-preview-surface')));
      final previewRect =
          tester.getRect(find.byKey(const Key('fake-camera-preview')));

      expect(surfaceRect.left, closeTo(0.0, 0.5));
      expect(surfaceRect.width, closeTo(scaffoldRect.width, 0.5));
      expect(previewRect.width, closeTo(scaffoldRect.width, 0.5));
    });

    testWidgets(
      'tapping 拍照录题 on HomeScreen opens /capture/camera directly without bottom sheet',
      (tester) async {
        final router = GoRouter(
          initialLocation: '/',
          routes: <RouteBase>[
            GoRoute(
              path: '/',
              builder: (_, __) => const Scaffold(body: HomeScreen()),
            ),
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) =>
                  const Scaffold(body: Text('DIRECT_CAMERA_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              questionRepositoryProvider
                  .overrideWithValue(InMemoryQuestionRepository()),
              settingsRepositoryProvider
                  .overrideWithValue(_ConfiguredSettingsRepository()),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('拍照录题'));
        await tester.pumpAndSettle();

        expect(find.byType(CaptureEntrySheet), findsNothing);
        expect(find.text('DIRECT_CAMERA_ROUTE'), findsOneWidget);
      },
    );

    testWidgets(
      'tapping camera button on NotebookScreen opens /capture/camera directly without bottom sheet',
      (tester) async {
        final router = GoRouter(
          initialLocation: '/notebook',
          routes: <RouteBase>[
            GoRoute(
              path: '/notebook',
              builder: (_, __) => const NotebookScreen(),
            ),
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) =>
                  const Scaffold(body: Text('DIRECT_CAMERA_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              questionRepositoryProvider
                  .overrideWithValue(InMemoryQuestionRepository()),
              settingsRepositoryProvider
                  .overrideWithValue(_ConfiguredSettingsRepository()),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('添加错题'));
        await tester.pumpAndSettle();

        expect(find.byType(CaptureEntrySheet), findsNothing);
        expect(find.text('DIRECT_CAMERA_ROUTE'), findsOneWidget);
      },
    );

    testWidgets(
      'crop screen lets user straighten photo angle with slider, reset via badge, and export rotated image',
      (tester) async {
        final tempDir =
            Directory.systemTemp.createTempSync('camera_angle_test_');
        final storage = _TempImageStorageService(tempDir);
        final session = _FakeCameraCaptureSession(
          photoFactory: () => _createThreeBandWorksheetPng(
            tempDir,
            name: 'angle_shot.png',
            width: 300,
            height: 300,
          ),
        );

        final router = GoRouter(
          initialLocation: '/capture/camera',
          routes: <RouteBase>[
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) => const CameraCaptureCropScreen(),
            ),
            GoRoute(
              path: '/analysis/loading',
              builder: (_, __) => const Scaffold(body: Text('LOADING_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                cameraCaptureSessionFactoryProvider
                    .overrideWithValue(() => session),
                imageStorageServiceProvider.overrideWithValue(storage),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('camera-shutter-button')));
          await tester.pump();
          await _pumpUntilFound(tester, find.byKey(const Key('crop-canvas')));
          await tester.pumpAndSettle();

          expect(find.byKey(const Key('crop-angle-slider')), findsOneWidget);
          expect(find.text('0°'), findsOneWidget);

          // Drag the angle slider right to tilt clockwise.
          await tester.drag(
            find.byKey(const Key('crop-angle-slider')),
            const Offset(80, 0),
          );
          await tester.pumpAndSettle();
          expect(find.text('0°'), findsNothing);

          // Tapping the angle badge resets angle cleanly back to 0°.
          await tester.tap(find.byKey(const Key('crop-angle-reset')));
          await tester.pumpAndSettle();
          expect(find.text('0°'), findsOneWidget);

          // Tilt again and confirm without moving crop box handles -> must
          // still re-encode (not take unmodified-original fast path).
          await tester.drag(
            find.byKey(const Key('crop-angle-slider')),
            const Offset(90, 0),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('crop-confirm')));
          await tester.pump();
          await _pumpUntilFound(tester, find.text('LOADING_ROUTE'));
          await tester.pumpAndSettle();

          expect(storage.lastSavedPath, isNotNull);
          final savedBytes = File(storage.lastSavedPath!).readAsBytesSync();
          // Encoded as JPEG (whereas raw capture was PNG), proving fine
          // rotation bypassed the unmodified-original fast path!
          expect(savedBytes.sublist(0, 3), <int>[0xFF, 0xD8, 0xFF]);
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'post-shutter crop supports two-finger pinch zoom-in & pan and crops the zoomed sub-region accurately',
      (tester) async {
        tester.view.physicalSize = const Size(412, 892);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tempDir =
            Directory.systemTemp.createTempSync('camera_pinch_zoom_in_');
        final storage = _TempImageStorageService(tempDir);

        // Create a 360x640 image with a small bright yellow target patch
        // centered at (x: 270 [75%], y: 320 [50%]) and dark blue elsewhere.
        File createTargetPatchPng() {
          final canvas = img.Image(width: 360, height: 640);
          for (var y = 0; y < 640; y++) {
            for (var x = 0; x < 360; x++) {
              final inYellowPatch =
                  x >= 210 && x <= 330 && y >= 290 && y <= 350;
              if (inYellowPatch) {
                canvas.setPixelRgb(x, y, 240, 220, 20);
              } else {
                canvas.setPixelRgb(x, y, 20, 30, 200);
              }
            }
          }
          final file = File('${tempDir.path}/zoom_target.png');
          file.writeAsBytesSync(img.encodePng(canvas));
          return file;
        }

        final session = _FakeCameraCaptureSession(
          photoFactory: createTargetPatchPng,
        );
        final router = GoRouter(
          initialLocation: '/capture/camera',
          routes: <RouteBase>[
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) => const CameraCaptureCropScreen(),
            ),
            GoRoute(
              path: '/analysis/loading',
              builder: (_, __) => const Scaffold(body: Text('LOADING_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                cameraCaptureSessionFactoryProvider
                    .overrideWithValue(() => session),
                imageStorageServiceProvider.overrideWithValue(storage),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('camera-shutter-button')));
          await tester.pump();
          await _pumpUntilFound(tester, find.byKey(const Key('crop-canvas')));
          await tester.pumpAndSettle();

          final canvasRect =
              tester.getRect(find.byKey(const Key('crop-canvas')));
          final initialImageRect = tester.getRect(find.byType(RawImage));
          expect(initialImageRect.width, closeTo(412.0, 0.5));
          expect(find.byKey(const Key('crop-zoom-reset')), findsNothing);

          // Two-finger spread around the right-side yellow patch while shifting
          // focal point toward canvas center (~2.5x zoom + pan left).
          final startFocal = Offset(
            canvasRect.left + canvasRect.width * 0.75,
            canvasRect.center.dy,
          );
          final endFocal = canvasRect.center;

          final g1 = await tester.createGesture();
          final g2 = await tester.createGesture();
          await g1.down(startFocal + const Offset(-30, 0));
          await g2.down(startFocal + const Offset(30, 0));
          await tester.pump();

          for (var step = 1; step <= 10; step++) {
            final t = step / 10.0;
            final focal = Offset.lerp(startFocal, endFocal, t)!;
            final halfSpan = 30.0 + 45.0 * t; // 60px -> 150px (2.5x)
            await g1.moveTo(focal + Offset(-halfSpan, 0));
            await g2.moveTo(focal + Offset(halfSpan, 0));
            await tester.pump(const Duration(milliseconds: 16));
          }
          // Lift one finger slightly before the other to verify trailing finger
          // does NOT yank crop handles.
          await g1.up();
          await tester.pump(const Duration(milliseconds: 16));
          await g2.moveBy(const Offset(2, 0));
          await tester.pump(const Duration(milliseconds: 16));
          await g2.up();
          await tester.pumpAndSettle();

          final zoomedImageRect = tester.getRect(find.byType(RawImage));
          expect(zoomedImageRect.width, greaterThan(412.0 * 2.0));
          expect(find.byKey(const Key('crop-zoom-reset')), findsOneWidget);

          await tester.tap(find.byKey(const Key('crop-confirm')));
          await tester.pump();
          await _pumpUntilFound(tester, find.text('LOADING_ROUTE'));
          await tester.pumpAndSettle();

          expect(storage.lastSavedPath, isNotNull);
          final cropped =
              img.decodeJpg(File(storage.lastSavedPath!).readAsBytesSync())!;
          // Zoomed 2.5x crop must be a zoomed sub-width (< 200px vs 360px full)
          // centered on the yellow target patch!
          expect(cropped.width, lessThan(200));
          final centerPixel = cropped.getPixel(
            cropped.width ~/ 2,
            cropped.height ~/ 2,
          );
          expect(centerPixel.r, greaterThan(180));
          expect(centerPixel.g, greaterThan(170));
          expect(centerPixel.b, lessThan(80));
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'post-shutter crop supports two-finger pinch zoom-out and restoring 1x via zoom pill or reset button',
      (tester) async {
        tester.view.physicalSize = const Size(412, 892);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tempDir =
            Directory.systemTemp.createTempSync('camera_pinch_zoom_out_');
        final session = _FakeCameraCaptureSession(
          photoFactory: () => _createThreeBandWorksheetPng(
            tempDir,
            name: 'zoom_out.png',
            width: 360,
            height: 640,
          ),
        );

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                cameraCaptureSessionFactoryProvider
                    .overrideWithValue(() => session),
              ],
              child: const MaterialApp(home: CameraCaptureCropScreen()),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('camera-shutter-button')));
          await tester.pump();
          await _pumpUntilFound(tester, find.byKey(const Key('crop-canvas')));
          await tester.pumpAndSettle();

          final center = tester.getCenter(find.byKey(const Key('crop-canvas')));

          // Pinch IN (220px span -> 90px span) to shrink the frozen image.
          final g1 = await tester.createGesture();
          final g2 = await tester.createGesture();
          await g1.down(center + const Offset(-110, 0));
          await g2.down(center + const Offset(110, 0));
          await tester.pump();
          for (var step = 1; step <= 10; step++) {
            final halfSpan = 110.0 - 6.5 * step; // 110 -> 45
            await g1.moveTo(center + Offset(-halfSpan, 0));
            await g2.moveTo(center + Offset(halfSpan, 0));
            await tester.pump(const Duration(milliseconds: 16));
          }
          await g1.up();
          await g2.up();
          await tester.pumpAndSettle();

          final shrunkRect = tester.getRect(find.byType(RawImage));
          expect(shrunkRect.width, lessThan(412.0 * 0.75));
          expect(find.byKey(const Key('crop-zoom-reset')), findsOneWidget);

          // Tap the floating zoom pill -> restores 100% 1.0x width immediately.
          await tester.tap(find.byKey(const Key('crop-zoom-reset')));
          await tester.pumpAndSettle();

          final restoredRect = tester.getRect(find.byType(RawImage));
          expect(restoredRect.width, closeTo(412.0, 0.5));
          expect(find.byKey(const Key('crop-zoom-reset')), findsNothing);

          // Zoom IN again, then tap toolbar 重置 -> also resets zoom to 1.0x.
          final z1 = await tester.createGesture();
          final z2 = await tester.createGesture();
          await z1.down(center + const Offset(-40, 0));
          await z2.down(center + const Offset(40, 0));
          await tester.pump();
          for (var step = 1; step <= 8; step++) {
            final halfSpan = 40.0 + 8.0 * step;
            await z1.moveTo(center + Offset(-halfSpan, 0));
            await z2.moveTo(center + Offset(halfSpan, 0));
            await tester.pump(const Duration(milliseconds: 16));
          }
          await z1.up();
          await z2.up();
          await tester.pumpAndSettle();
          expect(tester.getRect(find.byType(RawImage)).width, greaterThan(600));

          await tester.tap(find.byKey(const Key('crop-reset')));
          await tester.pumpAndSettle();
          expect(
            tester.getRect(find.byType(RawImage)).width,
            closeTo(412.0, 0.5),
          );
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'pinch zoom-in auto-triggers map-style polygon nodes, supports midpoint vertex insertion & deletion, and exports masked cutout',
      (tester) async {
        tester.view.physicalSize = const Size(412, 892);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tempDir =
            Directory.systemTemp.createTempSync('camera_polygon_crop_');
        final storage = _TempImageStorageService(tempDir);

        // 360x640 sheet: white paper (240, 240, 240), green target question on
        // the right half (x >= 180) and bright red neighboring question on the
        // bottom-left (x < 160, y >= 320).
        File createIrregularSheetPng() {
          final canvas = img.Image(width: 360, height: 640);
          for (var y = 0; y < 640; y++) {
            for (var x = 0; x < 360; x++) {
              if (x >= 190 && x <= 340 && y >= 285 && y <= 360) {
                canvas.setPixelRgb(x, y, 20, 175, 65);
              } else if (x >= 10 && x <= 155 && y >= 322 && y <= 365) {
                canvas.setPixelRgb(x, y, 230, 30, 30);
              } else {
                canvas.setPixelRgb(x, y, 240, 240, 240);
              }
            }
          }
          final file = File('${tempDir.path}/irregular_sheet.png');
          file.writeAsBytesSync(img.encodePng(canvas));
          return file;
        }

        final session = _FakeCameraCaptureSession(
          photoFactory: createIrregularSheetPng,
        );
        final router = GoRouter(
          initialLocation: '/capture/camera',
          routes: <RouteBase>[
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) => const CameraCaptureCropScreen(),
            ),
            GoRoute(
              path: '/analysis/loading',
              builder: (_, __) => const Scaffold(body: Text('LOADING_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                cameraCaptureSessionFactoryProvider
                    .overrideWithValue(() => session),
                imageStorageServiceProvider.overrideWithValue(storage),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('camera-shutter-button')));
          await tester.pump();
          await _pumpUntilFound(tester, find.byKey(const Key('crop-canvas')));
          await tester.pumpAndSettle();

          // At 1.0x default zoom, rectangle mode is active and chip shows '多边形'.
          expect(find.byKey(const Key('crop-polygon-toggle')), findsOneWidget);
          expect(find.text('多边形'), findsOneWidget);
          expect(find.textContaining('多边形 ·'), findsNothing);

          final canvasRect =
              tester.getRect(find.byKey(const Key('crop-canvas')));
          final center = canvasRect.center;

          // Pinch zoom IN (~1.5x) -> automatically triggers map-style 4-vertex polygon!
          final g1 = await tester.createGesture();
          final g2 = await tester.createGesture();
          await g1.down(center + const Offset(-50, 0));
          await g2.down(center + const Offset(50, 0));
          await tester.pump();
          for (var step = 1; step <= 8; step++) {
            final halfSpan = 50.0 + 3.5 * step; // 100px -> 156px (~1.56x)
            await g1.moveTo(center + Offset(-halfSpan, 0));
            await g2.moveTo(center + Offset(halfSpan, 0));
            await tester.pump(const Duration(milliseconds: 16));
          }
          await g1.up();
          await g2.up();
          await tester.pumpAndSettle();

          expect(find.text('多边形 · 4点'), findsOneWidget);

          // Restore to 1.0x and explicitly toggle 多边形 ON so we have exact
          // known 4:1 aimed strip coordinates to sculpt an L-cutout.
          await tester.tap(find.byKey(const Key('crop-zoom-reset')));
          await tester.pumpAndSettle();
          expect(find.text('多边形'), findsOneWidget);

          await tester.tap(find.byKey(const Key('crop-polygon-toggle')));
          await tester.pumpAndSettle();
          expect(find.text('多边形 · 4点'), findsOneWidget);

          // Aimed 4:1 strip on 412w canvas is centered at canvasRect.center
          // with width = 412, height = 103 (top = center.dy - 51.5, bottom = center.dy + 51.5).
          final stripBottomY = center.dy + 412.0 / 8.0;

          // 1. Drag bottom-edge midpoint (+) upward by 42px to insert a 5th vertex!
          final bottomMidGlobal = Offset(center.dx, stripBottomY);
          await tester.dragFrom(bottomMidGlobal, const Offset(0, -42));
          await tester.pumpAndSettle();
          expect(find.text('多边形 · 5点'), findsOneWidget);
          expect(
            find.byKey(const Key('crop-polygon-delete-vertex')),
            findsOneWidget,
          );

          // 2. Also drag top-edge midpoint (+) slightly, then delete it via '删节点'
          // to verify vertex deletion works cleanly!
          final stripTopY = center.dy - 412.0 / 8.0;
          await tester.dragFrom(
            Offset(center.dx, stripTopY),
            const Offset(0, 12),
          );
          await tester.pumpAndSettle();
          expect(find.text('多边形 · 6点'), findsOneWidget);

          await tester.tap(
            find.byKey(const Key('crop-polygon-delete-vertex')),
          );
          await tester.pumpAndSettle();
          expect(find.text('多边形 · 5点'), findsOneWidget);

          // 3. Pull bottom-left corner vertex (x = canvasRect.left + 4, y = stripBottomY)
          // upward by 46px so the entire bottom-left red neighboring question is
          // outside the polygon while the right-side green target stays inside!
          await tester.dragFrom(
            Offset(canvasRect.left + 6, stripBottomY - 2),
            const Offset(0, -46),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('crop-confirm')));
          await tester.pump();
          await _pumpUntilFound(tester, find.text('LOADING_ROUTE'));
          await tester.pumpAndSettle();

          expect(storage.lastSavedPath, isNotNull);
          final outJpg =
              img.decodeJpg(File(storage.lastSavedPath!).readAsBytesSync())!;

          // Right-side green target question is preserved inside the polygon:
          final rightPx = outJpg.getPixel(
            (outJpg.width * 0.75).round(),
            (outJpg.height * 0.60).round(),
          );
          expect(rightPx.g, greaterThan(140));
          expect(rightPx.r, lessThan(70));

          // Bottom-left red distracting question (outside polygon) is masked
          // cleanly to light paper white (~240, 240, 240), NOT red!
          final maskedLeftPx = outJpg.getPixel(
            (outJpg.width * 0.20).round(),
            (outJpg.height * 0.85).round(),
          );
          expect(maskedLeftPx.r, greaterThan(220));
          expect(maskedLeftPx.g, greaterThan(220));
          expect(maskedLeftPx.b, greaterThan(220));
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'zoomed polygon keeps left vertices anchored while panning view and auto-pans when dragging vertex to screen edge',
      (tester) async {
        tester.view.physicalSize = const Size(412, 892);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final tempDir =
            Directory.systemTemp.createTempSync('camera_polygon_autopan_');
        final storage = _TempImageStorageService(tempDir);

        // 360x640 sheet:
        // - Left blue question marker at x: 25..90 (~15%), y: 295..345 (mid)
        // - Far-right green diagram marker at x: 290..350 (~90%), y: 295..345 (mid)
        File createWideSpanSheetPng() {
          final canvas = img.Image(width: 360, height: 640);
          for (var y = 0; y < 640; y++) {
            for (var x = 0; x < 360; x++) {
              if (x >= 25 && x <= 90 && y >= 295 && y <= 345) {
                canvas.setPixelRgb(x, y, 25, 65, 225);
              } else if (x >= 290 && x <= 350 && y >= 295 && y <= 345) {
                canvas.setPixelRgb(x, y, 20, 185, 60);
              } else {
                canvas.setPixelRgb(x, y, 240, 240, 240);
              }
            }
          }
          final file = File('${tempDir.path}/wide_span.png');
          file.writeAsBytesSync(img.encodePng(canvas));
          return file;
        }

        final session = _FakeCameraCaptureSession(
          photoFactory: createWideSpanSheetPng,
        );
        final router = GoRouter(
          initialLocation: '/capture/camera',
          routes: <RouteBase>[
            GoRoute(
              path: '/capture/camera',
              builder: (_, __) => const CameraCaptureCropScreen(),
            ),
            GoRoute(
              path: '/analysis/loading',
              builder: (_, __) => const Scaffold(body: Text('LOADING_ROUTE')),
            ),
          ],
        );
        addTearDown(router.dispose);

        try {
          await tester.pumpWidget(
            ProviderScope(
              overrides: <Override>[
                cameraCaptureSessionFactoryProvider
                    .overrideWithValue(() => session),
                imageStorageServiceProvider.overrideWithValue(storage),
              ],
              child: MaterialApp.router(routerConfig: router),
            ),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('camera-shutter-button')));
          await tester.pump();
          await _pumpUntilFound(tester, find.byKey(const Key('crop-canvas')));
          await tester.pumpAndSettle();

          final canvasRect =
              tester.getRect(find.byKey(const Key('crop-canvas')));

          // 1. Pinch zoom IN (~2.4x) anchored on the LEFT side of the sheet
          // so only the left ~42% of the sheet is visible on screen!
          final leftFocal = Offset(canvasRect.left + 60, canvasRect.center.dy);
          final g1 = await tester.createGesture();
          final g2 = await tester.createGesture();
          await g1.down(leftFocal + const Offset(-35, 0));
          await g2.down(leftFocal + const Offset(35, 0));
          await tester.pump();
          for (var step = 1; step <= 10; step++) {
            final halfSpan = 35.0 + 5.0 * step; // 70px -> 170px (~2.4x)
            await g1.moveTo(leftFocal + Offset(-halfSpan, 0));
            await g2.moveTo(leftFocal + Offset(halfSpan, 0));
            await tester.pump(const Duration(milliseconds: 16));
          }
          await g1.up();
          await g2.up();
          await tester.pumpAndSettle();

          expect(find.text('多边形 · 4点'), findsOneWidget);
          final imageRectBeforePan = tester.getRect(find.byType(RawImage));
          expect(imageRectBeforePan.width, greaterThan(900));

          // 2. Nudge top-left vertex slightly inward to lock custom polygon on
          // the left blue marker.
          final stripTopY = canvasRect.center.dy - 412.0 / 8.0;
          final stripBottomY = canvasRect.center.dy + 412.0 / 8.0;
          await tester.dragFrom(
            Offset(canvasRect.left + 8, stripTopY),
            const Offset(18, 0),
          );
          await tester.pumpAndSettle();

          // 3. Single-finger drag on empty space (above polygon) to pan view
          // partway right — image shifts left while left vertices stay anchored!
          await tester.dragFrom(
            Offset(canvasRect.center.dx, canvasRect.top + 110),
            const Offset(-160, 0),
          );
          await tester.pumpAndSettle();
          final imageRectAfterManualPan = tester.getRect(find.byType(RawImage));
          expect(
            imageRectAfterManualPan.left,
            lessThan(imageRectBeforePan.left - 120),
          );

          // 4. Grab the top-right vertex (previously at canvasRect.right, now
          // shifted left by ~160px to ~canvasRect.right - 160) and drag it to
          // the right edge of the screen (`canvasRect.right - 8`), holding for
          // 40 frames so Edge Auto-Pan scrolls all the way to the far-right
          // green marker!
          final shiftedRightX = canvasRect.right - 160;
          final vDrag = await tester.startGesture(
            Offset(shiftedRightX, stripTopY),
          );
          await tester.pump(const Duration(milliseconds: 16));
          await vDrag.moveTo(Offset(canvasRect.right - 8, stripTopY));
          for (var tick = 0; tick < 45; tick++) {
            await tester.pump(const Duration(milliseconds: 16));
          }
          await vDrag.up();
          await tester.pumpAndSettle();

          // Image automatically scrolled all the way to the right edge!
          final imageRectAfterAutoPan = tester.getRect(find.byType(RawImage));
          expect(
            imageRectAfterAutoPan.left,
            lessThan(imageRectAfterManualPan.left - 200),
          );

          // Also pull bottom-right vertex (shifted left by total pan) across to
          // the right edge so the full height of the green diagram is enclosed.
          final totalShiftLeft =
              imageRectBeforePan.left - imageRectAfterAutoPan.left;
          final bottomRightScreenX = canvasRect.right - totalShiftLeft;
          // Pan back slightly if bottomRightScreenX scrolled off-screen left,
          // OR use visible bottom edge midpoint (+) right on screen!
          // Look how convenient visible-segment midpoint (+) is: the bottom
          // edge passes across the screen, or let's zoom out via '还原' to see
          // all 4 vertices and pull bottom-right to the right!
          await tester.tap(find.byKey(const Key('crop-zoom-reset')));
          await tester.pumpAndSettle();
          // Sculpted polygon is preserved even after zooming back to 1.0x!
          expect(find.text('多边形 · 4点'), findsOneWidget);
          expect(bottomRightScreenX, isNotNull);

          final imageRect1x = tester.getRect(find.byType(RawImage));
          final brU = (canvasRect.right - imageRectBeforePan.left) /
              imageRectBeforePan.width;
          final brV = (stripBottomY - imageRectBeforePan.top) /
              imageRectBeforePan.height;
          final brGlobal1x = Offset(
            imageRect1x.left + brU * imageRect1x.width,
            imageRect1x.top + brV * imageRect1x.height,
          );
          await tester.dragFrom(
            brGlobal1x,
            Offset(canvasRect.right - 10 - brGlobal1x.dx, 0),
          );
          await tester.pumpAndSettle();

          await tester.tap(find.byKey(const Key('crop-confirm')));
          await tester.pump();
          await _pumpUntilFound(tester, find.text('LOADING_ROUTE'));
          await tester.pumpAndSettle();

          expect(storage.lastSavedPath, isNotNull);
          final outJpg =
              img.decodeJpg(File(storage.lastSavedPath!).readAsBytesSync())!;
          expect(outJpg.width, greaterThan(300)); // spans left -> far-right!

          final leftPx = outJpg.getPixel(40, outJpg.height ~/ 2);
          expect(leftPx.b, greaterThan(170));
          expect(leftPx.r, lessThan(80));

          final rightPx =
              outJpg.getPixel(outJpg.width - 35, outJpg.height ~/ 2);
          expect(rightPx.g, greaterThan(140));
          expect(rightPx.r, lessThan(80));
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );
  });
}
