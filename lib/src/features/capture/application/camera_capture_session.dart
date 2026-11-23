import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// Flash options exposed by the in-app camera capture screen.
enum CaptureFlashMode {
  off,
  auto,
  torch,
}

extension CaptureFlashModeLabel on CaptureFlashMode {
  String get label => switch (this) {
        CaptureFlashMode.off => '闪光灯关',
        CaptureFlashMode.auto => '自动闪光',
        CaptureFlashMode.torch => '补光灯开',
      };
}

/// Abstract live-camera controller used by `CameraCaptureCropScreen` so the UI
/// stays testable without real camera hardware.
abstract interface class CameraCaptureSession {
  bool get isInitialized;
  CaptureFlashMode get flashMode;

  Future<void> initialize();
  Widget buildPreview();
  Future<File> takePicture();
  Future<CaptureFlashMode> cycleFlashMode();
  Future<void> setFocusPoint(Offset normalizedPoint);
  Future<void> pausePreview();
  Future<void> resumePreview();
  Future<void> dispose();
}

typedef CameraCaptureSessionFactory = CameraCaptureSession Function();

/// Production implementation backed by Flutter's official `camera` plugin.
class PluginCameraCaptureSession implements CameraCaptureSession {
  CameraController? _controller;
  CaptureFlashMode _flashMode = CaptureFlashMode.off;
  bool _disposed = false;

  @override
  bool get isInitialized =>
      !_disposed && (_controller?.value.isInitialized ?? false);

  @override
  CaptureFlashMode get flashMode => _flashMode;

  @override
  Future<void> initialize() async {
    if (_disposed) return;

    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      throw CameraException('no_camera', '未检测到可用摄像头');
    }

    final selected = cameras.firstWhere(
      (camera) => camera.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );

    CameraController? controller;
    try {
      controller = CameraController(
        selected,
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
    } catch (e) {
      debugPrint(
        '[PluginCameraCaptureSession] veryHigh init failed ($e), retrying high',
      );
      await controller?.dispose();
      controller = CameraController(
        selected,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await controller.initialize();
    }

    if (_disposed) {
      await controller.dispose();
      return;
    }

    _controller = controller;
    try {
      await controller.setFlashMode(FlashMode.off);
      _flashMode = CaptureFlashMode.off;
    } catch (_) {
      // Some devices/front cameras do not support flash control.
    }
  }

  @override
  Widget buildPreview() {
    final controller = _controller;
    if (controller == null || !isInitialized) {
      return const SizedBox.shrink();
    }
    return CameraPreview(controller);
  }

  @override
  Future<File> takePicture() async {
    final controller = _controller;
    if (controller == null || !isInitialized) {
      throw StateError('相机尚未就绪');
    }
    final file = await controller.takePicture();
    return File(file.path);
  }

  @override
  Future<CaptureFlashMode> cycleFlashMode() async {
    final controller = _controller;
    if (controller == null || !isInitialized) return _flashMode;

    final next = switch (_flashMode) {
      CaptureFlashMode.off => CaptureFlashMode.auto,
      CaptureFlashMode.auto => CaptureFlashMode.torch,
      CaptureFlashMode.torch => CaptureFlashMode.off,
    };
    final pluginMode = switch (next) {
      CaptureFlashMode.off => FlashMode.off,
      CaptureFlashMode.auto => FlashMode.auto,
      CaptureFlashMode.torch => FlashMode.torch,
    };

    try {
      await controller.setFlashMode(pluginMode);
      _flashMode = next;
    } catch (e) {
      debugPrint('[PluginCameraCaptureSession] setFlashMode failed: $e');
    }
    return _flashMode;
  }

  @override
  Future<void> setFocusPoint(Offset normalizedPoint) async {
    final controller = _controller;
    if (controller == null || !isInitialized) return;
    final clamped = Offset(
      normalizedPoint.dx.clamp(0.0, 1.0),
      normalizedPoint.dy.clamp(0.0, 1.0),
    );
    try {
      await controller.setFocusPoint(clamped);
    } catch (_) {}
    try {
      await controller.setExposurePoint(clamped);
    } catch (_) {}
  }

  @override
  Future<void> pausePreview() async {
    final controller = _controller;
    if (controller == null || !isInitialized) return;
    try {
      await controller.pausePreview();
    } catch (_) {}
  }

  @override
  Future<void> resumePreview() async {
    final controller = _controller;
    if (controller == null || !isInitialized) return;
    try {
      await controller.resumePreview();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final controller = _controller;
    _controller = null;
    if (controller != null) {
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }
}
