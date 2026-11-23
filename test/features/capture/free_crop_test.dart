import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:image/image.dart' as img;
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/data/files/image_storage_service.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/image_crop_processor.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/image_crop_screen.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/widgets/crop_angle_control.dart';

class _TempImageStorageService extends ImageStorageService {
  _TempImageStorageService(this.outputDir);

  final Directory outputDir;
  String? lastSavedPath;

  @override
  Future<String> saveImage(File source) async {
    final targetPath =
        '${outputDir.path}/saved_${DateTime.now().microsecondsSinceEpoch}.jpg';
    await source.copy(targetPath);
    lastSavedPath = targetPath;
    return targetPath;
  }
}

/// Creates a synthetic 3-band portrait worksheet image:
/// - Top 40%: red (question above)
/// - Middle 20%: green (target single horizontal question)
/// - Bottom 40%: blue (question below)
File _createThreeBandWorksheetPng(Directory dir,
    {int width = 300, int height = 600}) {
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
  final file = File('${dir.path}/worksheet.png');
  file.writeAsBytesSync(img.encodePng(canvas));
  return file;
}

void main() {
  group('free_crop_geometry', () {
    const displayRect = Rect.fromLTWH(20, 20, 300, 600);

    test('top and bottom edges resize height freely into a wide thin strip',
        () {
      var crop = fullNormalizedCropRect;

      // Drag top edge down 40% (240px on a 600px tall portrait page).
      crop = applyCropHandleDelta(
        normalizedRect: crop,
        handle: CropHandle.top,
        delta: const Offset(0, 240),
        displayRect: displayRect,
      );
      // Drag bottom edge up 50% (300px).
      crop = applyCropHandleDelta(
        normalizedRect: crop,
        handle: CropHandle.bottom,
        delta: const Offset(0, -300),
        displayRect: displayRect,
      );

      expect(crop.left, closeTo(0.0, 1e-6));
      expect(crop.right, closeTo(1.0, 1e-6));
      expect(crop.top, closeTo(0.4, 1e-6));
      expect(crop.bottom, closeTo(0.5, 1e-6));

      // Resulting strip is 300px wide by 60px tall (5:1 aspect ratio) on a 1:2 photo!
      final screen = normalizedToDisplayRect(crop, displayRect);
      expect(screen.width, closeTo(300, 1e-3));
      expect(screen.height, closeTo(60, 1e-3));
    });

    test('left and right edges resize width freely into a tall narrow column',
        () {
      var crop = fullNormalizedCropRect;

      crop = applyCropHandleDelta(
        normalizedRect: crop,
        handle: CropHandle.left,
        delta: const Offset(120, 0),
        displayRect: displayRect,
      );
      crop = applyCropHandleDelta(
        normalizedRect: crop,
        handle: CropHandle.right,
        delta: const Offset(-120, 0),
        displayRect: displayRect,
      );

      final screen = normalizedToDisplayRect(crop, displayRect);
      expect(screen.width, closeTo(60, 1e-3));
      expect(screen.height, closeTo(600, 1e-3));
    });

    test('corner dragging adjusts width and height independently without ratio lock',
        () {
      final crop = applyCropHandleDelta(
        normalizedRect: fullNormalizedCropRect,
        handle: CropHandle.bottomRight,
        delta: const Offset(-10, -450),
        displayRect: displayRect,
      );

      final screen = normalizedToDisplayRect(crop, displayRect);
      expect(screen.width, closeTo(290, 1e-3));
      expect(screen.height, closeTo(150, 1e-3));
    });

    test('move handle shifts crop box without altering dimensions', () {
      const initial = Rect.fromLTRB(0.1, 0.4, 0.9, 0.55);
      final moved = applyCropHandleDelta(
        normalizedRect: initial,
        handle: CropHandle.move,
        delta: const Offset(60, -120),
        displayRect: displayRect,
      );

      expect(moved.width, closeTo(initial.width, 1e-6));
      expect(moved.height, closeTo(initial.height, 1e-6));
      expect(moved.right, closeTo(1.0, 1e-6));
      expect(moved.top, closeTo(0.2, 1e-6));
    });

    test('hitTestCropHandle distinguishes top vs bottom edge on a thin 36px strip',
        () {
      const thinStrip = Rect.fromLTWH(20, 260, 300, 36);

      expect(
        hitTestCropHandle(
          position: const Offset(170, 256),
          screenCropRect: thinStrip,
        ),
        CropHandle.top,
      );
      expect(
        hitTestCropHandle(
          position: const Offset(170, 300),
          screenCropRect: thinStrip,
        ),
        CropHandle.bottom,
      );
      expect(
        hitTestCropHandle(
          position: const Offset(20, 260),
          screenCropRect: thinStrip,
        ),
        CropHandle.topLeft,
      );
      expect(
        hitTestCropHandle(
          position: const Offset(20, 296),
          screenCropRect: thinStrip,
        ),
        CropHandle.bottomLeft,
      );
    });

    test('rotateNormalizedCropRect rotates clockwise and counter-clockwise inversely',
        () {
      const original = Rect.fromLTRB(0.1, 0.2, 0.6, 0.5);
      final cw = rotateNormalizedCropRect(original, clockwise: true);
      final restored = rotateNormalizedCropRect(cw, clockwise: false);

      expect(restored.left, closeTo(original.left, 1e-6));
      expect(restored.top, closeTo(original.top, 1e-6));
      expect(restored.right, closeTo(original.right, 1e-6));
      expect(restored.bottom, closeTo(original.bottom, 1e-6));
    });

    test('computeOutputCropSpec preserves extreme free-form aspect ratios', () {
      final spec = computeOutputCropSpec(
        sourceWidth: 1000,
        sourceHeight: 2000,
        quarterTurns: 0,
        normalizedCropRect: const Rect.fromLTRB(0.0, 0.4, 1.0, 0.45),
      );

      expect(spec.cropWidth, 1000);
      expect(spec.cropHeight, 100);
      expect(spec.outputWidth, 1000);
      expect(spec.outputHeight, 100);
    });
  });

  group('image_crop_processor', () {
    test('crops a wide thin middle question strip without aspect ratio clamping',
        () async {
      final tempDir =
          Directory.systemTemp.createTempSync('free_crop_processor_');
      try {
        final file =
            _createThreeBandWorksheetPng(tempDir, width: 400, height: 600);
        final decoded = await decodeImageForCrop(file);
        try {
          // Select ONLY the thin green horizontal strip: 400 x 60 (6.67:1 ratio).
          final jpgBytes = await cropAndEncodeJpg(
            sourceImage: decoded,
            quarterTurns: 0,
            normalizedCropRect: const Rect.fromLTRB(0.0, 0.45, 1.0, 0.55),
          );

          // Valid JPEG magic bytes.
          expect(jpgBytes.sublist(0, 3), <int>[0xFF, 0xD8, 0xFF]);

          final out = img.decodeJpg(jpgBytes)!;
          expect(out.width, 400);
          expect(out.height, 60);

          final center = out.getPixel(out.width ~/ 2, out.height ~/ 2);
          expect(center.g, greaterThan(170));
          expect(center.r, lessThan(60));
          expect(center.b, lessThan(60));
        } finally {
          decoded.dispose();
        }
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('rotates 90 degrees clockwise and crops accurately', () async {
      final tempDir =
          Directory.systemTemp.createTempSync('free_crop_rotate_');
      try {
        final file =
            _createThreeBandWorksheetPng(tempDir, width: 200, height: 400);
        final decoded = await decodeImageForCrop(file);
        try {
          // Original top 40% is red; after 90° CW rotation, top becomes the
          // right 40% of the rotated 400x200 image.
          final jpgBytes = await cropAndEncodeJpg(
            sourceImage: decoded,
            quarterTurns: 1,
            normalizedCropRect: const Rect.fromLTRB(0.7, 0.0, 0.95, 1.0),
          );

          final out = img.decodeJpg(jpgBytes)!;
          expect(out.width, 100);
          expect(out.height, 200);

          final center = out.getPixel(out.width ~/ 2, out.height ~/ 2);
          expect(center.r, greaterThan(170));
          expect(center.g, lessThan(60));
          expect(center.b, lessThan(60));
        } finally {
          decoded.dispose();
        }
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('straightens a -25 degree tilted question bar accurately with fineRotationDegrees',
        () async {
      final tempDir =
          Directory.systemTemp.createTempSync('free_crop_fine_angle_');
      try {
        // Draw a 300x300 white canvas with a green stripe tilted -25° CCW
        // through the center (150, 150). Rotating +25° CW must level it
        // horizontally across the middle crop strip.
        const size = 300;
        final canvas = img.Image(width: size, height: size);
        final slope = math.tan(-25 * math.pi / 180);
        for (var y = 0; y < size; y++) {
          for (var x = 0; x < size; x++) {
            final expectedY = 150 + (x - 150) * slope;
            if ((y - expectedY).abs() <= 14) {
              canvas.setPixelRgb(x, y, 20, 210, 20);
            } else {
              canvas.setPixelRgb(x, y, 245, 245, 245);
            }
          }
        }
        final file = File('${tempDir.path}/tilted.png');
        file.writeAsBytesSync(img.encodePng(canvas));

        final decoded = await decodeImageForCrop(file);
        try {
          final jpgBytes = await cropAndEncodeJpg(
            sourceImage: decoded,
            quarterTurns: 0,
            fineRotationDegrees: 25.0,
            normalizedCropRect: const Rect.fromLTRB(0.25, 0.46, 0.75, 0.54),
          );
          final out = img.decodeJpg(jpgBytes)!;
          final midY = out.height ~/ 2;
          for (final frac in <double>[0.15, 0.50, 0.85]) {
            final p = out.getPixel((out.width * frac).round(), midY);
            expect(p.g, greaterThan(170));
            expect(p.r, lessThan(60));
            expect(p.b, lessThan(60));
          }
        } finally {
          decoded.dispose();
        }
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });

  group('CropAngleControl helpers', () {
    test('snaps near zero and rounds to 0.5 degree increments within [-45, 45]',
        () {
      expect(CropAngleControl.snapAngle(0.4), 0.0);
      expect(CropAngleControl.snapAngle(-0.7), 0.0);
      expect(CropAngleControl.snapAngle(3.26), 3.5);
      expect(CropAngleControl.snapAngle(-12.1), -12.0);
      expect(CropAngleControl.snapAngle(60.0), 45.0);
      expect(CropAngleControl.snapAngle(-60.0), -45.0);

      expect(CropAngleControl.formatAngle(0.0), '0°');
      expect(CropAngleControl.formatAngle(5.0), '+5°');
      expect(CropAngleControl.formatAngle(-3.5), '-3.5°');
    });
  });

  group('ImageCropScreen widget', () {
    testWidgets(
        'lets user freely drag top & bottom edges to crop a wide strip and proceed to analysis',
        (tester) async {
      final tempDir = Directory.systemTemp.createTempSync('crop_screen_');
      final storage = _TempImageStorageService(tempDir);
      final sourceFile =
          _createThreeBandWorksheetPng(tempDir, width: 300, height: 600);
      final draft = QuestionRecord.draft(
        id: 'q-crop-1',
        imagePath: sourceFile.path,
        subject: Subject.unknown,
        recognizedText: '',
      );

      final router = GoRouter(
        initialLocation: '/capture/crop',
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (_, __) => const Scaffold(body: Text('HOME_ROUTE')),
          ),
          GoRoute(
            path: '/capture/crop',
            builder: (_, __) => const ImageCropScreen(),
          ),
          GoRoute(
            path: '/analysis/loading',
            builder: (_, __) => const Scaffold(body: Text('LOADING_ROUTE')),
          ),
        ],
      );

      late ProviderContainer container;
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              currentQuestionProvider.overrideWith((ref) => draft),
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
        await tester.pump();
        for (var i = 0;
            i < 60 && find.byKey(const Key('crop-canvas')).evaluate().isEmpty;
            i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('crop-canvas')), findsOneWidget);
        expect(find.textContaining('不限宽高比'), findsOneWidget);

        final canvasRect =
            tester.getRect(find.byKey(const Key('crop-canvas')));
        final fitted = computeFittedImageRect(
          viewportSize: canvasRect.size,
          imageSize: const Size(300, 600),
        );

        // Drag top edge down 42% of fitted image height.
        final topHandleGlobal =
            canvasRect.topLeft + Offset(fitted.center.dx, fitted.top);
        await tester.dragFrom(
          topHandleGlobal,
          Offset(0, fitted.height * 0.42),
        );
        await tester.pump();

        // Drag bottom edge up 42% of fitted image height to isolate the green strip.
        final bottomHandleGlobal =
            canvasRect.topLeft + Offset(fitted.center.dx, fitted.bottom);
        await tester.dragFrom(
          bottomHandleGlobal,
          Offset(0, -fitted.height * 0.42),
        );
        await tester.pump();

        await tester.tap(find.byKey(const Key('crop-confirm')));
        await tester.pump();
        for (var i = 0; i < 120 && storage.lastSavedPath == null; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();

        expect(find.text('LOADING_ROUTE'), findsOneWidget);
        expect(storage.lastSavedPath, isNotNull);

        final savedBytes = File(storage.lastSavedPath!).readAsBytesSync();
        final savedImage = img.decodeJpg(savedBytes)!;
        // Original was 1:2 portrait; cropped single question must be wide horizontal!
        expect(savedImage.width / savedImage.height, greaterThan(2.5));

        final center =
            savedImage.getPixel(savedImage.width ~/ 2, savedImage.height ~/ 2);
        expect(center.g, greaterThan(160));
        expect(center.r, lessThan(70));
        expect(center.b, lessThan(70));

        final updated = container.read(currentQuestionProvider);
        expect(updated?.imagePath, storage.lastSavedPath);
        expect(updated?.contentStatus, ContentStatus.processing);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    testWidgets('canceling crop returns to home without launching analysis',
        (tester) async {
      final tempDir =
          Directory.systemTemp.createTempSync('crop_screen_cancel_');
      final sourceFile =
          _createThreeBandWorksheetPng(tempDir, width: 200, height: 400);
      final draft = QuestionRecord.draft(
        id: 'q-crop-cancel',
        imagePath: sourceFile.path,
        subject: Subject.unknown,
        recognizedText: '',
      );

      final router = GoRouter(
        initialLocation: '/capture/crop',
        routes: <RouteBase>[
          GoRoute(
            path: '/',
            builder: (_, __) => const Scaffold(body: Text('HOME_ROUTE')),
          ),
          GoRoute(
            path: '/capture/crop',
            builder: (_, __) => const ImageCropScreen(),
          ),
          GoRoute(
            path: '/analysis/loading',
            builder: (_, __) => const Scaffold(body: Text('LOADING_ROUTE')),
          ),
        ],
      );

      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: <Override>[
              currentQuestionProvider.overrideWith((ref) => draft),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pump();
        for (var i = 0;
            i < 60 && find.byKey(const Key('crop-canvas')).evaluate().isEmpty;
            i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();

        await tester.tap(find.byKey(const Key('crop-back-button')));
        await tester.pumpAndSettle();

        expect(find.text('HOME_ROUTE'), findsOneWidget);
        expect(find.text('LOADING_ROUTE'), findsNothing);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
