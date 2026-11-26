import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';

/// Visual overlay for free-form rectangular and map-style arbitrary polygon
/// question selection.
///
/// In rectangular mode ([polygonVertices] == null), renders a dimmed surround,
/// 3x3 framing guides, L-shaped corner brackets, and centered edge drag bars.
/// In polygon mode ([polygonVertices] != null), renders a dimmed surround
/// outside the arbitrary polygon, crisp polygon edges, circular vertex handles
/// (`●`), and map-style edge-midpoint `+` handles (`⊕`) for splitting edges.
class CropOverlay extends StatelessWidget {
  const CropOverlay({
    super.key,
    required this.cropRect,
    this.polygonVertices,
    this.activeHandle,
    this.activeVertexIndex,
    this.selectedVertexIndex,
    this.activeEdgeIndex,
    this.emphasizeGrid = false,
    this.accentColor = const Color(0xFF818CF8),
  });

  final Rect cropRect;
  final List<Offset>? polygonVertices;
  final CropHandle? activeHandle;
  final int? activeVertexIndex;
  final int? selectedVertexIndex;
  final int? activeEdgeIndex;
  final bool emphasizeGrid;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _CropOverlayPainter(
        cropRect: cropRect,
        polygonVertices: polygonVertices,
        activeHandle: activeHandle,
        activeVertexIndex: activeVertexIndex,
        selectedVertexIndex: selectedVertexIndex,
        activeEdgeIndex: activeEdgeIndex,
        emphasizeGrid: emphasizeGrid,
        accentColor: accentColor,
      ),
    );
  }
}

class _CropOverlayPainter extends CustomPainter {
  const _CropOverlayPainter({
    required this.cropRect,
    required this.polygonVertices,
    required this.activeHandle,
    required this.activeVertexIndex,
    required this.selectedVertexIndex,
    required this.activeEdgeIndex,
    required this.emphasizeGrid,
    required this.accentColor,
  });

  final Rect cropRect;
  final List<Offset>? polygonVertices;
  final CropHandle? activeHandle;
  final int? activeVertexIndex;
  final int? selectedVertexIndex;
  final int? activeEdgeIndex;
  final bool emphasizeGrid;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
    final poly = polygonVertices;
    if (poly != null && poly.length >= 3) {
      _paintPolygonOverlay(canvas, size, poly);
      return;
    }

    if (cropRect.isEmpty) return;

    // Dim everything outside the selected question area using Path difference
    // (safe without offscreen saveLayer).
    final outerPath = Path()..addRect(Offset.zero & size);
    final innerPath = Path()..addRect(cropRect);
    final maskPath =
        Path.combine(PathOperation.difference, outerPath, innerPath);
    canvas.drawPath(
      maskPath,
      Paint()..color = Colors.black.withValues(alpha: 0.62),
    );

    // Composition / leveling grid inside the crop box (denser and brighter
    // while adjusting fine rotation angle so text lines are easy to level).
    final divisions = emphasizeGrid ? 6 : 3;
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: emphasizeGrid ? 0.50 : 0.30)
      ..strokeWidth = emphasizeGrid ? 0.9 : 0.8;
    for (var i = 1; i < divisions; i++) {
      final dx = cropRect.left + cropRect.width * i / divisions;
      canvas.drawLine(
        Offset(dx, cropRect.top),
        Offset(dx, cropRect.bottom),
        gridPaint,
      );
      final dy = cropRect.top + cropRect.height * i / divisions;
      canvas.drawLine(
        Offset(cropRect.left, dy),
        Offset(cropRect.right, dy),
        gridPaint,
      );
    }

    // Keep border, L-corners, and pill handles crisply visible even when the
    // crop rect sits flush at 100% screen edges (x = 0 or x = size.width).
    const handleInset = 2.4;
    final maxX = math.max(handleInset, size.width - handleInset);
    final maxY = math.max(handleInset, size.height - handleInset);
    final visualRect = Rect.fromLTRB(
      cropRect.left.clamp(handleInset, maxX),
      cropRect.top.clamp(handleInset, maxY),
      cropRect.right.clamp(handleInset, maxX),
      cropRect.bottom.clamp(handleInset, maxY),
    );

    // Crisp selection border.
    final isDragging = activeHandle != null;
    final borderPaint = Paint()
      ..color = isDragging ? accentColor : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawRect(visualRect, borderPaint);

    // L-shaped corner brackets.
    final arm = math.min(
      20.0,
      math.min(visualRect.width, visualRect.height) * 0.35,
    );
    _drawCorner(
      canvas,
      corner: visualRect.topLeft,
      dirX: 1,
      dirY: 1,
      arm: arm,
      active: activeHandle == CropHandle.topLeft,
    );
    _drawCorner(
      canvas,
      corner: visualRect.topRight,
      dirX: -1,
      dirY: 1,
      arm: arm,
      active: activeHandle == CropHandle.topRight,
    );
    _drawCorner(
      canvas,
      corner: visualRect.bottomLeft,
      dirX: 1,
      dirY: -1,
      arm: arm,
      active: activeHandle == CropHandle.bottomLeft,
    );
    _drawCorner(
      canvas,
      corner: visualRect.bottomRight,
      dirX: -1,
      dirY: -1,
      arm: arm,
      active: activeHandle == CropHandle.bottomRight,
    );

    // Centered edge pill bars (top, bottom, left, right) signaling free edge
    // resizing.
    final hBarHalf = math.min(16.0, math.max(6.0, visualRect.width * 0.16));
    final vBarHalf = math.min(16.0, math.max(6.0, visualRect.height * 0.16));

    _drawEdgeBar(
      canvas,
      center: Offset(visualRect.center.dx, visualRect.top),
      horizontal: true,
      halfLength: hBarHalf,
      active: activeHandle == CropHandle.top,
    );
    _drawEdgeBar(
      canvas,
      center: Offset(visualRect.center.dx, visualRect.bottom),
      horizontal: true,
      halfLength: hBarHalf,
      active: activeHandle == CropHandle.bottom,
    );
    _drawEdgeBar(
      canvas,
      center: Offset(visualRect.left, visualRect.center.dy),
      horizontal: false,
      halfLength: vBarHalf,
      active: activeHandle == CropHandle.left,
    );
    _drawEdgeBar(
      canvas,
      center: Offset(visualRect.right, visualRect.center.dy),
      horizontal: false,
      halfLength: vBarHalf,
      active: activeHandle == CropHandle.right,
    );
  }

  void _paintPolygonOverlay(Canvas canvas, Size size, List<Offset> poly) {
    final outerPath = Path()..addRect(Offset.zero & size);
    final innerPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addPolygon(poly, true);
    final maskPath =
        Path.combine(PathOperation.difference, outerPath, innerPath);
    canvas.drawPath(
      maskPath,
      Paint()..color = Colors.black.withValues(alpha: 0.64),
    );

    // Optional leveling grid clipped inside the polygon when adjusting angle.
    if (emphasizeGrid) {
      canvas.save();
      canvas.clipPath(innerPath);
      final bounds = innerPath.getBounds();
      final gridPaint = Paint()
        ..color = Colors.white.withValues(alpha: 0.44)
        ..strokeWidth = 0.85;
      const divisions = 6;
      for (var i = 1; i < divisions; i++) {
        final dx = bounds.left + bounds.width * i / divisions;
        canvas.drawLine(
          Offset(dx, bounds.top),
          Offset(dx, bounds.bottom),
          gridPaint,
        );
        final dy = bounds.top + bounds.height * i / divisions;
        canvas.drawLine(
          Offset(bounds.left, dy),
          Offset(bounds.right, dy),
          gridPaint,
        );
      }
      canvas.restore();
    }

    // Subtle dark outer halo under polygon edges for contrast over white paper.
    final haloPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 3.6;
    canvas.drawPath(innerPath, haloPaint);

    final isInteracting = activeVertexIndex != null || activeEdgeIndex != null;
    final edgePaint = Paint()
      ..color = isInteracting ? accentColor : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 2.0;
    canvas.drawPath(innerPath, edgePaint);

    // Highlight active edge segment if user is sliding a whole edge.
    if (activeEdgeIndex != null &&
        activeEdgeIndex! >= 0 &&
        activeEdgeIndex! < poly.length) {
      final a = poly[activeEdgeIndex!];
      final b = poly[(activeEdgeIndex! + 1) % poly.length];
      canvas.drawLine(
        a,
        b,
        Paint()
          ..color = accentColor
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round,
      );
    }

    // Map-style midpoint `+` handles for inserting new vertices (clipped to
    // the visible segment on screen so zoomed-in long edges always show `+`).
    if (poly.length < kMaxPolygonVertices) {
      for (var i = 0; i < poly.length; i++) {
        final a = poly[i];
        final b = poly[(i + 1) % poly.length];
        final vis = computeVisibleEdgeMidpoint(
          a: a,
          b: b,
          viewportSize: size,
          inset: 9.0,
          minVisibleLength: kMinEdgeLengthForMidpoint,
        );
        if (vis == null) continue;
        _drawMidpointAddHandle(canvas, vis.midpoint);
      }
    }

    // Primary circular vertex handles (`●`).
    for (var i = 0; i < poly.length; i++) {
      final center = _clampHandleToCanvas(poly[i], size, inset: 10.0);
      final isActive = i == activeVertexIndex;
      final isSelected = i == selectedVertexIndex;
      _drawPolygonVertex(
        canvas,
        center: center,
        active: isActive,
        selected: isSelected,
      );
    }
  }

  Offset _clampHandleToCanvas(Offset pt, Size size, {required double inset}) {
    final maxX = math.max(inset, size.width - inset);
    final maxY = math.max(inset, size.height - inset);
    // Only inset-clamp vertices sitting right on [0..size] edges; let panned
    // off-screen vertices scroll cleanly outside the viewport.
    if (pt.dx < -1.0 ||
        pt.dx > size.width + 1.0 ||
        pt.dy < -1.0 ||
        pt.dy > size.height + 1.0) {
      return pt;
    }
    return Offset(
      pt.dx.clamp(inset, maxX),
      pt.dy.clamp(inset, maxY),
    );
  }

  void _drawMidpointAddHandle(Canvas canvas, Offset center) {
    const radius = 8.2;
    canvas.drawCircle(
      center,
      radius + 1.2,
      Paint()..color = Colors.black.withValues(alpha: 0.42),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()..color = const Color(0xEB1E2433),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.88)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );
    const arm = 3.6;
    final plusPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(center.dx - arm, center.dy),
      Offset(center.dx + arm, center.dy),
      plusPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - arm),
      Offset(center.dx, center.dy + arm),
      plusPaint,
    );
  }

  void _drawPolygonVertex(
    Canvas canvas, {
    required Offset center,
    required bool active,
    required bool selected,
  }) {
    final outerRadius = active ? 11.5 : (selected ? 10.5 : 9.2);
    final innerRadius = active ? 6.2 : (selected ? 5.6 : 4.6);

    canvas.drawCircle(
      center,
      outerRadius + 1.6,
      Paint()..color = Colors.black.withValues(alpha: 0.45),
    );
    canvas.drawCircle(
      center,
      outerRadius,
      Paint()..color = Colors.white,
    );
    canvas.drawCircle(
      center,
      innerRadius,
      Paint()
        ..color = (active || selected) ? const Color(0xFFF59E0B) : accentColor,
    );
  }

  void _drawCorner(
    Canvas canvas, {
    required Offset corner,
    required double dirX,
    required double dirY,
    required double arm,
    required bool active,
  }) {
    final paint = Paint()
      ..color = active ? accentColor : Colors.white
      ..strokeWidth = active ? 4.5 : 3.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path()
      ..moveTo(corner.dx + dirX * arm, corner.dy)
      ..lineTo(corner.dx, corner.dy)
      ..lineTo(corner.dx, corner.dy + dirY * arm);
    canvas.drawPath(path, paint);
  }

  void _drawEdgeBar(
    Canvas canvas, {
    required Offset center,
    required bool horizontal,
    required double halfLength,
    required bool active,
  }) {
    const thickness = 4.2;
    final rect = horizontal
        ? Rect.fromCenter(
            center: center,
            width: halfLength * 2,
            height: thickness,
          )
        : Rect.fromCenter(
            center: center,
            width: thickness,
            height: halfLength * 2,
          );
    final paint = Paint()
      ..color = active ? accentColor : Colors.white
      ..style = PaintingStyle.fill;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(thickness / 2)),
      paint,
    );
  }

  @override
  bool shouldRepaint(_CropOverlayPainter oldDelegate) {
    return oldDelegate.cropRect != cropRect ||
        oldDelegate.polygonVertices != polygonVertices ||
        oldDelegate.activeHandle != activeHandle ||
        oldDelegate.activeVertexIndex != activeVertexIndex ||
        oldDelegate.selectedVertexIndex != selectedVertexIndex ||
        oldDelegate.activeEdgeIndex != activeEdgeIndex ||
        oldDelegate.emphasizeGrid != emphasizeGrid ||
        oldDelegate.accentColor != accentColor;
  }
}
