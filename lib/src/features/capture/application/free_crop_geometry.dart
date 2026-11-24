import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// Interactive drag handles for free-form rectangular cropping without any
/// aspect-ratio constraint.
enum CropHandle {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
  top,
  bottom,
  left,
  right,
  move,
}

/// Exact pixel-space crop geometry computed for an oriented image.
class OutputCropSpec {
  const OutputCropSpec({
    required this.rotatedWidth,
    required this.rotatedHeight,
    required this.cropLeft,
    required this.cropTop,
    required this.cropWidth,
    required this.cropHeight,
    required this.outputWidth,
    required this.outputHeight,
  });

  final int rotatedWidth;
  final int rotatedHeight;
  final int cropLeft;
  final int cropTop;
  final int cropWidth;
  final int cropHeight;
  final int outputWidth;
  final int outputHeight;
}

/// Full normalized crop bounds covering the entire image.
const Rect fullNormalizedCropRect = Rect.fromLTRB(0.0, 0.0, 1.0, 1.0);

/// Computes the `BoxFit.contain` display rectangle of [imageSize] inside
/// [viewportSize] after applying [padding].
Rect computeFittedImageRect({
  required Size viewportSize,
  required Size imageSize,
  EdgeInsets padding = const EdgeInsets.symmetric(vertical: 10),
}) {
  final availW = math.max(1.0, viewportSize.width - padding.horizontal);
  final availH = math.max(1.0, viewportSize.height - padding.vertical);
  if (imageSize.width <= 0 || imageSize.height <= 0) {
    return Rect.fromLTWH(padding.left, padding.top, availW, availH);
  }

  final imageAspect = imageSize.width / imageSize.height;
  final availAspect = availW / availH;

  final double drawW;
  final double drawH;
  if (imageAspect > availAspect) {
    drawW = availW;
    drawH = availW / imageAspect;
  } else {
    drawH = availH;
    drawW = availH * imageAspect;
  }

  final left = padding.left + (availW - drawW) / 2;
  final top = padding.top + (availH - drawH) / 2;
  return Rect.fromLTWH(left, top, drawW, drawH);
}

/// Computes a 100%-width display rectangle for [imageSize] centered vertically
/// inside [viewportSize]. When the photo is taller than the viewport (for
/// example, a 9:16 portrait camera capture), top and bottom overflow equally,
/// matching the live camera viewfinder scale pixel-for-pixel.
Rect computeWidthFilledImageRect({
  required Size viewportSize,
  required Size imageSize,
}) {
  final drawW = math.max(1.0, viewportSize.width);
  if (imageSize.width <= 0 || imageSize.height <= 0) {
    return Rect.fromLTWH(0, 0, drawW, math.max(1.0, viewportSize.height));
  }
  final drawH = drawW * (imageSize.height / imageSize.width);
  final top = (viewportSize.height - drawH) / 2.0;
  return Rect.fromLTWH(0, top, drawW, drawH);
}

/// Returns the `[0, 1]` sub-rectangle of [displayRect] visible inside
/// [viewportSize]. When top/bottom overflow is clipped, applies [verticalInset]
/// so top/bottom crop handles remain comfortably reachable inside the viewport.
Rect computeVisibleNormalizedBounds({
  required Rect displayRect,
  required Size viewportSize,
  double verticalInset = 10.0,
}) {
  if (displayRect.width <= 0 || displayRect.height <= 0) {
    return fullNormalizedCropRect;
  }
  final visTopPx = displayRect.top < 0
      ? math.min(viewportSize.height * 0.25, verticalInset)
      : displayRect.top;
  final visBottomPx = displayRect.bottom > viewportSize.height
      ? math.max(
          viewportSize.height * 0.75,
          viewportSize.height - verticalInset,
        )
      : displayRect.bottom;

  final left = ((0.0 - displayRect.left) / displayRect.width).clamp(0.0, 1.0);
  final right = ((viewportSize.width - displayRect.left) / displayRect.width)
      .clamp(0.0, 1.0);
  final top =
      ((visTopPx - displayRect.top) / displayRect.height).clamp(0.0, 1.0);
  final bottom =
      ((visBottomPx - displayRect.top) / displayRect.height).clamp(0.0, 1.0);

  if (right <= left || bottom <= top) {
    return fullNormalizedCropRect;
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Clamps [rect] into [bounds] while enforcing a minimum crop size.
Rect clampNormalizedCropRect(
  Rect rect, {
  required Rect bounds,
  required Rect displayRect,
  double minCropSizePx = 28.0,
}) {
  if (displayRect.width <= 0 || displayRect.height <= 0) return rect;
  final minW = math.min(bounds.width, minCropSizePx / displayRect.width);
  final minH = math.min(bounds.height, minCropSizePx / displayRect.height);

  var left = rect.left.clamp(bounds.left, bounds.right - minW);
  var top = rect.top.clamp(bounds.top, bounds.bottom - minH);
  var right = rect.right.clamp(left + minW, bounds.right);
  var bottom = rect.bottom.clamp(top + minH, bounds.bottom);
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Maps normalized `[0, 1]` crop bounds to display coordinates inside
/// [displayRect].
Rect normalizedToDisplayRect(Rect normalizedRect, Rect displayRect) {
  return Rect.fromLTRB(
    displayRect.left + normalizedRect.left * displayRect.width,
    displayRect.top + normalizedRect.top * displayRect.height,
    displayRect.left + normalizedRect.right * displayRect.width,
    displayRect.top + normalizedRect.bottom * displayRect.height,
  );
}

/// Returns `true` if [normalizedRect] covers virtually the whole image.
bool isEffectivelyFullCrop(Rect normalizedRect) {
  return normalizedRect.left <= 0.002 &&
      normalizedRect.top <= 0.002 &&
      normalizedRect.right >= 0.998 &&
      normalizedRect.bottom >= 0.998;
}

/// Picks the most intuitive handle near [position] for [screenCropRect].
///
/// Corners take priority over edges, and within each group the nearest handle
/// wins so even very thin horizontal strips (e.g. a single 1-2 line question)
/// remain easy to adjust along both top and bottom borders.
CropHandle? hitTestCropHandle({
  required Offset position,
  required Rect screenCropRect,
  double cornerHitRadius = 30.0,
  double edgeHitThickness = 26.0,
}) {
  // 1. Closest corner within radius.
  final corners = <(CropHandle, Offset)>[
    (CropHandle.topLeft, screenCropRect.topLeft),
    (CropHandle.topRight, screenCropRect.topRight),
    (CropHandle.bottomLeft, screenCropRect.bottomLeft),
    (CropHandle.bottomRight, screenCropRect.bottomRight),
  ];

  CropHandle? bestCorner;
  var bestCornerDist = double.infinity;
  for (final (handle, corner) in corners) {
    final dist = (position - corner).distance;
    if (dist <= cornerHitRadius && dist < bestCornerDist) {
      bestCorner = handle;
      bestCornerDist = dist;
    }
  }
  if (bestCorner != null) return bestCorner;

  // 2. Closest edge within thickness (and orthogonal span with slight slack).
  final slack = edgeHitThickness * 0.5;
  final withinHorizontalSpan = position.dx >= screenCropRect.left - slack &&
      position.dx <= screenCropRect.right + slack;
  final withinVerticalSpan = position.dy >= screenCropRect.top - slack &&
      position.dy <= screenCropRect.bottom + slack;

  final candidateEdges = <(CropHandle, double)>[
    if (withinHorizontalSpan)
      (CropHandle.top, (position.dy - screenCropRect.top).abs()),
    if (withinHorizontalSpan)
      (CropHandle.bottom, (position.dy - screenCropRect.bottom).abs()),
    if (withinVerticalSpan)
      (CropHandle.left, (position.dx - screenCropRect.left).abs()),
    if (withinVerticalSpan)
      (CropHandle.right, (position.dx - screenCropRect.right).abs()),
  ];

  CropHandle? bestEdge;
  var bestEdgeDist = double.infinity;
  for (final (handle, dist) in candidateEdges) {
    if (dist <= edgeHitThickness && dist < bestEdgeDist) {
      bestEdge = handle;
      bestEdgeDist = dist;
    }
  }
  if (bestEdge != null) return bestEdge;

  // 3. Interior pan to reposition the box while preserving its size.
  if (screenCropRect.contains(position)) {
    return CropHandle.move;
  }

  return null;
}

/// Applies a screen-space drag [delta] to [normalizedRect] for [handle] with
/// completely independent width and height (zero aspect-ratio restriction).
Rect applyCropHandleDelta({
  required Rect normalizedRect,
  required CropHandle handle,
  required Offset delta,
  required Rect displayRect,
  Rect bounds = fullNormalizedCropRect,
  double minCropSizePx = 28.0,
}) {
  if (displayRect.width <= 0 || displayRect.height <= 0) {
    return normalizedRect;
  }

  final dx = delta.dx / displayRect.width;
  final dy = delta.dy / displayRect.height;
  final minW = math.min(bounds.width, minCropSizePx / displayRect.width);
  final minH = math.min(bounds.height, minCropSizePx / displayRect.height);

  var left = normalizedRect.left;
  var top = normalizedRect.top;
  var right = normalizedRect.right;
  var bottom = normalizedRect.bottom;

  switch (handle) {
    case CropHandle.move:
      final width = math.min(bounds.width, right - left);
      final height = math.min(bounds.height, bottom - top);
      left = (left + dx).clamp(bounds.left, bounds.right - width);
      top = (top + dy).clamp(bounds.top, bounds.bottom - height);
      right = left + width;
      bottom = top + height;
      break;
    case CropHandle.left:
      left = (left + dx).clamp(bounds.left, right - minW);
      break;
    case CropHandle.right:
      right = (right + dx).clamp(left + minW, bounds.right);
      break;
    case CropHandle.top:
      top = (top + dy).clamp(bounds.top, bottom - minH);
      break;
    case CropHandle.bottom:
      bottom = (bottom + dy).clamp(top + minH, bounds.bottom);
      break;
    case CropHandle.topLeft:
      left = (left + dx).clamp(bounds.left, right - minW);
      top = (top + dy).clamp(bounds.top, bottom - minH);
      break;
    case CropHandle.topRight:
      right = (right + dx).clamp(left + minW, bounds.right);
      top = (top + dy).clamp(bounds.top, bottom - minH);
      break;
    case CropHandle.bottomLeft:
      left = (left + dx).clamp(bounds.left, right - minW);
      bottom = (bottom + dy).clamp(top + minH, bounds.bottom);
      break;
    case CropHandle.bottomRight:
      right = (right + dx).clamp(left + minW, bounds.right);
      bottom = (bottom + dy).clamp(top + minH, bounds.bottom);
      break;
  }

  return Rect.fromLTRB(left, top, right, bottom);
}

/// Rotates a normalized `[0, 1]` crop rectangle by 90 degrees so the selected
/// content stays aligned when the user rotates the photo.
Rect rotateNormalizedCropRect(Rect rect, {required bool clockwise}) {
  if (clockwise) {
    return Rect.fromLTRB(
      (1.0 - rect.bottom).clamp(0.0, 1.0),
      rect.left.clamp(0.0, 1.0),
      (1.0 - rect.top).clamp(0.0, 1.0),
      rect.right.clamp(0.0, 1.0),
    );
  }
  return Rect.fromLTRB(
    rect.top.clamp(0.0, 1.0),
    (1.0 - rect.right).clamp(0.0, 1.0),
    rect.bottom.clamp(0.0, 1.0),
    (1.0 - rect.left).clamp(0.0, 1.0),
  );
}

/// Computes exact pixel crop bounds and capped output dimensions for a rotated
/// image while strictly preserving the user's chosen free-form proportions.
OutputCropSpec computeOutputCropSpec({
  required int sourceWidth,
  required int sourceHeight,
  required int quarterTurns,
  required Rect normalizedCropRect,
  int maxOutputDimension = 2400,
}) {
  final normalizedTurns = ((quarterTurns % 4) + 4) % 4;
  final rotatedW = normalizedTurns.isOdd ? sourceHeight : sourceWidth;
  final rotatedH = normalizedTurns.isOdd ? sourceWidth : sourceHeight;

  final clampedLeft = normalizedCropRect.left.clamp(0.0, 1.0);
  final clampedTop = normalizedCropRect.top.clamp(0.0, 1.0);
  final clampedRight = normalizedCropRect.right.clamp(0.0, 1.0);
  final clampedBottom = normalizedCropRect.bottom.clamp(0.0, 1.0);

  final cropLeft = (clampedLeft * rotatedW).floor().clamp(0, rotatedW - 1);
  final cropTop = (clampedTop * rotatedH).floor().clamp(0, rotatedH - 1);
  final cropRight =
      (clampedRight * rotatedW).ceil().clamp(cropLeft + 1, rotatedW);
  final cropBottom =
      (clampedBottom * rotatedH).ceil().clamp(cropTop + 1, rotatedH);

  final cropW = cropRight - cropLeft;
  final cropH = cropBottom - cropTop;

  final longest = math.max(cropW, cropH);
  final double scale =
      longest > maxOutputDimension ? maxOutputDimension / longest : 1.0;

  final outputW = math.max(1, (cropW * scale).round());
  final outputH = math.max(1, (cropH * scale).round());

  return OutputCropSpec(
    rotatedWidth: rotatedW,
    rotatedHeight: rotatedH,
    cropLeft: cropLeft,
    cropTop: cropTop,
    cropWidth: cropW,
    cropHeight: cropH,
    outputWidth: outputW,
    outputHeight: outputH,
  );
}
