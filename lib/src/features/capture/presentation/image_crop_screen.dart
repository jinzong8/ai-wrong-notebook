import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/free_crop_geometry.dart';
import 'package:smart_wrong_notebook/src/features/capture/application/image_crop_processor.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/widgets/crop_angle_control.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/widgets/free_crop_canvas.dart';

class ImageCropScreen extends ConsumerStatefulWidget {
  const ImageCropScreen({super.key});

  @override
  ConsumerState<ImageCropScreen> createState() => _ImageCropScreenState();
}

class _ImageCropScreenState extends ConsumerState<ImageCropScreen> {
  ui.Image? _decodedImage;
  Rect _cropRect = fullNormalizedCropRect;
  int _quarterTurns = 0;
  double _fineRotationDegrees = 0.0;
  bool _adjustingAngle = false;
  bool _loading = true;
  bool _saving = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadImage();
    });
  }

  @override
  void dispose() {
    _decodedImage?.dispose();
    super.dispose();
  }

  Future<void> _loadImage() async {
    final current = ref.read(currentQuestionProvider);
    if (current == null) {
      if (mounted) context.go('/');
      return;
    }

    setState(() {
      _loading = true;
      _loadError = null;
    });

    try {
      final file = File(current.imagePath);
      if (!file.existsSync()) {
        throw const FileSystemException('找不到拍摄的图片文件');
      }
      final image = await decodeImageForCrop(file);
      if (!mounted) {
        image.dispose();
        return;
      }
      _decodedImage?.dispose();
      setState(() {
        _decodedImage = image;
        _cropRect = fullNormalizedCropRect;
        _quarterTurns = 0;
        _fineRotationDegrees = 0.0;
        _adjustingAngle = false;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '加载图片失败：$e';
      });
    }
  }

  void _rotate({required bool clockwise}) {
    if (_decodedImage == null || _saving) return;
    setState(() {
      _quarterTurns = (_quarterTurns + (clockwise ? 1 : 3)) % 4;
      _cropRect = rotateNormalizedCropRect(_cropRect, clockwise: clockwise);
    });
  }

  void _resetCrop() {
    if (_decodedImage == null || _saving) return;
    setState(() {
      _quarterTurns = 0;
      _fineRotationDegrees = 0.0;
      _adjustingAngle = false;
      _cropRect = fullNormalizedCropRect;
    });
  }

  void _useOriginalImage() {
    if (_saving) return;
    final current = ref.read(currentQuestionProvider);
    if (current == null) {
      context.go('/');
      return;
    }
    ref.read(currentQuestionProvider.notifier).state = current.copyWith(
      contentStatus: ContentStatus.processing,
    );
    context.go('/analysis/loading');
  }

  Future<void> _confirmCrop() async {
    final current = ref.read(currentQuestionProvider);
    final image = _decodedImage;
    if (current == null || image == null || _saving) return;

    // Fast path: full unrotated frame avoids unnecessary re-encoding.
    if (_quarterTurns == 0 &&
        _fineRotationDegrees.abs() < 0.05 &&
        isEffectivelyFullCrop(_cropRect)) {
      _useOriginalImage();
      return;
    }

    setState(() => _saving = true);
    File? tempFile;
    try {
      final jpgBytes = await cropAndEncodeJpg(
        sourceImage: image,
        quarterTurns: _quarterTurns,
        fineRotationDegrees: _fineRotationDegrees,
        normalizedCropRect: _cropRect,
      );
      if (!mounted) return;

      tempFile = File(
        '${Directory.systemTemp.path}/crop_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await tempFile.writeAsBytes(jpgBytes, flush: true);

      final storage = ref.read(imageStorageServiceProvider);
      final savedPath = await storage.saveImage(tempFile);
      if (!mounted) return;

      final newRecord = QuestionRecord.draft(
        id: current.id,
        imagePath: savedPath,
        subject: current.subject,
        recognizedText: '',
      ).copyWith(contentStatus: ContentStatus.processing);
      ref.read(currentQuestionProvider.notifier).state = newRecord;

      context.go('/analysis/loading');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('裁剪失败：$e')),
      );
      setState(() => _saving = false);
    } finally {
      if (tempFile != null && tempFile.existsSync()) {
        try {
          await tempFile.delete();
        } catch (_) {}
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    const surfaceBg = Color(0xFF0E1117);
    const barBg = Color(0xFF161B22);
    const primaryAccent = Color(0xFF6366F1);

    return Scaffold(
      backgroundColor: surfaceBg,
      appBar: AppBar(
        backgroundColor: barBg,
        foregroundColor: Colors.white,
        iconTheme: const IconThemeData(color: Colors.white),
        actionsIconTheme: const IconThemeData(color: Colors.white),
        systemOverlayStyle: SystemUiOverlayStyle.light,
        elevation: 0,
        title: const Text('框选题目', style: TextStyle(color: Colors.white)),
        leading: IconButton(
          key: const Key('crop-back-button'),
          tooltip: '取消',
          icon: const Icon(CupertinoIcons.chevron_left, color: Colors.white),
          onPressed: _saving ? null : () => context.go('/'),
        ),
        actions: <Widget>[
          TextButton(
            key: const Key('crop-use-original'),
            onPressed: (_loading || _saving || _decodedImage == null)
                ? null
                : _useOriginalImage,
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
            child: const Text('用原图'),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          Container(
            width: double.infinity,
            color: barBg,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: const Text(
              '拖动四边或四角自由框选单道题，不限宽高比',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.white60),
            ),
          ),
          Expanded(
            child: _buildCanvas(),
          ),
          Container(
            color: barBg,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_decodedImage != null) ...<Widget>[
                    CropAngleControl(
                      angleDegrees: _fineRotationDegrees,
                      enabled: !_saving,
                      onChangeStart: () =>
                          setState(() => _adjustingAngle = true),
                      onChangeEnd: () =>
                          setState(() => _adjustingAngle = false),
                      onChanged: (deg) =>
                          setState(() => _fineRotationDegrees = deg),
                    ),
                    Divider(
                      height: 1,
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Row(
                      children: <Widget>[
                        _CropToolButton(
                          key: const Key('crop-rotate-left'),
                          icon: CupertinoIcons.rotate_left,
                          label: '左旋',
                          onPressed: (_decodedImage == null || _saving)
                              ? null
                              : () => _rotate(clockwise: false),
                        ),
                        const SizedBox(width: 4),
                        _CropToolButton(
                          key: const Key('crop-rotate-right'),
                          icon: CupertinoIcons.rotate_right,
                          label: '右旋',
                          onPressed: (_decodedImage == null || _saving)
                              ? null
                              : () => _rotate(clockwise: true),
                        ),
                        const SizedBox(width: 4),
                        _CropToolButton(
                          key: const Key('crop-reset'),
                          icon: CupertinoIcons.arrow_counterclockwise,
                          label: '重置',
                          onPressed: (_decodedImage == null || _saving)
                              ? null
                              : _resetCrop,
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
                          onPressed: (_decodedImage == null || _saving)
                              ? null
                              : _confirmCrop,
                          icon: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(CupertinoIcons.checkmark_alt,
                                  size: 18),
                          label: Text(_saving ? '处理中...' : '开始分析'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCanvas() {
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CircularProgressIndicator(color: Colors.white),
            SizedBox(height: 16),
            Text('正在加载图片...', style: TextStyle(color: Colors.white70)),
          ],
        ),
      );
    }

    if (_loadError != null || _decodedImage == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Icon(
                CupertinoIcons.exclamationmark_triangle,
                size: 40,
                color: Colors.orangeAccent,
              ),
              const SizedBox(height: 12),
              Text(
                _loadError ?? '无法加载图片',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                children: <Widget>[
                  OutlinedButton(
                    onPressed: () => context.go('/'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('返回'),
                  ),
                  FilledButton(
                    onPressed: _loadImage,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return FreeCropCanvas(
      image: _decodedImage!,
      quarterTurns: _quarterTurns,
      fineRotationDegrees: _fineRotationDegrees,
      emphasizeGrid: _adjustingAngle,
      cropRect: _cropRect,
      enabled: !_saving,
      onCropRectChanged: (next) => setState(() => _cropRect = next),
    );
  }
}

class _CropToolButton extends StatelessWidget {
  const _CropToolButton({
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
    final enabled = onPressed != null;
    final color = enabled ? Colors.white : Colors.white38;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
  }
}
