import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';

/// Visual overlay for free-form rectangular question selection.
///
/// Renders a dimmed surround, 3x3 framing guides, L-shaped corner brackets, and
/// centered edge drag bars on all four sides so users can immediately tell that
/// every border can be resized independently without aspect-ratio limits.
class CropOverlay extends StatelessWidget {
  const CropOverlay({
    super.key,
    required this.cropRect,
    this.activeHandle,
    this.accentColor = const Color(0xFF818CF8),
  });

  final Rect cropRect;
  final CropHandle? activeHandle;
  final Color accentColor;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _CropOverlayPainter(
        cropRect: cropRect,
        activeHandle: activeHandle,
        accentColor: accentColor,
      ),
    );
  }
}

class _CropOverlayPainter extends CustomPainter {
  const _CropOverlayPainter({
    required this.cropRect,
    required this.activeHandle,
    required this.accentColor,
  });

  final Rect cropRect;
  final CropHandle? activeHandle;
  final Color accentColor;

  @override
  void paint(Canvas canvas, Size size) {
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

    // Subtle 3x3 composition grid inside the crop box.
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.30)
      ..strokeWidth = 0.8;
    for (var i = 1; i <= 2; i++) {
      final dx = cropRect.left + cropRect.width * i / 3;
      canvas.drawLine(
        Offset(dx, cropRect.top),
        Offset(dx, cropRect.bottom),
        gridPaint,
      );
      final dy = cropRect.top + cropRect.height * i / 3;
      canvas.drawLine(
        Offset(cropRect.left, dy),
        Offset(cropRect.right, dy),
        gridPaint,
      );
    }

    // Crisp selection border.
    final isDragging = activeHandle != null;
    final borderPaint = Paint()
      ..color = isDragging ? accentColor : Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawRect(cropRect, borderPaint);

    // L-shaped corner brackets.
    final arm = math.min(
      20.0,
      math.min(cropRect.width, cropRect.height) * 0.35,
    );
    _drawCorner(
      canvas,
      corner: cropRect.topLeft,
      dirX: 1,
      dirY: 1,
      arm: arm,
      active: activeHandle == CropHandle.topLeft,
    );
    _drawCorner(
      canvas,
      corner: cropRect.topRight,
      dirX: -1,
      dirY: 1,
      arm: arm,
      active: activeHandle == CropHandle.topRight,
    );
    _drawCorner(
      canvas,
      corner: cropRect.bottomLeft,
      dirX: 1,
      dirY: -1,
      arm: arm,
      active: activeHandle == CropHandle.bottomLeft,
    );
    _drawCorner(
      canvas,
      corner: cropRect.bottomRight,
      dirX: -1,
      dirY: -1,
      arm: arm,
      active: activeHandle == CropHandle.bottomRight,
    );

    // Centered edge pill bars (top, bottom, left, right) signaling free edge
    // resizing.
    final hBarHalf = math.min(16.0, math.max(6.0, cropRect.width * 0.16));
    final vBarHalf = math.min(16.0, math.max(6.0, cropRect.height * 0.16));

    _drawEdgeBar(
      canvas,
      center: Offset(cropRect.center.dx, cropRect.top),
      horizontal: true,
      halfLength: hBarHalf,
      active: activeHandle == CropHandle.top,
    );
    _drawEdgeBar(
      canvas,
      center: Offset(cropRect.center.dx, cropRect.bottom),
      horizontal: true,
      halfLength: hBarHalf,
      active: activeHandle == CropHandle.bottom,
    );
    _drawEdgeBar(
      canvas,
      center: Offset(cropRect.left, cropRect.center.dy),
      horizontal: false,
      halfLength: vBarHalf,
      active: activeHandle == CropHandle.left,
    );
    _drawEdgeBar(
      canvas,
      center: Offset(cropRect.right, cropRect.center.dy),
      horizontal: false,
      halfLength: vBarHalf,
      active: activeHandle == CropHandle.right,
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
        oldDelegate.activeHandle != activeHandle ||
        oldDelegate.accentColor != accentColor;
  }
}
