import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/widgets/crop_overlay.dart';

/// Full-width (0 horizontal padding) crop canvas margin with a small vertical
/// buffer so top/bottom edge handles remain comfortably clear of toolbars.
const EdgeInsets kCropCanvasPadding = EdgeInsets.symmetric(vertical: 10);

enum _CanvasGestureMode {
  none,
  cropHandle,
  polygonHandle,
  imageTransform,
}

/// Interactive free-form image cropping surface with:
/// - Independent 4-edge, 4-corner, and interior dragging (zero aspect-ratio lock)
/// - Two-finger pinch-to-zoom (`0.5x`..`5.0x`) around the focal point & image panning
/// - Map-style arbitrary polygon mode (automatically activated on pinch zoom-in
///   `>= 1.15x` or via the `多边形` toggle chip) with vertex dragging (`●`),
///   edge-midpoint `+` vertex insertion (`⊕`), parallel edge sliding, edge
///   auto-panning when dragging a vertex to the viewport border, and
///   double-tap / button vertex deletion
/// - Real-time fine-angle straightening preview
class FreeCropCanvas extends StatefulWidget {
  const FreeCropCanvas({
    super.key,
    required this.image,
    required this.quarterTurns,
    required this.cropRect,
    required this.onCropRectChanged,
    this.cropPolygon,
    this.onCropPolygonChanged,
    this.fineRotationDegrees = 0.0,
    this.emphasizeGrid = false,
    this.fillWidth = false,
    this.resetSignal = 0,
    this.onInteractionStart,
    this.enabled = true,
    this.padding = kCropCanvasPadding,
  });

  final ui.Image image;
  final int quarterTurns;
  final Rect cropRect;
  final ValueChanged<Rect> onCropRectChanged;

  /// Optional normalized `[0..1, 0..1]` polygon vertices when the user sculpts
  /// an irregular cutout (e.g. L-shape / T-shape to exclude neighboring exam
  /// questions). `null` means standard axis-aligned [cropRect].
  final List<Offset>? cropPolygon;
  final ValueChanged<List<Offset>?>? onCropPolygonChanged;

  final double fineRotationDegrees;
  final bool emphasizeGrid;

  /// When `true`, scales the image to fill 100% of the viewport width (clipping
  /// excess height symmetrically if taller than the viewport) so camera capture
  /// transitions into cropping at the exact same full-width scale.
  final bool fillWidth;

  /// Incrementing this counter resets image zoom, pan, and polygon back to
  /// `1.0x` rectangle mode.
  final int resetSignal;
  final VoidCallback? onInteractionStart;
  final bool enabled;
  final EdgeInsets padding;

  @override
  State<FreeCropCanvas> createState() => _FreeCropCanvasState();
}

class _FreeCropCanvasState extends State<FreeCropCanvas> {
  double _zoom = 1.0;
  Offset _pan = Offset.zero;
  Rect? _desiredScreenCropRect;
  Rect? _lastEmittedCropRect;
  Size? _lastViewportSize;

  CropHandle? _activeHandle;
  _CanvasGestureMode _gestureMode = _CanvasGestureMode.none;

  // Polygon selection & edge auto-pan state.
  bool? _polygonModeOverride;
  List<Offset>? _customPolygon;
  List<Offset>? _lastEmittedPolygon;
  PolygonHitKind? _activePolygonHitKind;
  int? _activeVertexIndex;
  int? _selectedVertexIndex;
  int? _activeEdgeIndex;
  List<Offset>? _preSingleFingerPolygon;
  List<Offset>? _preTouchCustomPolygon;
  Offset _vertexGrabOffset = Offset.zero;
  Offset _lastDragFocalPoint = Offset.zero;
  Timer? _autoPanTimer;
  Size _autoPanViewport = Size.zero;
  Rect _autoPanBaseDisplayRect = Rect.zero;
  double _autoPanMinZoom = kMinCropZoom;
  int? _lastTapVertexIndex;
  DateTime? _lastTapVertexTime;
  DateTime? _firstPointerDownTime;

  final Set<int> _downPointers = <int>{};
  bool _hadMultiTouchInSession = false;
  Offset? _firstPointerDownLocal;

  double _scaleStartZoom = 1.0;
  Rect _scaleStartDisplayRect = Rect.zero;
  Offset _scaleStartFocalPoint = Offset.zero;
  Rect? _preSingleFingerDesiredCropRect;
  Rect? _preSingleFingerNormalizedCropRect;
  double _singleFingerTravel = 0.0;

  @override
  void initState() {
    super.initState();
    if (widget.cropPolygon != null &&
        widget.cropPolygon!.length >= kMinPolygonVertices) {
      _customPolygon = List<Offset>.of(widget.cropPolygon!);
    }
  }

  @override
  void dispose() {
    _stopAutoPan();
    super.dispose();
  }

  void _stopAutoPan() {
    _autoPanTimer?.cancel();
    _autoPanTimer = null;
  }

  @override
  void didUpdateWidget(covariant FreeCropCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    final imageOrTurnChanged = oldWidget.image != widget.image ||
        oldWidget.quarterTurns != widget.quarterTurns;
    final explicitReset = oldWidget.resetSignal != widget.resetSignal;
    final externalCropChanged = oldWidget.cropRect != widget.cropRect &&
        widget.cropRect != _lastEmittedCropRect;
    final externalPolygonChanged =
        oldWidget.cropPolygon != widget.cropPolygon &&
            !_samePolygon(widget.cropPolygon, _lastEmittedPolygon);

    if (explicitReset) {
      _stopAutoPan();
      _zoom = 1.0;
      _pan = Offset.zero;
      _desiredScreenCropRect = null;
      _lastEmittedCropRect = null;
      _activeHandle = null;
      _polygonModeOverride = null;
      _customPolygon = null;
      _lastEmittedPolygon = null;
      _activePolygonHitKind = null;
      _activeVertexIndex = null;
      _selectedVertexIndex = null;
      _activeEdgeIndex = null;
      _gestureMode = _CanvasGestureMode.none;
    } else if (imageOrTurnChanged || externalCropChanged) {
      _zoom = 1.0;
      _pan = Offset.zero;
      _desiredScreenCropRect = null;
      _lastEmittedCropRect = null;
      _activeHandle = null;
      _activePolygonHitKind = null;
      _activeVertexIndex = null;
      _selectedVertexIndex = null;
      _activeEdgeIndex = null;
      _gestureMode = _CanvasGestureMode.none;
      _customPolygon = (widget.cropPolygon != null &&
              widget.cropPolygon!.length >= kMinPolygonVertices)
          ? List<Offset>.of(widget.cropPolygon!)
          : null;
    } else if (externalPolygonChanged) {
      _customPolygon = (widget.cropPolygon != null &&
              widget.cropPolygon!.length >= kMinPolygonVertices)
          ? List<Offset>.of(widget.cropPolygon!)
          : null;
    } else if (!widget.enabled) {
      _activeHandle = null;
      _activePolygonHitKind = null;
      _activeVertexIndex = null;
      _activeEdgeIndex = null;
      _gestureMode = _CanvasGestureMode.none;
      _downPointers.clear();
      _hadMultiTouchInSession = false;
      _firstPointerDownLocal = null;
    }
  }

  static bool _samePolygon(List<Offset>? a, List<Offset>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _formatZoom(double zoom) {
    final rounded = (zoom * 10).round() / 10.0;
    if ((rounded - rounded.roundToDouble()).abs() < 1e-6) {
      return '${rounded.round()}×';
    }
    return '${rounded.toStringAsFixed(1)}×';
  }

  void _emitCropRectIfChanged(Rect nextNormalized) {
    if (_lastEmittedCropRect == nextNormalized &&
        widget.cropRect == nextNormalized) {
      return;
    }
    _lastEmittedCropRect = nextNormalized;
    widget.onCropRectChanged(nextNormalized);
  }

  void _emitCropPolygonIfChanged(List<Offset>? nextPolygon) {
    final callback = widget.onCropPolygonChanged;
    if (callback == null) return;
    if (_samePolygon(_lastEmittedPolygon, nextPolygon) &&
        _samePolygon(widget.cropPolygon, nextPolygon)) {
      return;
    }
    _lastEmittedPolygon =
        nextPolygon == null ? null : List<Offset>.unmodifiable(nextPolygon);
    callback(_lastEmittedPolygon);
  }

  void _emitPolygonAndBounds(List<Offset> nextPolygon) {
    final bounds = computePolygonBounds(nextPolygon);
    _emitCropRectIfChanged(bounds);
    _emitCropPolygonIfChanged(nextPolygon);
  }

  void _resetZoom({
    required Size viewport,
    required Rect baseDisplayRect,
    required Rect anchorCropRect,
  }) {
    if (!widget.enabled) return;
    final hasCustomPoly =
        _customPolygon != null && _customPolygon!.length >= kMinPolygonVertices;
    if (hasCustomPoly) {
      // Preserve the user's sculpted polygon while zooming back to 1.0x so
      // they can inspect the full irregular cutout before confirming.
      setState(() {
        _zoom = 1.0;
        _pan = Offset.zero;
        _activeHandle = null;
        _activeVertexIndex = null;
        _activeEdgeIndex = null;
        _gestureMode = _CanvasGestureMode.none;
      });
      return;
    }

    final resetAllowed = computeAllowedScreenCropBounds(
      viewportSize: viewport,
      displayRect: baseDisplayRect,
      padding: widget.padding,
    );
    final resetScreenCrop = clampScreenCropRect(
      anchorCropRect,
      bounds: resetAllowed,
    );
    final nextNormalized = displayToNormalizedCropRect(
      resetScreenCrop,
      baseDisplayRect,
    );
    setState(() {
      _zoom = 1.0;
      _pan = Offset.zero;
      _desiredScreenCropRect = resetScreenCrop;
      _activeHandle = null;
      _gestureMode = _CanvasGestureMode.none;
    });
    _emitCropRectIfChanged(nextNormalized);
  }

  void _togglePolygonMode({
    required bool currentlyActive,
    required Rect currentNormalizedCrop,
    required Rect displayRect,
    required Size viewport,
  }) {
    if (!widget.enabled) return;
    widget.onInteractionStart?.call();
    if (currentlyActive) {
      // Switch back to orthogonal rectangle using current bounding box.
      final rect = _customPolygon != null
          ? computePolygonBounds(_customPolygon!)
          : currentNormalizedCrop;
      final allowed = computeAllowedScreenCropBounds(
        viewportSize: viewport,
        displayRect: displayRect,
        padding: widget.padding,
      );
      final screenRect = clampScreenCropRect(
        normalizedToDisplayRect(rect, displayRect),
        bounds: allowed,
      );
      setState(() {
        _polygonModeOverride = false;
        _customPolygon = null;
        _selectedVertexIndex = null;
        _activeVertexIndex = null;
        _activeEdgeIndex = null;
        _desiredScreenCropRect = screenRect;
      });
      _emitCropRectIfChanged(rect);
      _emitCropPolygonIfChanged(null);
    } else {
      final initialPoly = rectToPolygonVertices(currentNormalizedCrop);
      setState(() {
        _polygonModeOverride = true;
        _customPolygon = initialPoly;
        _selectedVertexIndex = null;
      });
      _emitPolygonAndBounds(initialPoly);
    }
  }

  void _deleteVertexAt(int index) {
    final poly = _customPolygon;
    if (!widget.enabled ||
        poly == null ||
        poly.length <= kMinPolygonVertices ||
        index < 0 ||
        index >= poly.length) {
      return;
    }
    widget.onInteractionStart?.call();
    final nextPoly = List<Offset>.of(poly)..removeAt(index);
    setState(() {
      _customPolygon = nextPoly;
      _selectedVertexIndex = null;
      _activeVertexIndex = null;
      _lastTapVertexIndex = null;
      _lastTapVertexTime = null;
    });
    _emitPolygonAndBounds(nextPoly);
  }

  static Offset _computeEdgeAutoPanStep({
    required Offset fingerPos,
    required Size viewport,
    double edgeZone = 36.0,
    double maxSpeedPxPerTick = 11.0,
  }) {
    if (viewport.isEmpty) return Offset.zero;
    var dx = 0.0;
    var dy = 0.0;

    if (fingerPos.dx < edgeZone) {
      final t = ((edgeZone - fingerPos.dx) / edgeZone).clamp(0.0, 1.0);
      dx = maxSpeedPxPerTick * t;
    } else if (fingerPos.dx > viewport.width - edgeZone) {
      final t = ((fingerPos.dx - (viewport.width - edgeZone)) / edgeZone)
          .clamp(0.0, 1.0);
      dx = -maxSpeedPxPerTick * t;
    }

    if (fingerPos.dy < edgeZone) {
      final t = ((edgeZone - fingerPos.dy) / edgeZone).clamp(0.0, 1.0);
      dy = maxSpeedPxPerTick * t;
    } else if (fingerPos.dy > viewport.height - edgeZone) {
      final t = ((fingerPos.dy - (viewport.height - edgeZone)) / edgeZone)
          .clamp(0.0, 1.0);
      dy = -maxSpeedPxPerTick * t;
    }

    return Offset(dx, dy);
  }

  void _tickEdgeAutoPan() {
    if (!mounted ||
        !widget.enabled ||
        _downPointers.isEmpty ||
        _gestureMode != _CanvasGestureMode.polygonHandle ||
        _activePolygonHitKind != PolygonHitKind.vertex ||
        _activeVertexIndex == null ||
        _customPolygon == null) {
      _stopAutoPan();
      return;
    }

    final viewport = _autoPanViewport;
    final baseDisplayRect = _autoPanBaseDisplayRect;
    final step = _computeEdgeAutoPanStep(
      fingerPos: _lastDragFocalPoint,
      viewport: viewport,
    );
    if (step == Offset.zero) {
      _stopAutoPan();
      return;
    }

    final clampedZoom = _zoom.clamp(_autoPanMinZoom, kMaxCropZoom);
    final candidateRaw = Rect.fromCenter(
      center: baseDisplayRect.center + _pan + step,
      width: baseDisplayRect.width * clampedZoom,
      height: baseDisplayRect.height * clampedZoom,
    );
    final nextDisplayRect = clampFreePanDisplayRect(
      rawDisplayRect: candidateRaw,
      viewportSize: viewport,
    );
    final nextPan = nextDisplayRect.center - baseDisplayRect.center;
    if ((nextPan - _pan).distance < 0.05) {
      // Reached the edge of the exam photo — nothing left to scroll.
      _stopAutoPan();
      return;
    }

    final allowed = computeAllowedScreenCropBounds(
      viewportSize: viewport,
      displayRect: nextDisplayRect,
      padding: widget.padding,
    );
    final targetScreen = _lastDragFocalPoint + _vertexGrabOffset;
    final clampedScreen = Offset(
      targetScreen.dx.clamp(allowed.left, allowed.right),
      targetScreen.dy.clamp(allowed.top, allowed.bottom),
    );
    final nextNorm = displayPointToNormalized(clampedScreen, nextDisplayRect);
    final vIdx = _activeVertexIndex!;
    final basePoly = _customPolygon!;
    if (vIdx >= basePoly.length) {
      _stopAutoPan();
      return;
    }
    final candidatePoly = List<Offset>.of(basePoly)..[vIdx] = nextNorm;
    final validArea = computePolygonArea(candidatePoly) >= 1e-4;

    setState(() {
      _pan = nextPan;
      if (validArea) {
        _customPolygon = candidatePoly;
      }
    });
    if (validArea) {
      _emitPolygonAndBounds(candidatePoly);
    }
  }

  void _syncEdgeAutoPan({
    required Size viewport,
    required Rect baseDisplayRect,
    required double minZoom,
    required bool isZoomed,
  }) {
    if (!isZoomed ||
        _downPointers.isEmpty ||
        _gestureMode != _CanvasGestureMode.polygonHandle ||
        _activePolygonHitKind != PolygonHitKind.vertex ||
        _activeVertexIndex == null) {
      _stopAutoPan();
      return;
    }
    _autoPanViewport = viewport;
    _autoPanBaseDisplayRect = baseDisplayRect;
    _autoPanMinZoom = minZoom;

    final step = _computeEdgeAutoPanStep(
      fingerPos: _lastDragFocalPoint,
      viewport: viewport,
    );
    if (step == Offset.zero) {
      _stopAutoPan();
      return;
    }
    _autoPanTimer ??= Timer.periodic(
      const Duration(milliseconds: 16),
      (_) => _tickEdgeAutoPan(),
    );
  }

  void _handlePassiveTap({
    required Offset localPosition,
    required Size viewport,
    required bool isPolygonMode,
    required List<Offset>? screenPolygon,
    required List<Offset>? activeNormPoly,
  }) {
    if (!isPolygonMode || screenPolygon == null || activeNormPoly == null) {
      return;
    }
    // Ignore taps on the floating polygon control chips so chip taps never
    // accidentally double-tap a vertex underneath.
    if (localPosition.dy >= 36 &&
        localPosition.dy <= 82 &&
        localPosition.dx < 250) {
      return;
    }

    final hit = hitTestPolygonHandle(
      position: localPosition,
      screenVertices: screenPolygon,
      viewportSize: viewport,
    );
    if (hit?.kind == PolygonHitKind.vertex) {
      final now = DateTime.now();
      final isDoubleTap = _lastTapVertexIndex == hit!.index &&
          _lastTapVertexTime != null &&
          now.difference(_lastTapVertexTime!) <=
              const Duration(milliseconds: 380);
      if (isDoubleTap && activeNormPoly.length > kMinPolygonVertices) {
        _customPolygon ??= List<Offset>.of(activeNormPoly);
        _deleteVertexAt(hit.index);
      } else {
        setState(() {
          _customPolygon ??= List<Offset>.of(activeNormPoly);
          _selectedVertexIndex = hit.index;
          _lastTapVertexIndex = hit.index;
          _lastTapVertexTime = now;
        });
      }
    } else if (_selectedVertexIndex != null) {
      setState(() {
        _selectedVertexIndex = null;
      });
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
        final viewport = constraints.biggest;
        final baseDisplayRect = widget.fillWidth
            ? computeWidthFilledImageRect(
                viewportSize: viewport,
                imageSize: orientedSize,
              )
            : computeFittedImageRect(
                viewportSize: viewport,
                imageSize: orientedSize,
                padding: widget.padding,
              );
        final fittedDisplayRect = computeFittedImageRect(
          viewportSize: viewport,
          imageSize: orientedSize,
          padding: widget.padding,
        );
        final containZoom = baseDisplayRect.width > 0
            ? fittedDisplayRect.width / baseDisplayRect.width
            : 1.0;
        final minZoom = math.min(kMinCropZoom, containZoom);

        if (_desiredScreenCropRect == null || _lastViewportSize != viewport) {
          _lastViewportSize = viewport;
          final currentZoom = _zoom.clamp(minZoom, kMaxCropZoom);
          final provisionalDisplayRect = Rect.fromCenter(
            center: baseDisplayRect.center + _pan,
            width: baseDisplayRect.width * currentZoom,
            height: baseDisplayRect.height * currentZoom,
          );
          final allowed = computeAllowedScreenCropBounds(
            viewportSize: viewport,
            displayRect: provisionalDisplayRect,
            padding: widget.padding,
          );
          final mapped = normalizedToDisplayRect(
            widget.cropRect,
            provisionalDisplayRect,
          );
          _desiredScreenCropRect = clampScreenCropRect(mapped, bounds: allowed);
        }

        final viewportOnlyBounds = computeViewportCropBounds(
          viewportSize: viewport,
          padding: widget.padding,
        );
        final anchorCropRect = clampScreenCropRect(
          _desiredScreenCropRect!,
          bounds: viewportOnlyBounds,
        );
        final clampedZoom = _zoom.clamp(minZoom, kMaxCropZoom);
        final rawDisplayRect = Rect.fromCenter(
          center: baseDisplayRect.center + _pan,
          width: baseDisplayRect.width * clampedZoom,
          height: baseDisplayRect.height * clampedZoom,
        );

        final hasCustomPolygon = _customPolygon != null &&
            _customPolygon!.length >= kMinPolygonVertices;
        final displayRect = hasCustomPolygon
            ? clampFreePanDisplayRect(
                rawDisplayRect: rawDisplayRect,
                viewportSize: viewport,
              )
            : clampZoomedDisplayRect(
                rawDisplayRect: rawDisplayRect,
                anchorCropRect: anchorCropRect,
              );

        final allowedScreenBounds = computeAllowedScreenCropBounds(
          viewportSize: viewport,
          displayRect: displayRect,
          padding: widget.padding,
        );
        final screenCropRect = clampScreenCropRect(
          anchorCropRect,
          bounds: allowedScreenBounds,
        );

        final isPolygonMode = hasCustomPolygon ||
            (_polygonModeOverride ??
                (clampedZoom >= kAutoPolygonZoomThreshold));

        final currentNormalizedCrop = hasCustomPolygon
            ? computePolygonBounds(_customPolygon!)
            : displayToNormalizedCropRect(screenCropRect, displayRect);

        final List<Offset>? activeNormPoly = isPolygonMode
            ? (hasCustomPolygon
                ? _customPolygon!
                : rectToPolygonVertices(currentNormalizedCrop))
            : null;
        final List<Offset>? screenPolygon = activeNormPoly != null
            ? normalizedPolygonToDisplay(activeNormPoly, displayRect)
            : null;

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

        final isZoomed = (clampedZoom - 1.0).abs() >= 0.03;
        final canDeleteSelectedVertex = isPolygonMode &&
            _selectedVertexIndex != null &&
            activeNormPoly != null &&
            activeNormPoly.length > kMinPolygonVertices &&
            _selectedVertexIndex! < activeNormPoly.length;

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: !widget.enabled
              ? null
              : (event) {
                  if (_downPointers.isEmpty) {
                    _firstPointerDownLocal = event.localPosition;
                    _firstPointerDownTime = DateTime.now();
                  }
                  _downPointers.add(event.pointer);
                  if (_downPointers.length >= 2) {
                    _hadMultiTouchInSession = true;
                  }
                },
          onPointerUp: (event) {
            _downPointers.remove(event.pointer);
            if (_downPointers.isEmpty) {
              _stopAutoPan();
              final downPos = _firstPointerDownLocal;
              final downTime = _firstPointerDownTime;
              final wasMulti = _hadMultiTouchInSession;
              _hadMultiTouchInSession = false;
              _firstPointerDownLocal = null;
              _firstPointerDownTime = null;

              if (!wasMulti &&
                  downPos != null &&
                  downTime != null &&
                  (event.localPosition - downPos).distance < 10.0 &&
                  DateTime.now().difference(downTime) <
                      const Duration(milliseconds: 300)) {
                _handlePassiveTap(
                  localPosition: event.localPosition,
                  viewport: viewport,
                  isPolygonMode: isPolygonMode,
                  screenPolygon: screenPolygon,
                  activeNormPoly: activeNormPoly,
                );
              }
            }
          },
          onPointerCancel: (event) {
            _downPointers.remove(event.pointer);
            if (_downPointers.isEmpty) {
              _stopAutoPan();
              _hadMultiTouchInSession = false;
              _firstPointerDownLocal = null;
              _firstPointerDownTime = null;
            }
          },
          child: GestureDetector(
            key: const Key('crop-canvas'),
            behavior: HitTestBehavior.opaque,
            onScaleStart: !widget.enabled
                ? null
                : (details) {
                    final isMultiTouch = details.pointerCount >= 2 ||
                        _hadMultiTouchInSession ||
                        _downPointers.length >= 2;

                    if (isMultiTouch) {
                      _stopAutoPan();
                      if (_gestureMode == _CanvasGestureMode.cropHandle &&
                          _singleFingerTravel < 48.0 &&
                          _preSingleFingerDesiredCropRect != null) {
                        _desiredScreenCropRect =
                            _preSingleFingerDesiredCropRect;
                        if (_preSingleFingerNormalizedCropRect != null) {
                          _emitCropRectIfChanged(
                            _preSingleFingerNormalizedCropRect!,
                          );
                        }
                      } else if (_gestureMode ==
                              _CanvasGestureMode.polygonHandle &&
                          _singleFingerTravel < 48.0) {
                        _customPolygon = _preTouchCustomPolygon == null
                            ? null
                            : List<Offset>.of(_preTouchCustomPolygon!);
                        if (_customPolygon != null) {
                          _emitPolygonAndBounds(_customPolygon!);
                        } else {
                          _emitCropPolygonIfChanged(null);
                        }
                      }
                      _scaleStartZoom = clampedZoom;
                      _scaleStartDisplayRect = displayRect;
                      _scaleStartFocalPoint = details.localFocalPoint;
                      widget.onInteractionStart?.call();
                      _activeHandle = null;
                      _activeVertexIndex = null;
                      _activeEdgeIndex = null;
                      _gestureMode = _CanvasGestureMode.imageTransform;
                      setState(() {});
                      return;
                    }

                    final touchOrigin =
                        _firstPointerDownLocal ?? details.localFocalPoint;

                    _preSingleFingerDesiredCropRect = screenCropRect;
                    _preSingleFingerNormalizedCropRect = widget.cropRect;
                    _preTouchCustomPolygon = _customPolygon == null
                        ? null
                        : List<Offset>.of(_customPolygon!);
                    _singleFingerTravel = 0.0;
                    _scaleStartZoom = clampedZoom;
                    _scaleStartDisplayRect = displayRect;
                    _scaleStartFocalPoint = touchOrigin;
                    _lastDragFocalPoint = touchOrigin;

                    if (isPolygonMode &&
                        screenPolygon != null &&
                        activeNormPoly != null) {
                      final polyHit = hitTestPolygonHandle(
                        position: touchOrigin,
                        screenVertices: screenPolygon,
                        viewportSize: viewport,
                      );

                      if (polyHit != null &&
                          !(polyHit.kind == PolygonHitKind.interior &&
                              (isZoomed || hasCustomPolygon))) {
                        widget.onInteractionStart?.call();
                        if (polyHit.kind == PolygonHitKind.midpoint) {
                          final i = polyHit.index;
                          final next = (i + 1) % activeNormPoly.length;
                          final midNorm = Offset.lerp(
                            activeNormPoly[i],
                            activeNormPoly[next],
                            polyHit.parameterT,
                          )!;
                          final midScreen = Offset(
                            displayRect.left + midNorm.dx * displayRect.width,
                            displayRect.top + midNorm.dy * displayRect.height,
                          );
                          final inserted = List<Offset>.of(activeNormPoly)
                            ..insert(i + 1, midNorm);
                          _preSingleFingerPolygon = inserted;
                          _customPolygon = List<Offset>.of(inserted);
                          _vertexGrabOffset = midScreen - touchOrigin;
                          _activePolygonHitKind = PolygonHitKind.vertex;
                          _activeVertexIndex = i + 1;
                          _selectedVertexIndex = i + 1;
                          _activeEdgeIndex = null;
                          _gestureMode = _CanvasGestureMode.polygonHandle;
                          setState(() {});
                          _emitPolygonAndBounds(_customPolygon!);
                          return;
                        }

                        _preSingleFingerPolygon =
                            List<Offset>.of(activeNormPoly);
                        _activePolygonHitKind = polyHit.kind;
                        if (polyHit.kind == PolygonHitKind.vertex) {
                          _activeVertexIndex = polyHit.index;
                          _selectedVertexIndex = polyHit.index;
                          _vertexGrabOffset =
                              screenPolygon[polyHit.index] - touchOrigin;
                          _activeEdgeIndex = null;
                        } else if (polyHit.kind == PolygonHitKind.edge) {
                          _activeEdgeIndex = polyHit.index;
                          _activeVertexIndex = null;
                        } else {
                          _activeVertexIndex = null;
                          _activeEdgeIndex = null;
                        }
                        _gestureMode = _CanvasGestureMode.polygonHandle;
                        setState(() {});
                        return;
                      }

                      widget.onInteractionStart?.call();
                      _activeHandle = null;
                      _activeVertexIndex = null;
                      _activeEdgeIndex = null;
                      _gestureMode = _CanvasGestureMode.imageTransform;
                      setState(() {});
                      return;
                    }

                    final handle = hitTestCropHandle(
                      position: touchOrigin,
                      screenCropRect: screenCropRect,
                    );

                    // When zoomed, dragging the interior of the crop window
                    // pans the zoomed photo right under the finger while
                    // corners and edges still resize the crop frame.
                    if (handle != null &&
                        !(handle == CropHandle.move && isZoomed)) {
                      widget.onInteractionStart?.call();
                      _activeHandle = handle;
                      _gestureMode = _CanvasGestureMode.cropHandle;
                      setState(() {});
                    } else {
                      widget.onInteractionStart?.call();
                      _activeHandle = null;
                      _gestureMode = _CanvasGestureMode.imageTransform;
                      setState(() {});
                    }
                  },
            onScaleUpdate: !widget.enabled
                ? null
                : (details) {
                    final isMultiTouch = details.pointerCount >= 2 ||
                        _hadMultiTouchInSession ||
                        _downPointers.length >= 2;

                    if (isMultiTouch &&
                        _gestureMode != _CanvasGestureMode.imageTransform) {
                      _stopAutoPan();
                      if (_gestureMode == _CanvasGestureMode.cropHandle &&
                          _singleFingerTravel < 48.0 &&
                          _preSingleFingerDesiredCropRect != null) {
                        _desiredScreenCropRect =
                            _preSingleFingerDesiredCropRect;
                      } else if (_gestureMode ==
                              _CanvasGestureMode.polygonHandle &&
                          _singleFingerTravel < 48.0) {
                        _customPolygon = _preTouchCustomPolygon == null
                            ? null
                            : List<Offset>.of(_preTouchCustomPolygon!);
                        if (_customPolygon != null) {
                          _emitPolygonAndBounds(_customPolygon!);
                        } else {
                          _emitCropPolygonIfChanged(null);
                        }
                      }
                      _activeHandle = null;
                      _activeVertexIndex = null;
                      _activeEdgeIndex = null;
                      _gestureMode = _CanvasGestureMode.imageTransform;
                      _scaleStartZoom = clampedZoom;
                      _scaleStartDisplayRect = displayRect;
                      _scaleStartFocalPoint = details.localFocalPoint;
                    }

                    if (_gestureMode == _CanvasGestureMode.polygonHandle &&
                        _preSingleFingerPolygon != null) {
                      _lastDragFocalPoint = details.localFocalPoint;
                      final totalDelta =
                          details.localFocalPoint - _scaleStartFocalPoint;
                      _singleFingerTravel = totalDelta.distance;
                      final basePoly = _preSingleFingerPolygon!;
                      final dxNorm = displayRect.width > 0
                          ? totalDelta.dx / displayRect.width
                          : 0.0;
                      final dyNorm = displayRect.height > 0
                          ? totalDelta.dy / displayRect.height
                          : 0.0;

                      List<Offset>? nextPoly;
                      if (_activePolygonHitKind == PolygonHitKind.vertex &&
                          _activeVertexIndex != null &&
                          _activeVertexIndex! < basePoly.length) {
                        final vIdx = _activeVertexIndex!;
                        final currentPoly = _customPolygon ?? basePoly;
                        final targetScreen =
                            details.localFocalPoint + _vertexGrabOffset;
                        final clampedScreen = Offset(
                          targetScreen.dx.clamp(
                            allowedScreenBounds.left,
                            allowedScreenBounds.right,
                          ),
                          targetScreen.dy.clamp(
                            allowedScreenBounds.top,
                            allowedScreenBounds.bottom,
                          ),
                        );
                        final clampedNorm = displayPointToNormalized(
                          clampedScreen,
                          displayRect,
                        );
                        final candidate = List<Offset>.of(currentPoly)
                          ..[vIdx] = clampedNorm;
                        if (computePolygonArea(candidate) >= 1e-4) {
                          nextPoly = candidate;
                        }
                        _syncEdgeAutoPan(
                          viewport: viewport,
                          baseDisplayRect: baseDisplayRect,
                          minZoom: minZoom,
                          isZoomed: clampedZoom > 1.02,
                        );
                      } else if (_activePolygonHitKind == PolygonHitKind.edge &&
                          _activeEdgeIndex != null &&
                          _activeEdgeIndex! < basePoly.length) {
                        final i = _activeEdgeIndex!;
                        final j = (i + 1) % basePoly.length;
                        final minDx = -math.min(basePoly[i].dx, basePoly[j].dx);
                        final maxDx =
                            1.0 - math.max(basePoly[i].dx, basePoly[j].dx);
                        final minDy = -math.min(basePoly[i].dy, basePoly[j].dy);
                        final maxDy =
                            1.0 - math.max(basePoly[i].dy, basePoly[j].dy);
                        final cdx = dxNorm.clamp(minDx, maxDx);
                        final cdy = dyNorm.clamp(minDy, maxDy);
                        final candidate = List<Offset>.of(basePoly);
                        candidate[i] =
                            Offset(basePoly[i].dx + cdx, basePoly[i].dy + cdy);
                        candidate[j] =
                            Offset(basePoly[j].dx + cdx, basePoly[j].dy + cdy);
                        if (computePolygonArea(candidate) >= 1e-4) {
                          nextPoly = candidate;
                        }
                      } else if (_activePolygonHitKind ==
                          PolygonHitKind.interior) {
                        var minX = 1.0, maxX = 0.0, minY = 1.0, maxY = 0.0;
                        for (final pt in basePoly) {
                          if (pt.dx < minX) minX = pt.dx;
                          if (pt.dx > maxX) maxX = pt.dx;
                          if (pt.dy < minY) minY = pt.dy;
                          if (pt.dy > maxY) maxY = pt.dy;
                        }
                        final cdx = dxNorm.clamp(-minX, 1.0 - maxX);
                        final cdy = dyNorm.clamp(-minY, 1.0 - maxY);
                        nextPoly = basePoly
                            .map((pt) => Offset(pt.dx + cdx, pt.dy + cdy))
                            .toList(growable: false);
                      }

                      if (nextPoly != null &&
                          !_samePolygon(nextPoly, _customPolygon)) {
                        setState(() {
                          _customPolygon = nextPoly;
                        });
                        _emitPolygonAndBounds(nextPoly);
                      }
                      return;
                    }

                    if (_gestureMode == _CanvasGestureMode.cropHandle &&
                        _activeHandle != null) {
                      final totalDelta =
                          details.localFocalPoint - _scaleStartFocalPoint;
                      _singleFingerTravel = totalDelta.distance;
                      final baseScreenCrop =
                          _preSingleFingerDesiredCropRect ?? screenCropRect;
                      final nextScreenCrop = applyScreenCropHandleDelta(
                        screenRect: baseScreenCrop,
                        handle: _activeHandle!,
                        delta: totalDelta,
                        bounds: allowedScreenBounds,
                      );
                      if (nextScreenCrop != _desiredScreenCropRect) {
                        final nextNormalized = displayToNormalizedCropRect(
                          nextScreenCrop,
                          displayRect,
                        );
                        setState(() {
                          _desiredScreenCropRect = nextScreenCrop;
                        });
                        _emitCropRectIfChanged(nextNormalized);
                      }
                      return;
                    }

                    if (_gestureMode == _CanvasGestureMode.imageTransform) {
                      final polyLocked = _customPolygon != null &&
                          _customPolygon!.length >= kMinPolygonVertices;

                      if (polyLocked) {
                        final nextZoom = (_scaleStartZoom * details.scale)
                            .clamp(minZoom, kMaxCropZoom);
                        final newW = baseDisplayRect.width * nextZoom;
                        final newH = baseDisplayRect.height * nextZoom;
                        final u = _scaleStartDisplayRect.width > 0
                            ? (_scaleStartFocalPoint.dx -
                                    _scaleStartDisplayRect.left) /
                                _scaleStartDisplayRect.width
                            : 0.5;
                        final v = _scaleStartDisplayRect.height > 0
                            ? (_scaleStartFocalPoint.dy -
                                    _scaleStartDisplayRect.top) /
                                _scaleStartDisplayRect.height
                            : 0.5;
                        final rawRect = Rect.fromLTWH(
                          details.localFocalPoint.dx - u * newW,
                          details.localFocalPoint.dy - v * newH,
                          newW,
                          newH,
                        );
                        final nextDisplayRect = clampFreePanDisplayRect(
                          rawDisplayRect: rawRect,
                          viewportSize: viewport,
                        );
                        final nextActualZoom = baseDisplayRect.width > 0
                            ? nextDisplayRect.width / baseDisplayRect.width
                            : 1.0;
                        final nextPan =
                            nextDisplayRect.center - baseDisplayRect.center;
                        if ((nextActualZoom - _zoom).abs() > 1e-5 ||
                            (nextPan - _pan).distance > 1e-3) {
                          setState(() {
                            _zoom = nextActualZoom;
                            _pan = nextPan;
                          });
                        }
                        return;
                      }

                      final activeAnchor = clampScreenCropRect(
                        _desiredScreenCropRect ?? anchorCropRect,
                        bounds: viewportOnlyBounds,
                      );
                      final nextDisplayRect = computeFocalZoomDisplayRect(
                        baseDisplayRect: baseDisplayRect,
                        startDisplayRect: _scaleStartDisplayRect,
                        startZoom: _scaleStartZoom,
                        startFocalPoint: _scaleStartFocalPoint,
                        currentFocalPoint: details.localFocalPoint,
                        scaleFactor: details.scale,
                        anchorCropRect: activeAnchor,
                        minZoom: minZoom,
                        maxZoom: kMaxCropZoom,
                      );
                      final nextZoom = baseDisplayRect.width > 0
                          ? nextDisplayRect.width / baseDisplayRect.width
                          : 1.0;
                      final nextPan =
                          nextDisplayRect.center - baseDisplayRect.center;
                      final nextAllowedBounds = computeAllowedScreenCropBounds(
                        viewportSize: viewport,
                        displayRect: nextDisplayRect,
                        padding: widget.padding,
                      );
                      final nextEffectiveScreenCrop = clampScreenCropRect(
                        activeAnchor,
                        bounds: nextAllowedBounds,
                      );
                      final nextNormalized = displayToNormalizedCropRect(
                        nextEffectiveScreenCrop,
                        nextDisplayRect,
                      );

                      if ((nextZoom - _zoom).abs() > 1e-5 ||
                          (nextPan - _pan).distance > 1e-3 ||
                          nextNormalized != _lastEmittedCropRect) {
                        setState(() {
                          _zoom = nextZoom;
                          _pan = nextPan;
                        });
                        _emitCropRectIfChanged(nextNormalized);
                      }
                    }
                  },
            onScaleEnd: (_) {
              _stopAutoPan();
              _gestureMode = _CanvasGestureMode.none;
              if (_activeHandle != null ||
                  _activeVertexIndex != null ||
                  _activeEdgeIndex != null) {
                setState(() {
                  _activeHandle = null;
                  _activeVertexIndex = null;
                  _activeEdgeIndex = null;
                });
              }
            },
            child: Stack(
              fit: StackFit.expand,
              clipBehavior: Clip.hardEdge,
              children: <Widget>[
                Positioned.fromRect(
                  rect: displayRect,
                  child: imageWidget,
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    child: CropOverlay(
                      cropRect: screenCropRect,
                      polygonVertices: screenPolygon,
                      activeHandle: _activeHandle,
                      activeVertexIndex: _activeVertexIndex,
                      selectedVertexIndex: _selectedVertexIndex,
                      activeEdgeIndex: _activeEdgeIndex,
                      emphasizeGrid: widget.emphasizeGrid,
                    ),
                  ),
                ),
                Positioned(
                  top: 42,
                  left: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Material(
                        color: isPolygonMode
                            ? const Color(0xE64F46E5)
                            : Colors.black.withValues(alpha: 0.56),
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          key: const Key('crop-polygon-toggle'),
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _togglePolygonMode(
                            currentlyActive: isPolygonMode,
                            currentNormalizedCrop: currentNormalizedCrop,
                            displayRect: displayRect,
                            viewport: viewport,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 5.5,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                Icon(
                                  isPolygonMode
                                      ? CupertinoIcons.skew
                                      : CupertinoIcons.crop,
                                  size: 13,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  isPolygonMode
                                      ? '多边形 · ${activeNormPoly?.length ?? 4}点'
                                      : '多边形',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      if (canDeleteSelectedVertex) ...<Widget>[
                        const SizedBox(width: 8),
                        Material(
                          color: const Color(0xDCBE123C),
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            key: const Key('crop-polygon-delete-vertex'),
                            borderRadius: BorderRadius.circular(16),
                            onTap: () => _deleteVertexAt(_selectedVertexIndex!),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5.5,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  Icon(
                                    CupertinoIcons.trash,
                                    size: 12,
                                    color: Colors.white,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    '删节点',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (isZoomed)
                  Positioned(
                    bottom: 12,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Material(
                        color: Colors.black.withValues(alpha: 0.56),
                        borderRadius: BorderRadius.circular(16),
                        child: InkWell(
                          key: const Key('crop-zoom-reset'),
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _resetZoom(
                            viewport: viewport,
                            baseDisplayRect: baseDisplayRect,
                            anchorCropRect: anchorCropRect,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 11,
                              vertical: 5,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: <Widget>[
                                const Icon(
                                  CupertinoIcons.arrow_counterclockwise,
                                  size: 12,
                                  color: Colors.white70,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  '${_formatZoom(clampedZoom)} · 还原',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
