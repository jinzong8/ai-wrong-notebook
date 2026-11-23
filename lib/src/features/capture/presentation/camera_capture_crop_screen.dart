import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/auto_question_crop_detector.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/camera_capture_session.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/image_crop_processor.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/widgets/free_crop_canvas.dart';
import 'package:uuid/uuid.dart';

enum _CaptureStage {
  initializing,
  preview,
  cropping,
  error,
}

/// Integrated full-screen camera + immediate in-place free-form question
/// cropper. After pressing the shutter button, the captured photo freezes in
/// place, runs fast local layout analysis to pre-select the center question,
/// and lets the user freely adjust all 4 edges/corners without ratio lock.
class CameraCaptureCropScreen extends ConsumerStatefulWidget {
  const CameraCaptureCropScreen({super.key});

  @override
  ConsumerState<CameraCaptureCropScreen> createState() =>
      _CameraCaptureCropScreenState();
}

class _CameraCaptureCropScreenState
    extends ConsumerState<CameraCaptureCropScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraCaptureSession? _session;
  int _initEpoch = 0;
  int _cropSessionEpoch = 0;
  _CaptureStage _stage = _CaptureStage.initializing;
  CaptureFlashMode _flashMode = CaptureFlashMode.off;

  bool _capturing = false;
  bool _saving = false;
  bool _pickingExternal = false;
  bool _autoDetecting = false;
  bool _autoDetectedApplied = false;
  bool _userAdjustedCrop = false;
  String? _errorMessage;

  File? _capturedFile;
  bool _capturedFileOwnedTemp = false;
  String? _existingRecordId;
  Subject _subject = Subject.unknown;
  ui.Image? _capturedImage;
  Rect _cropRect = fullNormalizedCropRect;
  int _quarterTurns = 0;

  late final AnimationController _cropAnimController;
  Animation<Rect?>? _cropRectAnimation;

  Offset? _focusIndicatorPosition;
  Timer? _focusIndicatorTimer;

  @override
  void initState() {
    super.initState();
    _cropAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(_onCropAnimationTick);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initCamera();
    });
  }

  @override
  void dispose() {
    _initEpoch++;
    _cropSessionEpoch++;
    _cropAnimController.dispose();
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

  void _onCropAnimationTick() {
    final value = _cropRectAnimation?.value;
    if (value != null && mounted) {
      setState(() => _cropRect = value);
    }
  }

  void _cancelCropAnimation() {
    if (_cropAnimController.isAnimating) {
      _cropAnimController.stop();
    }
    _cropRectAnimation = null;
  }

  void _animateCropRectTo(Rect target) {
    _cancelCropAnimation();
    _cropRectAnimation = RectTween(begin: _cropRect, end: target).animate(
      CurvedAnimation(
        parent: _cropAnimController,
        curve: Curves.easeOutCubic,
      ),
    );
    _cropAnimController.forward(from: 0);
  }

  Future<void> _enterCropWithFile(
    File file, {
    required bool ownedTemp,
    required String? existingRecordId,
    required Subject subject,
  }) async {
    final decoded = await decodeImageForCrop(file);
    if (!mounted) {
      decoded.dispose();
      _deleteTempFileIfOwned(file, ownedTemp);
      return;
    }

    _cancelCropAnimation();
    final previousFile = _capturedFile;
    final previousOwned = _capturedFileOwnedTemp;
    _capturedImage?.dispose();

    setState(() {
      _capturedFile = file;
      _capturedFileOwnedTemp = ownedTemp;
      _existingRecordId = existingRecordId;
      _subject = subject;
      _capturedImage = decoded;
      _cropRect = fullNormalizedCropRect;
      _quarterTurns = 0;
      _userAdjustedCrop = false;
      _autoDetectedApplied = false;
      _autoDetecting = true;
      _stage = _CaptureStage.cropping;
    });

    if (previousFile != null && previousFile.path != file.path) {
      _deleteTempFileIfOwned(previousFile, previousOwned);
    }

    unawaited(
      _runAutoDetectCenterQuestion(
        image: decoded,
        quarterTurns: 0,
        forceApply: false,
      ),
    );
  }

  Future<void> _runAutoDetectCenterQuestion({
    required ui.Image image,
    required int quarterTurns,
    required bool forceApply,
  }) async {
    final epoch = ++_cropSessionEpoch;
    if (mounted && !_autoDetecting) {
      setState(() => _autoDetecting = true);
    }

    Rect? detected;
    try {
      detected = await detectCenterQuestionCropRect(
        sourceImage: image,
        quarterTurns: quarterTurns,
      );
    } catch (e) {
      debugPrint('[CameraCaptureCropScreen] Auto crop detection failed: $e');
    }

    if (!mounted ||
        epoch != _cropSessionEpoch ||
        _stage != _CaptureStage.cropping) {
      return;
    }

    if (!forceApply && _userAdjustedCrop) {
      setState(() => _autoDetecting = false);
      return;
    }

    if (detected != null) {
      setState(() {
        _autoDetecting = false;
        _autoDetectedApplied = true;
        _userAdjustedCrop = false;
      });
      _animateCropRectTo(detected);
    } else {
      setState(() {
        _autoDetecting = false;
        _autoDetectedApplied = false;
      });
      if (forceApply) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('未检测到明显单题边界，请手动拖动四边微调'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  Future<void> _rerunAutoDetect() async {
    final image = _capturedImage;
    if (image == null || _saving || _autoDetecting) return;
    _cancelCropAnimation();
    await _runAutoDetectCenterQuestion(
      image: image,
      quarterTurns: _quarterTurns,
      forceApply: true,
    );
  }

  Future<void> _retake() async {
    if (_saving) return;
    _cropSessionEpoch++;
    _cancelCropAnimation();
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
        _cropRect = fullNormalizedCropRect;
        _quarterTurns = 0;
        _autoDetecting = false;
        _autoDetectedApplied = false;
        _userAdjustedCrop = false;
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
    TapDownDetails details,
    Size viewportSize,
  ) async {
    final session = _session;
    if (session == null ||
        !session.isInitialized ||
        viewportSize.width <= 0 ||
        viewportSize.height <= 0) {
      return;
    }

    final local = details.localPosition;
    final normalized = Offset(
      (local.dx / viewportSize.width).clamp(0.0, 1.0),
      (local.dy / viewportSize.height).clamp(0.0, 1.0),
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
    _cropSessionEpoch++;
    _cancelCropAnimation();
    setState(() {
      _autoDetecting = false;
      _userAdjustedCrop = true;
      _quarterTurns = (_quarterTurns + (clockwise ? 1 : 3)) % 4;
      _cropRect = rotateNormalizedCropRect(_cropRect, clockwise: clockwise);
    });
  }

  void _resetCrop() {
    if (_capturedImage == null || _saving) return;
    _cropSessionEpoch++;
    _cancelCropAnimation();
    setState(() {
      _autoDetecting = false;
      _autoDetectedApplied = false;
      _userAdjustedCrop = true;
      _quarterTurns = 0;
      _cropRect = fullNormalizedCropRect;
    });
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

    _cropSessionEpoch++;
    _cancelCropAnimation();
    setState(() {
      _autoDetecting = false;
      _saving = true;
    });
    File? croppedTempFile;
    try {
      final storage = ref.read(imageStorageServiceProvider);
      final String savedPath;

      final useOriginal = forceOriginal ||
          (_quarterTurns == 0 && isEffectivelyFullCrop(_cropRect));
      if (useOriginal) {
        savedPath = _capturedFileOwnedTemp
            ? await storage.saveImage(file)
            : file.path;
      } else {
        final jpgBytes = await cropAndEncodeJpg(
          sourceImage: image,
          quarterTurns: _quarterTurns,
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
        backgroundColor: barBg,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(isCropping ? '框选题目' : '拍照框选'),
        leading: isCropping
            ? TextButton.icon(
                key: const Key('crop-retake-button'),
                onPressed: _saving ? null : _retake,
                style: TextButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.only(left: 8),
                ),
                icon: const Icon(CupertinoIcons.camera, size: 17),
                label: const Text('重拍'),
              )
            : IconButton(
                key: const Key('camera-back-button'),
                tooltip: '返回',
                icon: const Icon(CupertinoIcons.xmark),
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
              icon: Icon(_flashIcon(_flashMode)),
              onPressed: _capturing ? null : _cycleFlash,
            ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            color: barBg,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Text(
              _buildHintText(isCropping),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ),
          Expanded(child: _buildStageContent()),
          _buildBottomBar(barBg),
        ],
      ),
    );
  }

  String _buildHintText(bool isCropping) {
    if (!isCropping) {
      return '将目标题目对准中心拍照，拍完自动框选并可微调';
    }
    if (_autoDetecting) {
      return '正在识别中间题目...';
    }
    if (_autoDetectedApplied && !_userAdjustedCrop) {
      return '已自动框选中间题目，拖动四边或四角可微调';
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
        return Padding(
          padding: kCropCanvasPadding,
          child: Center(
            child: Builder(
              builder: (previewContext) {
                return GestureDetector(
                  key: const Key('camera-preview-surface'),
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) {
                    final box = previewContext.findRenderObject() as RenderBox?;
                    if (box != null && box.hasSize) {
                      _handleTapToFocus(details, box.size);
                    }
                  },
                  child: Stack(
                    alignment: Alignment.center,
                    children: <Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: session.buildPreview(),
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
                );
              },
            ),
          ),
        );
      case _CaptureStage.cropping:
        final image = _capturedImage;
        if (image == null) return const SizedBox.shrink();
        return FreeCropCanvas(
          image: image,
          quarterTurns: _quarterTurns,
          cropRect: _cropRect,
          enabled: !_saving,
          onInteractionStart: () {
            _cancelCropAnimation();
            if (!_userAdjustedCrop) {
              setState(() => _userAdjustedCrop = true);
            }
          },
          onCropRectChanged: (next) {
            _cancelCropAnimation();
            setState(() {
              _userAdjustedCrop = true;
              _cropRect = next;
            });
          },
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 14, 12),
            child: Row(
              children: <Widget>[
                _ActionIconLabel(
                  key: const Key('crop-auto-select'),
                  icon: CupertinoIcons.viewfinder,
                  label: '自动',
                  onPressed:
                      (_saving || _autoDetecting) ? null : _rerunAutoDetect,
                ),
                const SizedBox(width: 2),
                _ActionIconLabel(
                  key: const Key('crop-rotate-left'),
                  icon: CupertinoIcons.rotate_left,
                  label: '左旋',
                  onPressed: _saving ? null : () => _rotate(clockwise: false),
                ),
                const SizedBox(width: 2),
                _ActionIconLabel(
                  key: const Key('crop-rotate-right'),
                  icon: CupertinoIcons.rotate_right,
                  label: '右旋',
                  onPressed: _saving ? null : () => _rotate(clockwise: true),
                ),
                const SizedBox(width: 2),
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
                      horizontal: 18,
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
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
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
    final guidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.20)
      ..strokeWidth = 0.8;
    // Subtle horizontal level lines to help align printed question lines.
    canvas.drawLine(
      Offset(12, size.height / 3),
      Offset(size.width - 12, size.height / 3),
      guidePaint,
    );
    canvas.drawLine(
      Offset(12, size.height * 2 / 3),
      Offset(size.width - 12, size.height * 2 / 3),
      guidePaint,
    );

    // Subtle center focus target showing which question will be auto-selected.
    final center = Offset(size.width / 2, size.height / 2);
    final halfW = (size.width * 0.16).clamp(24.0, 44.0);
    final halfH = (size.height * 0.05).clamp(14.0, 22.0);
    const arm = 10.0;
    final targetPaint = Paint()
      ..color = const Color(0xFFA5B4FC).withValues(alpha: 0.72)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final left = center.dx - halfW;
    final right = center.dx + halfW;
    final top = center.dy - halfH;
    final bottom = center.dy + halfH;

    // Four subtle center corner brackets.
    canvas.drawLine(Offset(left, top + arm), Offset(left, top), targetPaint);
    canvas.drawLine(Offset(left, top), Offset(left + arm, top), targetPaint);
    canvas.drawLine(Offset(right - arm, top), Offset(right, top), targetPaint);
    canvas.drawLine(Offset(right, top), Offset(right, top + arm), targetPaint);
    canvas.drawLine(
      Offset(left, bottom - arm),
      Offset(left, bottom),
      targetPaint,
    );
    canvas.drawLine(
      Offset(left, bottom),
      Offset(left + arm, bottom),
      targetPaint,
    );
    canvas.drawLine(
      Offset(right - arm, bottom),
      Offset(right, bottom),
      targetPaint,
    );
    canvas.drawLine(
      Offset(right, bottom - arm),
      Offset(right, bottom),
      targetPaint,
    );

    // Small center crosshair dot.
    canvas.drawCircle(
      center,
      2.2,
      Paint()..color = const Color(0xFFA5B4FC).withValues(alpha: 0.8),
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
