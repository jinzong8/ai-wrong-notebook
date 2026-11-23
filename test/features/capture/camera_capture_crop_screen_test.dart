import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/data/files/image_storage_service.dart';
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
      aspectRatio: 0.5,
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

/// Creates a synthetic 3-question printed worksheet PNG (white paper, dark
/// text-like strokes in 3 separated blocks; middle question spans y = 41%..57%).
File _createThreeQuestionPrintedWorksheetPng(
  Directory dir, {
  String name = 'printed_worksheet.png',
  int width = 360,
  int height = 480,
}) {
  final canvas = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      canvas.setPixelRgb(x, y, 246, 246, 246);
    }
  }

  void drawLine(int left, int right, int yTop, {int lineH = 11}) {
    for (var x = left; x < right; x++) {
      if ((x - left) % 9 >= 6) continue;
      for (var y = yTop; y < yTop + lineH; y++) {
        canvas.setPixelRgb(x, y, 30, 30, 30);
      }
    }
  }

  // Question 1 (top)
  drawLine(28, 330, 34);
  drawLine(28, 320, 52);
  drawLine(28, 220, 70);

  // Question 2 (middle, straddling y = 240)
  drawLine(28, 330, 200);
  drawLine(28, 324, 218);
  drawLine(28, 316, 236);
  drawLine(28, 260, 254);

  // Question 3 (bottom)
  drawLine(28, 330, 376);
  drawLine(28, 320, 394);
  drawLine(28, 240, 412);

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
      'capturing transitions directly into in-place free crop and crops a thin strip',
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

          // Press shutter -> stays on /capture/camera and immediately freezes into crop canvas.
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
          expect(find.byKey(const Key('camera-shutter-button')), findsNothing);

          // Drag top & bottom edges freely to isolate ONLY the middle green band.
          final canvasRect =
              tester.getRect(find.byKey(const Key('crop-canvas')));
          final fitted = computeFittedImageRect(
            viewportSize: canvasRect.size,
            imageSize: const Size(300, 600),
          );

          await tester.dragFrom(
            canvasRect.topLeft + Offset(fitted.center.dx, fitted.top),
            Offset(0, fitted.height * 0.42),
          );
          await tester.pump();

          await tester.dragFrom(
            canvasRect.topLeft + Offset(fitted.center.dx, fitted.bottom),
            Offset(0, -fitted.height * 0.42),
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

          // Wide thin horizontal strip cropped from a 1:2 portrait shot!
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
      'auto-selects middle question right after shutter and crops it without manual drag',
      (tester) async {
        final tempDir =
            Directory.systemTemp.createTempSync('camera_auto_crop_');
        final storage = _TempImageStorageService(tempDir);
        final session = _FakeCameraCaptureSession(
          photoFactory: () => _createThreeQuestionPrintedWorksheetPng(
            tempDir,
            name: 'worksheet_auto.png',
            width: 360,
            height: 480,
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
          await _pumpUntilFound(
            tester,
            find.text('已自动框选中间题目，拖动四边或四角可微调'),
          );
          await tester.pumpAndSettle();

          expect(
            find.text('已自动框选中间题目，拖动四边或四角可微调'),
            findsOneWidget,
          );
          expect(find.byKey(const Key('crop-auto-select')), findsOneWidget);

          // Confirm directly WITHOUT manually dragging -> should save only the
          // auto-detected middle question strip, NOT the whole 360x480 page!
          await tester.tap(find.byKey(const Key('crop-confirm')));
          await tester.pump();
          await _pumpUntilFound(tester, find.text('LOADING_ROUTE'));
          await tester.pumpAndSettle();

          expect(storage.lastSavedPath, isNotNull);
          final cropped =
              img.decodeJpg(File(storage.lastSavedPath!).readAsBytesSync())!;
          // Middle question spans ~65px + breathing room (~90-140px) out of 480px.
          expect(cropped.height, lessThan(200));
          expect(cropped.height, greaterThan(65));
          expect(cropped.width, greaterThan(280));
        } finally {
          tempDir.deleteSync(recursive: true);
        }
      },
    );

    testWidgets(
      'supports manual adjustment after auto-select, reset to full, and re-snap via 自动',
      (tester) async {
        final tempDir =
            Directory.systemTemp.createTempSync('camera_auto_adjust_');
        final storage = _TempImageStorageService(tempDir);
        final session = _FakeCameraCaptureSession(
          photoFactory: () => _createThreeQuestionPrintedWorksheetPng(
            tempDir,
            name: 'worksheet_adjust.png',
            width: 360,
            height: 480,
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
          await _pumpUntilFound(
            tester,
            find.text('已自动框选中间题目，拖动四边或四角可微调'),
          );
          await tester.pumpAndSettle();

          // Reset clears auto-crop back to full frame; tapping 自动 re-snaps it.
          await tester.tap(find.byKey(const Key('crop-reset')));
          await tester.pumpAndSettle();
          expect(
            find.text('拖动四边或四角自由框选单道题，不限宽高比'),
            findsOneWidget,
          );

          await tester.tap(find.byKey(const Key('crop-auto-select')));
          await tester.pump();
          await _pumpUntilFound(
            tester,
            find.text('已自动框选中间题目，拖动四边或四角可微调'),
          );
          await tester.pumpAndSettle();

          // Manually drag the bottom edge of the auto-selected box downward to
          // expand the selection, proving manual fine-tuning works seamlessly.
          final canvasRect =
              tester.getRect(find.byKey(const Key('crop-canvas')));
          final fitted = computeFittedImageRect(
            viewportSize: canvasRect.size,
            imageSize: const Size(360, 480),
          );
          // Bottom of auto-selected Q2 sits around 58%..62% of fitted height.
          await tester.dragFrom(
            canvasRect.topLeft +
                Offset(fitted.center.dx, fitted.top + fitted.height * 0.60),
            Offset(0, fitted.height * 0.25),
          );
          await tester.pumpAndSettle();

          // Hint transitions out of untouched auto-select state once adjusted.
          expect(
            find.text('拖动四边或四角自由框选单道题，不限宽高比'),
            findsOneWidget,
          );

          await tester.tap(find.byKey(const Key('crop-confirm')));
          await tester.pump();
          await _pumpUntilFound(tester, find.text('LOADING_ROUTE'));
          await tester.pumpAndSettle();

          final cropped =
              img.decodeJpg(File(storage.lastSavedPath!).readAsBytesSync())!;
          // Expanded significantly taller than the untouched auto-detected ~110px strip!
          expect(cropped.height, greaterThan(180));
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
}
