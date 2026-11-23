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

/// Crops and optionally rotates [sourceImage] to [normalizedCropRect] without
/// any aspect-ratio constraint, encoding the result as a compact JPEG.
Future<Uint8List> cropAndEncodeJpg({
  required ui.Image sourceImage,
  required int quarterTurns,
  required ui.Rect normalizedCropRect,
  int jpegQuality = 85,
  int maxOutputDimension = 2400,
}) async {
  final normalizedTurns = ((quarterTurns % 4) + 4) % 4;
  final spec = computeOutputCropSpec(
    sourceWidth: sourceImage.width,
    sourceHeight: sourceImage.height,
    quarterTurns: normalizedTurns,
    normalizedCropRect: normalizedCropRect,
    maxOutputDimension: maxOutputDimension,
  );

  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);

  canvas.scale(
    spec.outputWidth / spec.cropWidth,
    spec.outputHeight / spec.cropHeight,
  );
  canvas.translate(-spec.cropLeft.toDouble(), -spec.cropTop.toDouble());

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
  try {
    croppedImage = await picture.toImage(spec.outputWidth, spec.outputHeight);
    final byteData =
        await croppedImage.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      throw StateError('无法读取裁剪后的图像像素数据');
    }
    final rgbaCopy = Uint8List.fromList(
      byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      ),
    );
    final width = spec.outputWidth;
    final height = spec.outputHeight;
    return await Isolate.run(
      () => _encodeRgbaAsJpg(
        rgba: rgbaCopy,
        width: width,
        height: height,
        quality: jpegQuality,
      ),
    );
  } finally {
    croppedImage?.dispose();
    picture.dispose();
  }
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
