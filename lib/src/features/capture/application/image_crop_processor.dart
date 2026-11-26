import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';

/// Decodes [file] using Flutter's native codec, which automatically applies
/// EXIF orientation metadata across JPEG/PNG/WebP/HEIC camera photos.
Future<ui.Image> decodeImageForCrop(File file) async {
  final bytes = await file.readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    return frame.image;
  } finally {
    codec.dispose();
  }
}

/// Crops and optionally rotates [sourceImage] to [normalizedCropRect] (or to
/// the tight bounding box of [normalizedPolygon], masking everything outside
/// the polygon with seamless paper-white) without any aspect-ratio constraint,
/// encoding the result as a compact JPEG.
///
/// [quarterTurns] applies coarse 90° clockwise rotations and
/// [fineRotationDegrees] applies fine straightening (e.g. `-45°..+45°`) around
/// the center of the oriented image, matching `FreeCropCanvas` pixel-for-pixel.
Future<Uint8List> cropAndEncodeJpg({
  required ui.Image sourceImage,
  required int quarterTurns,
  required ui.Rect normalizedCropRect,
  List<ui.Offset>? normalizedPolygon,
  double fineRotationDegrees = 0.0,
  int jpegQuality = 85,
  int maxOutputDimension = 2400,
}) async {
  final hasPolygon = normalizedPolygon != null &&
      normalizedPolygon.length >= kMinPolygonVertices;
  final effectiveCropRect =
      hasPolygon ? computePolygonBounds(normalizedPolygon) : normalizedCropRect;

  final normalizedTurns = ((quarterTurns % 4) + 4) % 4;
  final spec = computeOutputCropSpec(
    sourceWidth: sourceImage.width,
    sourceHeight: sourceImage.height,
    quarterTurns: normalizedTurns,
    normalizedCropRect: effectiveCropRect,
    maxOutputDimension: maxOutputDimension,
  );

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  if (fineRotationDegrees.abs() > 1e-4) {
    // Fill exposed rotated corners with paper-white so dark triangles never
    // interfere with downstream AI reading if a crop sits near a tilted corner.
    canvas.drawRect(
      ui.Rect.fromLTWH(
        0,
        0,
        spec.outputWidth.toDouble(),
        spec.outputHeight.toDouble(),
      ),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
  }

  canvas.scale(
    spec.outputWidth / spec.cropWidth,
    spec.outputHeight / spec.cropHeight,
  );
  canvas.translate(-spec.cropLeft.toDouble(), -spec.cropTop.toDouble());

  if (fineRotationDegrees.abs() > 1e-4) {
    final cx = spec.rotatedWidth / 2.0;
    final cy = spec.rotatedHeight / 2.0;
    canvas.translate(cx, cy);
    canvas.rotate(fineRotationDegrees * math.pi / 180.0);
    canvas.translate(-cx, -cy);
  }

  switch (normalizedTurns) {
    case 1:
      canvas.translate(sourceImage.height.toDouble(), 0);
      canvas.rotate(math.pi / 2);
      break;
    case 2:
      canvas.translate(
        sourceImage.width.toDouble(),
        sourceImage.height.toDouble(),
      );
      canvas.rotate(math.pi);
      break;
    case 3:
      canvas.translate(0, sourceImage.width.toDouble());
      canvas.rotate(-math.pi / 2);
      break;
    case 0:
    default:
      break;
  }

  canvas.drawImage(
    sourceImage,
    ui.Offset.zero,
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );

  final picture = recorder.endRecording();
  ui.Image? croppedImage;
  ui.Picture? maskedPicture;
  ui.Image? maskedImage;
  try {
    croppedImage = await picture.toImage(spec.outputWidth, spec.outputHeight);

    final needsPolygonMask = hasPolygon &&
        !isAxisAlignedRectPolygon(normalizedPolygon, effectiveCropRect);

    ui.Image finalImage = croppedImage;
    Uint8List? finalRgba;

    if (needsPolygonMask) {
      final rawData =
          await croppedImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (rawData == null) {
        throw StateError('无法读取裁剪后的图像像素数据');
      }
      final rawBytes = rawData.buffer.asUint8List(
        rawData.offsetInBytes,
        rawData.lengthInBytes,
      );

      final scaleX = spec.outputWidth / spec.cropWidth;
      final scaleY = spec.outputHeight / spec.cropHeight;
      final outputPolygon = normalizedPolygon
          .map(
            (pt) => ui.Offset(
              (pt.dx.clamp(0.0, 1.0) * spec.rotatedWidth - spec.cropLeft) *
                  scaleX,
              (pt.dy.clamp(0.0, 1.0) * spec.rotatedHeight - spec.cropTop) *
                  scaleY,
            ),
          )
          .toList(growable: false);

      final maskColor = _detectPaperMaskColor(
        rgba: rawBytes,
        width: spec.outputWidth,
        height: spec.outputHeight,
        outputPolygon: outputPolygon,
      );

      final maskRecorder = ui.PictureRecorder();
      final maskCanvas = ui.Canvas(maskRecorder);
      maskCanvas.drawRect(
        ui.Rect.fromLTWH(
          0,
          0,
          spec.outputWidth.toDouble(),
          spec.outputHeight.toDouble(),
        ),
        ui.Paint()..color = maskColor,
      );
      final clipPath = ui.Path()
        ..fillType = ui.PathFillType.evenOdd
        ..addPolygon(outputPolygon, true);
      maskCanvas.clipPath(clipPath);
      maskCanvas.drawImage(croppedImage, ui.Offset.zero, ui.Paint());

      maskedPicture = maskRecorder.endRecording();
      maskedImage =
          await maskedPicture.toImage(spec.outputWidth, spec.outputHeight);
      finalImage = maskedImage;
    }

    final byteData =
        await finalImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      throw StateError('无法读取裁剪后的图像像素数据');
    }
    finalRgba = Uint8List.fromList(
      byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ),
    );
    final width = spec.outputWidth;
    final height = spec.outputHeight;
    return await Isolate.run(
      () => _encodeRgbaAsJpg(
        rgba: finalRgba!,
        width: width,
        height: height,
        quality: jpegQuality,
      ),
    );
  } finally {
    maskedImage?.dispose();
    maskedPicture?.dispose();
    croppedImage?.dispose();
    picture.dispose();
  }
}

/// Estimates the exam paper background color inside [outputPolygon] from up to
/// `20x20` interior samples. Uses the 80th-percentile brightness sample when it
/// looks like neutral light paper (`lum >= 185` and low saturation), falling
/// back to pure white (`#FFFFFF`) on colored or dark backgrounds so AI never
/// mistakes the masked cutout for a drawn line or shaded region.
ui.Color _detectPaperMaskColor({
  required Uint8List rgba,
  required int width,
  required int height,
  required List<ui.Offset> outputPolygon,
}) {
  final samples = <(int lum, int r, int g, int b)>[];
  final stepX = math.max(1, width ~/ 20);
  final stepY = math.max(1, height ~/ 20);

  for (var y = stepY ~/ 2; y < height; y += stepY) {
    for (var x = stepX ~/ 2; x < width; x += stepX) {
      if (!isPointInPolygon(ui.Offset(x + 0.5, y + 0.5), outputPolygon)) {
        continue;
      }
      final offset = (y * width + x) * 4;
      if (offset + 2 >= rgba.length) continue;
      final r = rgba[offset];
      final g = rgba[offset + 1];
      final b = rgba[offset + 2];
      final lum = ((299 * r + 587 * g + 114 * b) / 1000).round();
      samples.add((lum, r, g, b));
    }
  }

  if (samples.isEmpty) {
    return const ui.Color(0xFFFFFFFF);
  }

  samples.sort((a, b) => a.$1.compareTo(b.$1));
  final idx =
      ((samples.length - 1) * 0.80).round().clamp(0, samples.length - 1);
  final (lum, r, g, b) = samples[idx];
  final maxCh = math.max(r, math.max(g, b));
  final minCh = math.min(r, math.min(g, b));

  if (lum >= 185 && (maxCh - minCh) <= 28) {
    return ui.Color.fromARGB(255, r, g, b);
  }
  return const ui.Color(0xFFFFFFFF);
}

Uint8List _encodeRgbaAsJpg({
  required Uint8List rgba,
  required int width,
  required int height,
  required int quality,
}) {
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgba.buffer,
    bytesOffset: rgba.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}
