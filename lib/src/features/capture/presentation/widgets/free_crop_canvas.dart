import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/widgets/crop_overlay.dart';

/// Full-width (0 horizontal padding) crop canvas margin with a small vertical
/// buffer so top/bottom edge handles remain comfortably clear of toolbars.
const EdgeInsets kCropCanvasPadding = EdgeInsets.symmetric(vertical: 10);

/// Interactive free-form image cropping surface with independent 4-edge,
/// 4-corner, and interior move dragging (zero aspect-ratio restriction), plus
/// real-time fine-angle straightening preview.
class FreeCropCanvas extends StatefulWidget {
  const FreeCropCanvas({
    super.key,
    required this.image,
    required this.quarterTurns,
    required this.cropRect,
    required this.onCropRectChanged,
    this.fineRotationDegrees = 0.0,
    this.emphasizeGrid = false,
    this.onInteractionStart,
    this.enabled = true,
    this.padding = kCropCanvasPadding,
  });

  final ui.Image image;
  final int quarterTurns;
  final Rect cropRect;
  final ValueChanged<Rect> onCropRectChanged;
  final double fineRotationDegrees;
  final bool emphasizeGrid;
  final VoidCallback? onInteractionStart;
  final bool enabled;
  final EdgeInsets padding;

  @override
  State<FreeCropCanvas> createState() => _FreeCropCanvasState();
}

class _FreeCropCanvasState extends State<FreeCropCanvas> {
  late Rect _cropRect;
  CropHandle? _activeHandle;

  @override
  void initState() {
    super.initState();
    _cropRect = widget.cropRect;
  }

  @override
  void didUpdateWidget(covariant FreeCropCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cropRect != widget.cropRect) {
      _cropRect = widget.cropRect;
    }
    if (oldWidget.quarterTurns != widget.quarterTurns ||
        oldWidget.image != widget.image ||
        !widget.enabled) {
      _activeHandle = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final orientedSize = widget.quarterTurns.isOdd
        ? Size(widget.image.height.toDouble(), widget.image.width.toDouble())
        : Size(widget.image.width.toDouble(), widget.image.height.toDouble());
    final fineRadians = widget.fineRotationDegrees * math.pi / 180.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final displayRect = computeFittedImageRect(
          viewportSize: constraints.biggest,
          imageSize: orientedSize,
          padding: widget.padding,
        );
        final screenCropRect =
            normalizedToDisplayRect(_cropRect, displayRect);

        Widget imageWidget = RotatedBox(
          quarterTurns: widget.quarterTurns,
          child: RawImage(
            image: widget.image,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.medium,
          ),
        );
        if (fineRadians.abs() > 1e-4) {
          imageWidget = ClipRect(
            child: Transform.rotate(
              angle: fineRadians,
              alignment: Alignment.center,
              child: imageWidget,
            ),
          );
        }

        return GestureDetector(
          key: const Key('crop-canvas'),
          behavior: HitTestBehavior.opaque,
          onPanStart: !widget.enabled
              ? null
              : (details) {
                  final handle = hitTestCropHandle(
                    position: details.localPosition,
                    screenCropRect: screenCropRect,
                  );
                  if (handle != null) {
                    widget.onInteractionStart?.call();
                    setState(() => _activeHandle = handle);
                  }
                },
          onPanUpdate: !widget.enabled
              ? null
              : (details) {
                  final handle = _activeHandle;
                  if (handle == null) return;
                  final next = applyCropHandleDelta(
                    normalizedRect: _cropRect,
                    handle: handle,
                    delta: details.delta,
                    displayRect: displayRect,
                  );
                  if (next != _cropRect) {
                    setState(() => _cropRect = next);
                    widget.onCropRectChanged(next);
                  }
                },
          onPanEnd: (_) {
            if (_activeHandle != null) {
              setState(() => _activeHandle = null);
            }
          },
          onPanCancel: () {
            if (_activeHandle != null) {
              setState(() => _activeHandle = null);
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Positioned.fromRect(
                rect: displayRect,
                child: imageWidget,
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CropOverlay(
                    cropRect: screenCropRect,
                    activeHandle: _activeHandle,
                    emphasizeGrid: widget.emphasizeGrid,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
