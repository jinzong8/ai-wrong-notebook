import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/camera_capture_session.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/image_crop_processor.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/widgets/crop_angle_control.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/widgets/free_crop_canvas.dart';
import 'package:uuid/uuid.dart';

/// Checks AI service configuration and navigates straight into the integrated
/// camera + free-crop screen, skipping any intermediate camera/gallery modal.
Future<void> openCameraCaptureFlow(BuildContext context, WidgetRef ref) async {
  final router = GoRouter.maybeOf(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final hasScaffold = Scaffold.maybeOf(context) != null;

  final config =
      await ref.read(settingsRepositoryProvider).getAiProviderConfig();
  if (!context.mounted) return;
  if (config == null ||
      config.baseUrl.isEmpty ||
      config.apiKey.isEmpty ||
      config.model.isEmpty) {
    if (hasScaffold) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(
        SnackBar(
          content: const Text('请先在设置中配置 AI 服务'),
          action: router == null
              ? null
              : SnackBarAction(
                  label: '去设置',
                  onPressed: () => router.go('/settings/provider'),
                ),
        ),
      );
    }
    return;
  }

  router?.go('/capture/camera');
}

/// Computes the centered single-question framing guide rectangle inside the
/// live viewfinder: 100% viewport width with an approximate 4:1 aspect ratio.
Rect computeViewfinderGuideRect(Size viewportSize) {
  if (viewportSize.width <= 0 || viewportSize.height <= 0) {
    return Rect.zero;
  }
  final width = viewportSize.width;
  final height = (width / 4.0)
      .clamp(
        math.min(56.0, viewportSize.height * 0.5),
        viewportSize.height * 0.55,
      )
      .toDouble();
  final top = (viewportSize.height - height) / 2.0;
  return Rect.fromLTWH(0, top, width, height);
}

/// Maps the live viewfinder's 100%-width ~4:1 framing guide into normalized
/// `[0, 1]` coordinates of the captured upright photo so pressing the shutter
/// selects the exact area the user aimed at (WYSIWYG).
Rect computeAimedCropRect({
  required Size previewViewportSize,
  required Size capturedImageSize,
}) {
  if (capturedImageSize.width <= 0 || capturedImageSize.height <= 0) {
    return fullNormalizedCropRect;
  }
  final effectiveViewport =
      (previewViewportSize.width > 0 && previewViewportSize.height > 0)
          ? previewViewportSize
          : capturedImageSize;
  final guideRect = computeViewfinderGuideRect(effectiveViewport);
  final displayRect = computeWidthFilledImageRect(
    viewportSize: effectiveViewport,
    imageSize: capturedImageSize,
  );
  if (guideRect.isEmpty || displayRect.width <= 0 || displayRect.height <= 0) {
    return fullNormalizedCropRect;
  }

  final left =
      ((guideRect.left - displayRect.left) / displayRect.width).clamp(0.0, 1.0);
  final right = ((guideRect.right - displayRect.left) / displayRect.width)
      .clamp(0.0, 1.0);
  final top =
      ((guideRect.top - displayRect.top) / displayRect.height).clamp(0.0, 1.0);
  final bottom = ((guideRect.bottom - displayRect.top) / displayRect.height)
      .clamp(0.0, 1.0);

  if (right - left < 0.1 || bottom - top < 0.05) {
    return fullNormalizedCropRect;
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

enum _CaptureStage {
  initializing,
  preview,
  cropping,
  error,
}

/// Integrated full-screen camera + WYSIWYG in-place free-form question cropper.
///
/// The live viewfinder spans 100% screen width with a centered 4:1 guide frame.
/// Pressing the shutter freezes the photo in place at the exact same 100% width
/// with the crop handles initialized directly to the aimed 4:1 region so the
/// user can immediately confirm or freely adjust all four edges and tilt angle.
class CameraCaptureCropScreen extends ConsumerStatefulWidget {
  const CameraCaptureCropScreen({super.key});

  @override
  ConsumerState<CameraCaptureCropScreen> createState() =>
      _CameraCaptureCropScreenState();
}

class _CameraCaptureCropScreenState
    extends ConsumerState<CameraCaptureCropScreen> with WidgetsBindingObserver {
  CameraCaptureSession? _session;
  int _initEpoch = 0;
  _CaptureStage _stage = _CaptureStage.initializing;
  CaptureFlashMode _flashMode = CaptureFlashMode.off;

  bool _capturing = false;
  bool _saving = false;
  bool _pickingExternal = false;
  String? _errorMessage;

  File? _capturedFile;
  bool _capturedFileOwnedTemp = false;
  String? _existingRecordId;
  Subject _subject = Subject.unknown;
  ui.Image? _capturedImage;
  bool _fromLiveViewfinder = true;
  Size _lastPreviewViewportSize = Size.zero;
  Rect _initialCropRect = fullNormalizedCropRect;
  Rect _cropRect = fullNormalizedCropRect;
  int _quarterTurns = 0;
  double _fineRotationDegrees = 0.0;
  bool _adjustingAngle = false;

  Offset? _focusIndicatorPosition;
  Timer? _focusIndicatorTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initCamera();
    });
  }

  @override
  void dispose() {
    _initEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    _focusIndicatorTimer?.cancel();
    _capturedImage?.dispose();
    _deleteTempFileIfOwned(_capturedFile, _capturedFileOwnedTemp);
    unawaited(_session?.dispose());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_pickingExternal) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _initEpoch++;
      final session = _session;
      _session = null;
      unawaited(session?.dispose());
    } else if (state == AppLifecycleState.resumed) {
      if ((_stage == _CaptureStage.preview ||
              _stage == _CaptureStage.initializing) &&
          _session == null) {
        unawaited(_initCamera());
      }
    }
  }

  Future<void> _initCamera() async {
    final epoch = ++_initEpoch;
    final previous = _session;
    _session = null;
    if (previous != null) {
      await previous.dispose();
    }

    if (!mounted || epoch != _initEpoch) return;
    setState(() {
      _stage = _CaptureStage.initializing;
      _errorMessage = null;
    });

    final factory = ref.read(cameraCaptureSessionFactoryProvider);
    final session = factory();
    try {
      await session.initialize();
      if (!mounted || epoch != _initEpoch) {
        await session.dispose();
        return;
      }
      setState(() {
        _session = session;
        _flashMode = session.flashMode;
        _stage = _CaptureStage.preview;
      });
    } catch (e) {
      await session.dispose();
      if (!mounted || epoch != _initEpoch) return;
      final raw = e.toString();
      final message = raw.toLowerCase().contains('denied') ||
              raw.toLowerCase().contains('permission')
          ? '相机权限未开启，请在系统设置中允许访问相机，或改用系统相机/相册。'
          : '无法启动内置相机，可直接改用系统相机或从相册选图。';
      setState(() {
        _errorMessage = message;
        _stage = _CaptureStage.error;
      });
    }
  }

  Future<void> _capturePhoto() async {
    final session = _session;
    if (session == null || !session.isInitialized || _capturing) return;

    setState(() => _capturing = true);
    File? rawFile;
    try {
      rawFile = await session.takePicture();
      if (!mounted) {
        _deleteTempFileIfOwned(rawFile, true);
        return;
      }
      unawaited(session.pausePreview());
      await _enterCropWithFile(
        rawFile,
        ownedTemp: true,
        fromLiveViewfinder: true,
        existingRecordId: null,
        subject: Subject.unknown,
      );
    } catch (e) {
      _deleteTempFileIfOwned(rawFile, true);
      unawaited(session.resumePreview());
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('拍照失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _enterCropWithFile(
    File file, {
    required bool ownedTemp,
    required bool fromLiveViewfinder,
    required String? existingRecordId,
    required Subject subject,
  }) async {
    final decoded = await decodeImageForCrop(file);
    if (!mounted) {
      decoded.dispose();
      _deleteTempFileIfOwned(file, ownedTemp);
      return;
    }

    final initialCrop = fromLiveViewfinder
        ? computeAimedCropRect(
            previewViewportSize: _lastPreviewViewportSize,
            capturedImageSize: Size(
              decoded.width.toDouble(),
              decoded.height.toDouble(),
            ),
          )
        : fullNormalizedCropRect;

    final previousFile = _capturedFile;
    final previousOwned = _capturedFileOwnedTemp;
    _capturedImage?.dispose();

    setState(() {
      _capturedFile = file;
      _capturedFileOwnedTemp = ownedTemp;
      _existingRecordId = existingRecordId;
      _subject = subject;
      _capturedImage = decoded;
      _fromLiveViewfinder = fromLiveViewfinder;
      _initialCropRect = initialCrop;
      _cropRect = initialCrop;
      _quarterTurns = 0;
      _fineRotationDegrees = 0.0;
      _adjustingAngle = false;
      _stage = _CaptureStage.cropping;
    });

    if (previousFile != null && previousFile.path != file.path) {
      _deleteTempFileIfOwned(previousFile, previousOwned);
    }
  }

  Future<void> _retake() async {
    if (_saving) return;
    final oldFile = _capturedFile;
    final oldOwned = _capturedFileOwnedTemp;
    _capturedImage?.dispose();
    _capturedImage = null;
    _capturedFile = null;
    _capturedFileOwnedTemp = false;
    _existingRecordId = null;
    _deleteTempFileIfOwned(oldFile, oldOwned);

    final session = _session;
    if (session != null && session.isInitialized) {
      await session.resumePreview();
      if (!mounted) return;
      setState(() {
        _initialCropRect = fullNormalizedCropRect;
        _cropRect = fullNormalizedCropRect;
        _quarterTurns = 0;
        _fineRotationDegrees = 0.0;
        _adjustingAngle = false;
        _stage = _CaptureStage.preview;
      });
    } else {
      await _initCamera();
    }
  }

  Future<void> _cycleFlash() async {
    final session = _session;
    if (session == null || !session.isInitialized || _capturing) return;
    final next = await session.cycleFlashMode();
    if (!mounted) return;
    setState(() => _flashMode = next);
  }

  Future<void> _handleTapToFocus(
    TapDownDetails details, {
    required Rect previewRect,
  }) async {
    final session = _session;
    if (session == null ||
        !session.isInitialized ||
        previewRect.width <= 0 ||
        previewRect.height <= 0) {
      return;
    }

    final local = details.localPosition;
    final normalized = Offset(
      ((local.dx - previewRect.left) / previewRect.width).clamp(0.0, 1.0),
      ((local.dy - previewRect.top) / previewRect.height).clamp(0.0, 1.0),
    );
    setState(() => _focusIndicatorPosition = local);
    _focusIndicatorTimer?.cancel();
    _focusIndicatorTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(() => _focusIndicatorPosition = null);
    });
    await session.setFocusPoint(normalized);
  }

  Future<void> _pickExternal({required bool fromCamera}) async {
    if (_capturing || _saving || _pickingExternal) return;
    _pickingExternal = true;
    final session = _session;
    unawaited(session?.pausePreview());

    try {
      final capture = ref.read(captureServiceProvider);
      final result = fromCamera
          ? await capture.pickFromCamera()
          : await capture.pickFromGallery();
      if (!mounted) return;

      if (result.isCancelled) {
        if (_stage == _CaptureStage.preview) {
          unawaited(session?.resumePreview());
        }
        return;
      }

      if (result.errorMessage != null) {
        if (_stage == _CaptureStage.preview) {
          unawaited(session?.resumePreview());
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('获取图片失败：${result.errorMessage}')),
        );
        return;
      }

      final record = result.record;
      if (record != null) {
        await _enterCropWithFile(
          File(record.imagePath),
          ownedTemp: false,
          fromLiveViewfinder: false,
          existingRecordId: record.id,
          subject: record.subject,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败：$e')),
        );
      }
    } finally {
      _pickingExternal = false;
    }
  }

  void _rotate({required bool clockwise}) {
    if (_capturedImage == null || _saving) return;
    setState(() {
      _quarterTurns = (_quarterTurns + (clockwise ? 1 : 3)) % 4;
      _cropRect = rotateNormalizedCropRect(_cropRect, clockwise: clockwise);
    });
  }

  void _resetCrop() {
    if (_capturedImage == null || _saving) return;
    setState(() {
      _quarterTurns = 0;
      _fineRotationDegrees = 0.0;
      _adjustingAngle = false;
      _cropRect = _initialCropRect;
    });
  }

  void _setFineRotation(double degrees) {
    if (_capturedImage == null || _saving) return;
    setState(() => _fineRotationDegrees = degrees);
  }

  Future<void> _submitFullOriginal() async {
    await _submitCaptured(forceOriginal: true);
  }

  Future<void> _confirmCrop() async {
    await _submitCaptured(forceOriginal: false);
  }

  Future<void> _submitCaptured({required bool forceOriginal}) async {
    final file = _capturedFile;
    final image = _capturedImage;
    if (file == null || image == null || _saving) return;

    setState(() {
      _adjustingAngle = false;
      _saving = true;
    });
    File? croppedTempFile;
    try {
      final storage = ref.read(imageStorageServiceProvider);
      final String savedPath;

      final useOriginal = forceOriginal ||
          (_quarterTurns == 0 &&
              _fineRotationDegrees.abs() < 0.05 &&
              isEffectivelyFullCrop(_cropRect));
      if (useOriginal) {
        savedPath = _capturedFileOwnedTemp
            ? await storage.saveImage(file)
            : file.path;
      } else {
        final jpgBytes = await cropAndEncodeJpg(
          sourceImage: image,
          quarterTurns: _quarterTurns,
          fineRotationDegrees: _fineRotationDegrees,
          normalizedCropRect: _cropRect,
        );
        if (!mounted) return;
        croppedTempFile = File(
          '${Directory.systemTemp.path}/camera_crop_${DateTime.now().microsecondsSinceEpoch}.jpg',
        );
        await croppedTempFile.writeAsBytes(jpgBytes, flush: true);
        savedPath = await storage.saveImage(croppedTempFile);
      }

      if (!mounted) return;

      final record = QuestionRecord.draft(
        id: _existingRecordId ?? const Uuid().v4(),
        imagePath: savedPath,
        subject: _subject,
        recognizedText: '',
      ).copyWith(contentStatus: ContentStatus.processing);
      ref.read(currentQuestionProvider.notifier).state = record;

      final session = _session;
      _session = null;
      await session?.dispose();
      if (!mounted) return;
      context.go('/analysis/loading');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
      setState(() => _saving = false);
    } finally {
      _deleteTempFileIfOwned(croppedTempFile, true);
    }
  }

  void _deleteTempFileIfOwned(File? file, bool owned) {
    if (!owned || file == null) return;
    try {
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    const surfaceBg = Color(0xFF0E1117);
    const barBg = Color(0xFF161B22);
    final isCropping = _stage == _CaptureStage.cropping;

    return Scaffold(
      backgroundColor: surfaceBg,
      appBar: AppBar(
        toolbarHeight: 48,
        backgroundColor: barBg,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        actionsIconTheme: const IconThemeData(color: Colors.white),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        elevation: 0,
        title: Text(
          isCropping ? '框选题目' : '拍照框选',
          style: const TextStyle(color: Colors.white),
        ),
        leading: isCropping
            ? TextButton.icon(
                key: const Key('crop-retake-button'),
                onPressed: _saving ? null : _retake,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.only(left: 8),
                ),
                icon: const Icon(
                  CupertinoIcons.camera,
                  size: 17,
                  color: Colors.white,
                ),
                label: const Text('重拍'),
              )
            : IconButton(
                key: const Key('camera-back-button'),
                tooltip: '返回',
                icon: const Icon(CupertinoIcons.xmark, color: Colors.white),
                onPressed: _capturing ? null : () => context.go('/'),
              ),
        leadingWidth: isCropping ? 88 : 56,
        actions: <Widget>[
          if (isCropping)
            TextButton(
              key: const Key('crop-use-original'),
              onPressed: _saving ? null : _submitFullOriginal,
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              child: const Text('用原图'),
            )
          else if (_stage == _CaptureStage.preview)
            IconButton(
              key: const Key('camera-flash-button'),
              tooltip: _flashMode.label,
              icon: Icon(_flashIcon(_flashMode), color: Colors.white),
              onPressed: _capturing ? null : _cycleFlash,
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                _buildStageContent(),
                if (_stage == _CaptureStage.preview ||
                    _stage == _CaptureStage.cropping)
                  Positioned(
                    top: 10,
                    left: 16,
                    right: 16,
                    child: IgnorePointer(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.48),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            _buildHintText(isCropping),
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white70,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          _buildBottomBar(barBg),
        ],
      ),
    );
  }

  String _buildHintText(bool isCropping) {
    if (!isCropping) {
      return '将题目对准中间框拍照，拍完按此范围框选并可微调';
    }
    if (_fromLiveViewfinder) {
      return '已按取景范围框选，拖动四边或四角可微调';
    }
    return '拖动四边或四角自由框选单道题，不限宽高比';
  }

  IconData _flashIcon(CaptureFlashMode mode) => switch (mode) {
        CaptureFlashMode.off => CupertinoIcons.bolt_slash,
        CaptureFlashMode.auto => CupertinoIcons.bolt_badge_a,
        CaptureFlashMode.torch => CupertinoIcons.bolt_fill,
      };

  Widget _buildStageContent() {
    switch (_stage) {
      case _CaptureStage.initializing:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CircularProgressIndicator(color: Colors.white),
              SizedBox(height: 16),
              Text('正在打开相机...', style: TextStyle(color: Colors.white70)),
            ],
          ),
        );
      case _CaptureStage.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(
                  CupertinoIcons.camera_fill,
                  size: 44,
                  color: Colors.white54,
                ),
                const SizedBox(height: 14),
                Text(
                  _errorMessage ?? '相机暂不可用',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, height: 1.5),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: <Widget>[
                    FilledButton.icon(
                      key: const Key('camera-error-system-camera'),
                      onPressed: () => _pickExternal(fromCamera: true),
                      icon: const Icon(CupertinoIcons.camera, size: 17),
                      label: const Text('使用系统相机'),
                    ),
                    OutlinedButton.icon(
                      key: const Key('camera-error-gallery'),
                      onPressed: () => _pickExternal(fromCamera: false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                      ),
                      icon: const Icon(CupertinoIcons.photo, size: 17),
                      label: const Text('从相册选择'),
                    ),
                    TextButton(
                      key: const Key('camera-retry-button'),
                      onPressed: _initCamera,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white70,
                      ),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      case _CaptureStage.preview:
        final session = _session;
        if (session == null || !session.isInitialized) {
          return const SizedBox.shrink();
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final viewport = constraints.biggest;
            _lastPreviewViewportSize = viewport;
            final previewAspect = session.previewAspectRatio;
            final previewWidth = viewport.width;
            final previewHeight = (previewAspect != null && previewAspect > 0)
                ? previewWidth / previewAspect
                : viewport.height;
            final previewTop = (viewport.height - previewHeight) / 2.0;

            return GestureDetector(
              key: const Key('camera-preview-surface'),
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) => _handleTapToFocus(
                details,
                previewRect: Rect.fromLTWH(
                  0,
                  previewTop,
                  previewWidth,
                  previewHeight,
                ),
              ),
              child: SizedBox.expand(
                child: Stack(
                  alignment: Alignment.center,
                  children: <Widget>[
                    Positioned.fill(
                      child: ClipRect(
                        child: OverflowBox(
                          alignment: Alignment.center,
                          minWidth: previewWidth,
                          maxWidth: previewWidth,
                          minHeight: previewHeight,
                          maxHeight: previewHeight,
                          child: session.buildPreview(),
                        ),
                      ),
                    ),
                    Positioned.fill(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _ViewfinderGuidePainter(),
                        ),
                      ),
                    ),
                    if (_focusIndicatorPosition != null)
                      Positioned(
                        left: _focusIndicatorPosition!.dx - 24,
                        top: _focusIndicatorPosition!.dy - 24,
                        child: IgnorePointer(
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              border: Border.all(
                                color: const Color(0xFF818CF8),
                                width: 2,
                              ),
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                    if (_capturing)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(width: 8),
                            Text(
                              '定格中...',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        );
      case _CaptureStage.cropping:
        final image = _capturedImage;
        if (image == null) return const SizedBox.shrink();
        return FreeCropCanvas(
          image: image,
          quarterTurns: _quarterTurns,
          fineRotationDegrees: _fineRotationDegrees,
          emphasizeGrid: _adjustingAngle,
          fillWidth: _fromLiveViewfinder,
          cropRect: _cropRect,
          enabled: !_saving,
          onCropRectChanged: (next) => setState(() => _cropRect = next),
        );
    }
  }

  Widget _buildBottomBar(Color barBg) {
    const primaryAccent = Color(0xFF6366F1);

    if (_stage == _CaptureStage.cropping) {
      return Container(
        color: barBg,
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              CropAngleControl(
                angleDegrees: _fineRotationDegrees,
                enabled: !_saving,
                onChangeStart: () => setState(() => _adjustingAngle = true),
                onChangeEnd: () => setState(() => _adjustingAngle = false),
                onChanged: _setFineRotation,
              ),
              Divider(
                height: 1,
                color: Colors.white.withValues(alpha: 0.08),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
                child: Row(
                  children: <Widget>[
                    _ActionIconLabel(
                      key: const Key('crop-rotate-left'),
                      icon: CupertinoIcons.rotate_left,
                      label: '左旋',
                      onPressed:
                          _saving ? null : () => _rotate(clockwise: false),
                    ),
                    const SizedBox(width: 4),
                    _ActionIconLabel(
                      key: const Key('crop-rotate-right'),
                      icon: CupertinoIcons.rotate_right,
                      label: '右旋',
                      onPressed:
                          _saving ? null : () => _rotate(clockwise: true),
                    ),
                    const SizedBox(width: 4),
                    _ActionIconLabel(
                      key: const Key('crop-reset'),
                      icon: CupertinoIcons.arrow_counterclockwise,
                      label: '重置',
                      onPressed: _saving ? null : _resetCrop,
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      key: const Key('crop-confirm'),
                      style: FilledButton.styleFrom(
                        backgroundColor: primaryAccent,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                      ),
                      onPressed: _saving ? null : _confirmCrop,
                      icon: _saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(CupertinoIcons.checkmark_alt, size: 18),
                      label: Text(_saving ? '处理中...' : '开始分析'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_stage != _CaptureStage.preview) {
      return const SizedBox.shrink();
    }

    return Container(
      color: barBg,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 18),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              _ActionIconLabel(
                key: const Key('camera-gallery-button'),
                icon: CupertinoIcons.photo,
                label: '相册',
                onPressed: _capturing
                    ? null
                    : () => _pickExternal(fromCamera: false),
              ),
              GestureDetector(
                key: const Key('camera-shutter-button'),
                onTap: _capturing ? null : _capturePhoto,
                child: Container(
                  width: 72,
                  height: 72,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3.5),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _capturing ? Colors.white54 : Colors.white,
                    ),
                  ),
                ),
              ),
              _ActionIconLabel(
                key: const Key('camera-system-button'),
                icon: CupertinoIcons.camera_viewfinder,
                label: '系统相机',
                onPressed: _capturing
                    ? null
                    : () => _pickExternal(fromCamera: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionIconLabel extends StatelessWidget {
  const _ActionIconLabel({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final color = onPressed != null ? Colors.white : Colors.white38;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 21, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }
}

class _ViewfinderGuidePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final guideRect = computeViewfinderGuideRect(size);
    if (guideRect.isEmpty) return;

    // Light translucent veil above & below the 4:1 band so the single-question
    // framing zone stands out clearly while keeping surrounding lines readable.
    final outerPath = Path()..addRect(Offset.zero & size);
    final innerPath = Path()..addRect(guideRect);
    final maskPath =
        Path.combine(PathOperation.difference, outerPath, innerPath);
    canvas.drawPath(
      maskPath,
      Paint()..color = Colors.black.withValues(alpha: 0.24),
    );

    // Subtle inset so 100%-width vertical borders and corner strokes stay crisp.
    const edgeInset = 2.0;
    final left = guideRect.left + edgeInset;
    final right = math.max(left, guideRect.right - edgeInset);
    final top = guideRect.top;
    final bottom = guideRect.bottom;
    final visualRect = Rect.fromLTRB(left, top, right, bottom);

    // Crisp framing outline spanning 100% viewport width at ~4:1 ratio.
    canvas.drawRect(
      visualRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke,
    );

    // Subtle horizontal level line through the vertical center of the 4:1 box.
    canvas.drawLine(
      Offset(left + 16, visualRect.center.dy),
      Offset(right - 16, visualRect.center.dy),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.16)
        ..strokeWidth = 0.8,
    );

    // Highlighted corner brackets at all four corners of the 4:1 guide box.
    final arm = math.min(20.0, visualRect.height * 0.28);
    final cornerPaint = Paint()
      ..color = const Color(0xFFA5B4FC).withValues(alpha: 0.90)
      ..strokeWidth = 2.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawLine(Offset(left, top + arm), Offset(left, top), cornerPaint);
    canvas.drawLine(Offset(left, top), Offset(left + arm, top), cornerPaint);
    canvas.drawLine(Offset(right - arm, top), Offset(right, top), cornerPaint);
    canvas.drawLine(Offset(right, top), Offset(right, top + arm), cornerPaint);
    canvas.drawLine(
      Offset(left, bottom - arm),
      Offset(left, bottom),
      cornerPaint,
    );
    canvas.drawLine(
      Offset(left, bottom),
      Offset(left + arm, bottom),
      cornerPaint,
    );
    canvas.drawLine(
      Offset(right - arm, bottom),
      Offset(right, bottom),
      cornerPaint,
    );
    canvas.drawLine(
      Offset(right, bottom - arm),
      Offset(right, bottom),
      cornerPaint,
    );

    // Small center alignment dot.
    canvas.drawCircle(
      visualRect.center,
      2.4,
      Paint()..color = const Color(0xFFA5B4FC).withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
