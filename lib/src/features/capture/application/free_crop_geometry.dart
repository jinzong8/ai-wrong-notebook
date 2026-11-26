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

/// Minimum pinch-zoom factor relative to the initial display size (allows
/// shrinking down to 50% so taller/wider context can fit into the crop frame).
const double kMinCropZoom = 0.5;

/// Maximum pinch-zoom factor relative to the initial display size (up to 5x
/// magnification for inspecting fine subscripts, fractions, or diagrams).
const double kMaxCropZoom = 5.0;

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

/// Maps viewport-space [screenCropRect] back into normalized `[0, 1]` image
/// coordinates inside [displayRect].
Rect displayToNormalizedCropRect(Rect screenCropRect, Rect displayRect) {
  if (displayRect.width <= 0 || displayRect.height <= 0) {
    return fullNormalizedCropRect;
  }
  final left = ((screenCropRect.left - displayRect.left) / displayRect.width)
      .clamp(0.0, 1.0);
  final top = ((screenCropRect.top - displayRect.top) / displayRect.height)
      .clamp(0.0, 1.0);
  final right = ((screenCropRect.right - displayRect.left) / displayRect.width)
      .clamp(left, 1.0);
  final bottom =
      ((screenCropRect.bottom - displayRect.top) / displayRect.height)
          .clamp(top, 1.0);
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Computes the reachable viewport rectangle for crop handles, keeping top and
/// bottom handles comfortably inset from surrounding toolbars.
Rect computeViewportCropBounds({
  required Size viewportSize,
  EdgeInsets padding = const EdgeInsets.symmetric(vertical: 10),
  double verticalInset = 10.0,
}) {
  final minTop = math.min(
    viewportSize.height * 0.25,
    math.max(padding.top, verticalInset),
  );
  final maxBottom = math.max(
    viewportSize.height * 0.75,
    viewportSize.height - math.max(padding.bottom, verticalInset),
  );
  final left = padding.left;
  final right = math.max(left + 1.0, viewportSize.width - padding.right);
  return Rect.fromLTRB(
    left,
    minTop,
    right,
    math.max(minTop + 1.0, maxBottom),
  );
}

/// Computes the intersection of reachable viewport bounds and [displayRect] so
/// crop handles stay both on-screen and inside the rendered photo.
Rect computeAllowedScreenCropBounds({
  required Size viewportSize,
  required Rect displayRect,
  EdgeInsets padding = const EdgeInsets.symmetric(vertical: 10),
  double verticalInset = 10.0,
}) {
  final viewportBounds = computeViewportCropBounds(
    viewportSize: viewportSize,
    padding: padding,
    verticalInset: verticalInset,
  );
  final intersected = viewportBounds.intersect(displayRect);
  if (intersected.width <= 0 || intersected.height <= 0) {
    return viewportBounds;
  }
  return intersected;
}

/// Clamps screen-space [rect] inside [bounds] while enforcing [minCropSizePx].
Rect clampScreenCropRect(
  Rect rect, {
  required Rect bounds,
  double minCropSizePx = 28.0,
}) {
  final minW = math.min(bounds.width, minCropSizePx);
  final minH = math.min(bounds.height, minCropSizePx);
  final left = rect.left.clamp(bounds.left, bounds.right - minW);
  final top = rect.top.clamp(bounds.top, bounds.bottom - minH);
  final right = rect.right.clamp(left + minW, bounds.right);
  final bottom = rect.bottom.clamp(top + minH, bounds.bottom);
  return Rect.fromLTRB(left, top, right, bottom);
}

/// Applies a screen-space drag [delta] directly to [screenRect] within [bounds]
/// with independent width and height (zero aspect-ratio lock).
Rect applyScreenCropHandleDelta({
  required Rect screenRect,
  required CropHandle handle,
  required Offset delta,
  required Rect bounds,
  double minCropSizePx = 28.0,
}) {
  final minW = math.min(bounds.width, minCropSizePx);
  final minH = math.min(bounds.height, minCropSizePx);

  var left = screenRect.left;
  var top = screenRect.top;
  var right = screenRect.right;
  var bottom = screenRect.bottom;

  switch (handle) {
    case CropHandle.move:
      final width = math.min(bounds.width, right - left);
      final height = math.min(bounds.height, bottom - top);
      left = (left + delta.dx).clamp(bounds.left, bounds.right - width);
      top = (top + delta.dy).clamp(bounds.top, bounds.bottom - height);
      right = left + width;
      bottom = top + height;
      break;
    case CropHandle.left:
      left = (left + delta.dx).clamp(bounds.left, right - minW);
      break;
    case CropHandle.right:
      right = (right + delta.dx).clamp(left + minW, bounds.right);
      break;
    case CropHandle.top:
      top = (top + delta.dy).clamp(bounds.top, bottom - minH);
      break;
    case CropHandle.bottom:
      bottom = (bottom + delta.dy).clamp(top + minH, bounds.bottom);
      break;
    case CropHandle.topLeft:
      left = (left + delta.dx).clamp(bounds.left, right - minW);
      top = (top + delta.dy).clamp(bounds.top, bottom - minH);
      break;
    case CropHandle.topRight:
      right = (right + delta.dx).clamp(left + minW, bounds.right);
      top = (top + delta.dy).clamp(bounds.top, bottom - minH);
      break;
    case CropHandle.bottomLeft:
      left = (left + delta.dx).clamp(bounds.left, right - minW);
      bottom = (bottom + delta.dy).clamp(top + minH, bounds.bottom);
      break;
    case CropHandle.bottomRight:
      right = (right + delta.dx).clamp(left + minW, bounds.right);
      bottom = (bottom + delta.dy).clamp(top + minH, bounds.bottom);
      break;
  }

  return Rect.fromLTRB(left, top, right, bottom);
}

/// Clamps [rawDisplayRect] so that when zoomed larger than [anchorCropRect] the
/// photo always covers [anchorCropRect] (never exposing empty void inside the
/// crop frame), and when zoomed smaller than [anchorCropRect] it stays centered
/// on that axis.
Rect clampZoomedDisplayRect({
  required Rect rawDisplayRect,
  required Rect anchorCropRect,
}) {
  final w = rawDisplayRect.width;
  final h = rawDisplayRect.height;

  final double left;
  if (w >= anchorCropRect.width) {
    left = rawDisplayRect.left.clamp(
      anchorCropRect.right - w,
      anchorCropRect.left,
    );
  } else {
    left = anchorCropRect.center.dx - w / 2.0;
  }

  final double top;
  if (h >= anchorCropRect.height) {
    top = rawDisplayRect.top.clamp(
      anchorCropRect.bottom - h,
      anchorCropRect.top,
    );
  } else {
    top = anchorCropRect.center.dy - h / 2.0;
  }

  return Rect.fromLTWH(left, top, w, h);
}

/// Computes the zoomed and panned photo display rectangle during a pinch/pan
/// gesture so the image point under [startFocalPoint] stays anchored beneath
/// [currentFocalPoint] before clamping against [anchorCropRect].
Rect computeFocalZoomDisplayRect({
  required Rect baseDisplayRect,
  required Rect startDisplayRect,
  required double startZoom,
  required Offset startFocalPoint,
  required Offset currentFocalPoint,
  required double scaleFactor,
  required Rect anchorCropRect,
  double minZoom = kMinCropZoom,
  double maxZoom = kMaxCropZoom,
}) {
  final nextZoom = (startZoom * scaleFactor).clamp(minZoom, maxZoom);
  final newW = baseDisplayRect.width * nextZoom;
  final newH = baseDisplayRect.height * nextZoom;

  final u = startDisplayRect.width > 0
      ? (startFocalPoint.dx - startDisplayRect.left) / startDisplayRect.width
      : 0.5;
  final v = startDisplayRect.height > 0
      ? (startFocalPoint.dy - startDisplayRect.top) / startDisplayRect.height
      : 0.5;

  final rawRect = Rect.fromLTWH(
    currentFocalPoint.dx - u * newW,
    currentFocalPoint.dy - v * newH,
    newW,
    newH,
  );
  return clampZoomedDisplayRect(
    rawDisplayRect: rawRect,
    anchorCropRect: anchorCropRect,
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

// ---------------------------------------------------------------------------
// Map-style Arbitrary Polygon Crop Geometry
// ---------------------------------------------------------------------------

/// Minimum vertex count for a valid polygon crop region.
const int kMinPolygonVertices = 3;

/// Maximum vertex count so map-style midpoint handles remain uncluttered.
const int kMaxPolygonVertices = 16;

/// Pinch-zoom threshold (`1.15x`) at which map-style polygon vertices and
/// edge-midpoint `+` handles automatically activate unless manually overridden.
const double kAutoPolygonZoomThreshold = 1.15;

/// Minimum screen-space edge length (`px`) required before rendering or
/// hit-testing a midpoint `+` splitter on that edge.
const double kMinEdgeLengthForMidpoint = 44.0;

enum PolygonHitKind {
  vertex,
  midpoint,
  edge,
  interior,
}

class PolygonHitResult {
  const PolygonHitResult({
    required this.kind,
    this.index = -1,
    this.parameterT = 0.5,
  });

  final PolygonHitKind kind;

  /// Vertex index for [PolygonHitKind.vertex], or leading edge index `i`
  /// (connecting `i` to `(i + 1) % N`) for [PolygonHitKind.midpoint] and
  /// [PolygonHitKind.edge].
  final int index;

  /// Parametric position `t` in `(0..1)` along edge `i -> (i + 1) % N` where
  /// a midpoint `+` handle was hit (supports partially off-screen zoomed edges).
  final double parameterT;
}

/// Converts a rectangle into 4 clockwise polygon vertices `[TL, TR, BR, BL]`.
List<Offset> rectToPolygonVertices(Rect rect) {
  return <Offset>[
    rect.topLeft,
    rect.topRight,
    rect.bottomRight,
    rect.bottomLeft,
  ];
}

/// Computes the tight normalized `[0..1, 0..1]` bounding box of [vertices].
Rect computePolygonBounds(
  List<Offset> vertices, {
  double minSpan = 0.015,
}) {
  if (vertices.isEmpty) return fullNormalizedCropRect;
  var minX = 1.0;
  var minY = 1.0;
  var maxX = 0.0;
  var maxY = 0.0;
  for (final pt in vertices) {
    final x = pt.dx.clamp(0.0, 1.0);
    final y = pt.dy.clamp(0.0, 1.0);
    if (x < minX) minX = x;
    if (y < minY) minY = y;
    if (x > maxX) maxX = x;
    if (y > maxY) maxY = y;
  }
  if (maxX - minX < minSpan) {
    final cx = ((minX + maxX) * 0.5).clamp(minSpan * 0.5, 1.0 - minSpan * 0.5);
    minX = (cx - minSpan * 0.5).clamp(0.0, 1.0);
    maxX = (cx + minSpan * 0.5).clamp(0.0, 1.0);
  }
  if (maxY - minY < minSpan) {
    final cy = ((minY + maxY) * 0.5).clamp(minSpan * 0.5, 1.0 - minSpan * 0.5);
    minY = (cy - minSpan * 0.5).clamp(0.0, 1.0);
    maxY = (cy + minSpan * 0.5).clamp(0.0, 1.0);
  }
  return Rect.fromLTRB(minX, minY, maxX, maxY);
}

/// Returns `true` when [vertices] is simply the 4 corners of [bounds] (in
/// clockwise or counter-clockwise order), meaning no non-rectangular exterior
/// masking is needed.
bool isAxisAlignedRectPolygon(
  List<Offset>? vertices,
  Rect bounds, {
  double epsilon = 1.5e-3,
}) {
  if (vertices == null || vertices.length != 4) return false;
  final corners = <Offset>[
    bounds.topLeft,
    bounds.topRight,
    bounds.bottomRight,
    bounds.bottomLeft,
  ];
  for (var start = 0; start < 4; start++) {
    var cwMatch = true;
    var ccwMatch = true;
    for (var i = 0; i < 4; i++) {
      if ((vertices[i] - corners[(start + i) % 4]).distance > epsilon) {
        cwMatch = false;
      }
      if ((vertices[i] - corners[(start - i + 4) % 4]).distance > epsilon) {
        ccwMatch = false;
      }
    }
    if (cwMatch || ccwMatch) return true;
  }
  return false;
}

/// Maps normalized `[0..1, 0..1]` polygon vertices into screen [displayRect].
List<Offset> normalizedPolygonToDisplay(
  List<Offset> normalizedVertices,
  Rect displayRect,
) {
  return normalizedVertices
      .map(
        (pt) => Offset(
          displayRect.left + pt.dx * displayRect.width,
          displayRect.top + pt.dy * displayRect.height,
        ),
      )
      .toList(growable: false);
}

/// Maps a single screen-space point back into normalized `[0..1, 0..1]`
/// image coordinates relative to [displayRect].
Offset displayPointToNormalized(Offset screenPoint, Rect displayRect) {
  if (displayRect.width <= 0 || displayRect.height <= 0) {
    return Offset.zero;
  }
  return Offset(
    ((screenPoint.dx - displayRect.left) / displayRect.width).clamp(0.0, 1.0),
    ((screenPoint.dy - displayRect.top) / displayRect.height).clamp(0.0, 1.0),
  );
}

/// Maps screen-space polygon vertices back into normalized `[0..1, 0..1]`
/// image coordinates relative to [displayRect].
List<Offset> displayPolygonToNormalized(
  List<Offset> screenVertices,
  Rect displayRect,
) {
  return screenVertices
      .map((pt) => displayPointToNormalized(pt, displayRect))
      .toList(growable: false);
}

/// Rotates normalized `[0..1, 0..1]` polygon vertices by 90 degrees so a
/// sculpted cutout stays locked to the same question when rotating the photo.
List<Offset> rotateNormalizedPolygon(
  List<Offset> vertices, {
  required bool clockwise,
}) {
  return vertices.map((pt) {
    if (clockwise) {
      return Offset(
        (1.0 - pt.dy).clamp(0.0, 1.0),
        pt.dx.clamp(0.0, 1.0),
      );
    }
    return Offset(
      pt.dy.clamp(0.0, 1.0),
      (1.0 - pt.dx).clamp(0.0, 1.0),
    );
  }).toList(growable: false);
}

/// Signed polygon area via the shoelace formula (absolute value = area).
double computePolygonArea(List<Offset> vertices) {
  if (vertices.length < 3) return 0.0;
  var sum = 0.0;
  for (var i = 0; i < vertices.length; i++) {
    final a = vertices[i];
    final b = vertices[(i + 1) % vertices.length];
    sum += a.dx * b.dy - b.dx * a.dy;
  }
  return (sum * 0.5).abs();
}

/// Even-odd ray-casting point-in-polygon test (handles both convex and concave
/// L/T/U/Z polygons accurately).
bool isPointInPolygon(Offset point, List<Offset> polygon) {
  if (polygon.length < 3) return false;
  var inside = false;
  for (var i = 0, j = polygon.length - 1; i < polygon.length; j = i++) {
    final pi = polygon[i];
    final pj = polygon[j];
    final intersects = ((pi.dy > point.dy) != (pj.dy > point.dy)) &&
        (point.dx <
            (pj.dx - pi.dx) *
                    (point.dy - pi.dy) /
                    ((pj.dy - pi.dy) == 0 ? 1e-12 : (pj.dy - pi.dy)) +
                pi.dx);
    if (intersects) {
      inside = !inside;
    }
  }
  return inside;
}

double _pointToSegmentDistance(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final lenSq = ab.dx * ab.dx + ab.dy * ab.dy;
  if (lenSq <= 1e-9) return (p - a).distance;
  final t =
      (((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / lenSq).clamp(0.0, 1.0);
  final proj = Offset(a.dx + ab.dx * t, a.dy + ab.dy * t);
  return (p - proj).distance;
}

/// Clips polygon segment `[a, b]` to `[0..viewportSize.width, 0..viewportSize.height]`
/// via Liang-Barsky and returns the midpoint of the **visible** segment (along
/// with its parametric `t` on `[a, b]`) when the visible length is at least
/// [minVisibleLength].
///
/// This ensures that even at `3x..5x` zoom when one endpoint of a long polygon
/// border is panned far off-screen, the `+` splitter handle (`⊕`) stays right
/// in the center of the visible border on screen.
({Offset midpoint, double parameterT})? computeVisibleEdgeMidpoint({
  required Offset a,
  required Offset b,
  required Size viewportSize,
  double inset = 9.0,
  double minVisibleLength = kMinEdgeLengthForMidpoint,
}) {
  if (viewportSize.isEmpty) return null;

  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  var t0 = 0.0;
  var t1 = 1.0;

  bool clipSide(double p, double q) {
    if (p.abs() < 1e-9) {
      return q >= -1e-4;
    }
    final r = q / p;
    if (p < 0) {
      if (r > t1) return false;
      if (r > t0) t0 = r;
    } else {
      if (r < t0) return false;
      if (r < t1) t1 = r;
    }
    return true;
  }

  if (!clipSide(-dx, a.dx) ||
      !clipSide(dx, viewportSize.width - a.dx) ||
      !clipSide(-dy, a.dy) ||
      !clipSide(dy, viewportSize.height - a.dy)) {
    return null;
  }

  final visA = Offset(a.dx + dx * t0, a.dy + dy * t0);
  final visB = Offset(a.dx + dx * t1, a.dy + dy * t1);
  if ((visB - visA).distance < minVisibleLength) {
    return null;
  }

  final tMid = (t0 + t1) * 0.5;
  final rawMid = Offset(a.dx + dx * tMid, a.dy + dy * tMid);
  final maxX = math.max(inset, viewportSize.width - inset);
  final maxY = math.max(inset, viewportSize.height - inset);
  final clampedMid = Offset(
    rawMid.dx.clamp(inset, maxX),
    rawMid.dy.clamp(inset, maxY),
  );
  return (midpoint: clampedMid, parameterT: tMid);
}

/// Hit-tests map-style polygon handles in priority order:
/// 1. Existing corner/vertex (`●`)
/// 2. Edge-midpoint `+` splitter (`⊕`, when visible edge length >= `44px`)
/// 3. Edge segment (for parallel edge sliding)
/// 4. Polygon interior
PolygonHitResult? hitTestPolygonHandle({
  required Offset position,
  required List<Offset> screenVertices,
  Size? viewportSize,
  int maxVertices = kMaxPolygonVertices,
  double vertexHitRadius = 26.0,
  double midpointHitRadius = 22.0,
  double minEdgeLengthForMidpoint = kMinEdgeLengthForMidpoint,
  double edgeHitThickness = 18.0,
}) {
  if (screenVertices.length < 3) return null;

  // 1. Closest vertex handle.
  var bestVertexIdx = -1;
  var bestVertexDist = double.infinity;
  for (var i = 0; i < screenVertices.length; i++) {
    final dist = (position - screenVertices[i]).distance;
    if (dist <= vertexHitRadius && dist < bestVertexDist) {
      bestVertexDist = dist;
      bestVertexIdx = i;
    }
  }
  if (bestVertexIdx >= 0) {
    return PolygonHitResult(
      kind: PolygonHitKind.vertex,
      index: bestVertexIdx,
    );
  }

  // 2. Closest edge-midpoint `+` handle (splits edge to insert a new vertex).
  if (screenVertices.length < maxVertices) {
    var bestMidIdx = -1;
    var bestMidDist = double.infinity;
    var bestMidT = 0.5;
    for (var i = 0; i < screenVertices.length; i++) {
      final a = screenVertices[i];
      final b = screenVertices[(i + 1) % screenVertices.length];
      Offset mid;
      var paramT = 0.5;
      if (viewportSize != null && !viewportSize.isEmpty) {
        final vis = computeVisibleEdgeMidpoint(
          a: a,
          b: b,
          viewportSize: viewportSize,
          inset: 9.0,
          minVisibleLength: minEdgeLengthForMidpoint,
        );
        if (vis == null) continue;
        mid = vis.midpoint;
        paramT = vis.parameterT;
      } else {
        if ((b - a).distance < minEdgeLengthForMidpoint) continue;
        mid = Offset((a.dx + b.dx) * 0.5, (a.dy + b.dy) * 0.5);
      }
      final dist = (position - mid).distance;
      if (dist <= midpointHitRadius && dist < bestMidDist) {
        bestMidDist = dist;
        bestMidIdx = i;
        bestMidT = paramT;
      }
    }
    if (bestMidIdx >= 0) {
      return PolygonHitResult(
        kind: PolygonHitKind.midpoint,
        index: bestMidIdx,
        parameterT: bestMidT,
      );
    }
  }

  // 3. Closest edge segment (moves both endpoints of that segment together).
  var bestEdgeIdx = -1;
  var bestEdgeDist = double.infinity;
  for (var i = 0; i < screenVertices.length; i++) {
    final a = screenVertices[i];
    final b = screenVertices[(i + 1) % screenVertices.length];
    final dist = _pointToSegmentDistance(position, a, b);
    if (dist <= edgeHitThickness && dist < bestEdgeDist) {
      bestEdgeDist = dist;
      bestEdgeIdx = i;
    }
  }
  if (bestEdgeIdx >= 0) {
    return PolygonHitResult(
      kind: PolygonHitKind.edge,
      index: bestEdgeIdx,
    );
  }

  // 4. Interior.
  if (isPointInPolygon(position, screenVertices)) {
    return const PolygonHitResult(kind: PolygonHitKind.interior);
  }

  return null;
}

/// Clamps [rawDisplayRect] during free map-like pan & zoom when a custom
/// polygon is anchored to the image, allowing the user to pan freely to any
/// corner of the exam paper at high zoom (`2x..5x`) without losing the photo
/// completely off-screen.
Rect clampFreePanDisplayRect({
  required Rect rawDisplayRect,
  required Size viewportSize,
  double minVisibleMargin = 96.0,
}) {
  final w = rawDisplayRect.width;
  final h = rawDisplayRect.height;

  final double left;
  if (w <= viewportSize.width) {
    left = (viewportSize.width - w) * 0.5;
  } else {
    final marginX = math.min(minVisibleMargin, viewportSize.width * 0.45);
    left = rawDisplayRect.left.clamp(
      marginX - w,
      viewportSize.width - marginX,
    );
  }

  final double top;
  if (h <= viewportSize.height) {
    top = (viewportSize.height - h) * 0.5;
  } else {
    final marginY = math.min(minVisibleMargin, viewportSize.height * 0.45);
    top = rawDisplayRect.top.clamp(
      marginY - h,
      viewportSize.height - marginY,
    );
  }

  return Rect.fromLTWH(left, top, w, h);
}
