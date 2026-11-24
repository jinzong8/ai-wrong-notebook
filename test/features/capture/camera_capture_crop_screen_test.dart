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
          expect(find.byKey(const Key('camera-preview-surface')), findsOneWidget);
          expect(find.byKey(const Key('camera-shutter-button')), findsOneWidget);
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
            find.text('已按取景范围框选，拖动四边或四角可微调'),
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

          expect(find.byKey(const Key('camera-shutter-button')), findsOneWidget);
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
            find.text('已按取景范围框选，拖动四边或四角可微调'),
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
            Offset(canvasRect.center.dx, canvasRect.center.dy + guideHeight / 2),
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
            Offset(canvasRect.center.dx, canvasRect.center.dy + guideHeight / 2),
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
  });
}
