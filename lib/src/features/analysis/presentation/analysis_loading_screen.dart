import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/common/widgets/app_back_scope.dart';
import 'package:smart_wrong_notebook/src/common/widgets/editorial_surface.dart';
import 'package:smart_wrong_notebook/src/data/remote/ai/ai_analysis_service.dart';
import 'package:smart_wrong_notebook/src/data/services/question_analysis_coordinator.dart';
import 'package:smart_wrong_notebook/src/data/services/single_question_auto_save.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/camera_capture_crop_screen.dart';

class AnalysisLoadingScreen extends ConsumerStatefulWidget {
  const AnalysisLoadingScreen({
    super.key,
    this.isReanalysis = false,
  });

  final bool isReanalysis;

  @override
  ConsumerState<AnalysisLoadingScreen> createState() =>
      _AnalysisLoadingScreenState();
}

class _AnalysisLoadingScreenState extends ConsumerState<AnalysisLoadingScreen> {
  String? _errorMessage;
  String? _debugInfo;
  bool _showDebugInfo = false;
  int _step = 0;
  String? _progressText;
  bool _canContinueInBackground = false;
  Timer? _stepTimer;

  static const List<String> _steps = <String>[
    '正在识别题目...',
    '正在理解题意...',
    '正在生成解析...',
    '即将完成...',
  ];

  static const List<String> _stageLabels = <String>[
    '识别题干与公式',
    '拆解考点与错因',
    '生成分步解答',
  ];

  @override
  void initState() {
    super.initState();
    _runAnalysis();
    _animateSteps();
  }

  void _animateSteps() {
    _stepTimer?.cancel();
    _stepTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_step < _steps.length - 1) {
        setState(() => _step++);
      } else {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _stepTimer?.cancel();
    super.dispose();
  }

  Future<void> _runAnalysis() async {
    final current = ref.read(currentQuestionProvider);
    if (current == null) {
      if (mounted) context.go('/');
      return;
    }

    final settingsRepo = ref.read(settingsRepositoryProvider);
    final config = await settingsRepo.getAiProviderConfig();

    final buffer = StringBuffer()
      ..writeln('配置状态:')
      ..writeln('- 配置对象: ${config != null ? "存在" : "为空"}');
    if (config != null) {
      buffer
        ..writeln(
            '- baseUrl: ${config.baseUrl.isNotEmpty ? config.baseUrl : "(空)"}')
        ..writeln('- model: ${config.model.isNotEmpty ? config.model : "(空)"}')
        ..writeln(
            '- apiKey: ${config.apiKey.isNotEmpty ? "[已设置(${config.apiKey.length}字符)]" : "(空)"}');
    } else {
      buffer.writeln('\n请到设置中配置 AI 服务');
    }
    final debugInfo = buffer.toString();

    if (!mounted) return;
    setState(() => _debugInfo = debugInfo);

    try {
      final coordinator = ref.read(questionAnalysisCoordinatorProvider);
      final QuestionRecord updated;
      if (coordinator is BackgroundQuestionAnalysisCoordinator) {
        final handle = await coordinator.enqueue(current);
        if (mounted) {
          setState(() => _canContinueInBackground = true);
        }
        updated = await coordinator.waitForResult(handle);
      } else {
        updated = await coordinator.analyze(
          current,
          onProgress: (completed, total, {int failed = 0}) {
            if (!mounted) return;
            setState(() {
              _stepTimer?.cancel();
              if (completed == 0) {
                _progressText = '正在依次分析 $total 道题...';
                return;
              }
              final suffix = failed > 0 ? '（$failed题失败）' : '';
              _progressText = '已完成 $completed/$total题分析$suffix';
            });
          },
        );
      }
      if (!mounted) return;
      final activeQuestion = ref.read(currentQuestionProvider);
      if (activeQuestion?.id != current.id) return;

      _stepTimer?.cancel();

      // Plan A: single question -> auto-save idempotently and land directly on
      // QuestionDetailScreen; >1 questions -> go to AnalysisResultScreen for
      // per-question review and split confirmation.
      if (!isMultiQuestionAnalysisResult(updated)) {
        final saved = await autoSaveSingleQuestion(
          analyzed: updated,
          repository: ref.read(questionRepositoryProvider),
        );
        try {
          await ref
              .read(scanTaskLifecycleServiceProvider)
              .completeSaved(saved.id);
        } catch (_) {
          // Saved notebook record remains authoritative.
        }
        if (!mounted) return;
        final latestActive = ref.read(currentQuestionProvider);
        if (latestActive?.id != current.id) return;

        invalidateQuestionList(ref);
        ref.invalidate(scanTaskCountProvider);
        ref.read(currentQuestionProvider.notifier).state = saved;
        if (!widget.isReanalysis) {
          ref.read(questionDetailReturnRouteProvider.notifier).state =
              ref.read(captureReturnRouteProvider);
          ref.read(questionDetailModeProvider.notifier).state =
              QuestionDetailMode.capture;
        }
        final messenger = ScaffoldMessenger.maybeOf(context);
        context.go('/notebook/question/${saved.id}');
        messenger?.hideCurrentSnackBar();
        messenger?.showSnackBar(
          SnackBar(
            content: Text(
              widget.isReanalysis ? '已重新解析并更新错题' : '已自动保存到错题本',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
        return;
      }

      ref.read(currentQuestionProvider.notifier).state = updated;
      context.go('/analysis/result');
    } on AiAnalysisException catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
          _debugInfo = debugInfo;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '解析失败：$e';
          _debugInfo = debugInfo;
        });
      }
    }
  }

  void _handleBack() {
    final current = ref.read(currentQuestionProvider);
    if (widget.isReanalysis && current != null) {
      context.go('/notebook/question/${current.id}');
      return;
    }
    context.go(ref.read(captureReturnRouteProvider));
  }

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    return AppBackScope(
      onBack: _handleBack,
      child: Scaffold(
        backgroundColor: p.canvas,
        appBar: AppBar(
          title: Text(widget.isReanalysis ? '重新解析' : 'AI 解析'),
          leading: IconButton(
            icon: const Icon(CupertinoIcons.chevron_left),
            onPressed: _handleBack,
          ),
        ),
        body: _errorMessage != null
            ? _buildErrorView(context, p)
            : _LoadingView(
                step: _step,
                steps: _steps,
                stageLabels: _stageLabels,
                isReanalysis: widget.isReanalysis,
                progressText: _progressText,
                onCaptureNextInBackground: _canContinueInBackground
                    ? () => openCameraCaptureFlow(
                          context,
                          ref,
                          returnRoute: ref.read(captureReturnRouteProvider),
                        )
                    : null,
                onBackHomeInBackground: _canContinueInBackground
                    ? () => context.go(ref.read(captureReturnRouteProvider))
                    : null,
              ),
      ),
    );
  }

  Widget _buildErrorView(BuildContext context, EditorialPalette p) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: EditorialCard(
          accentColor: p.terracotta,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Center(
                child: Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: p.terracottaTint,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    CupertinoIcons.exclamationmark_circle,
                    color: p.terracotta,
                    size: 28,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '本次解析未能完成',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: p.inkPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.55,
                  color: p.inkSecondary,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () {
                  setState(() {
                    _errorMessage = null;
                    _progressText = null;
                    _step = 0;
                    _canContinueInBackground = false;
                  });
                  _runAnalysis();
                  _animateSteps();
                },
                icon: const Icon(CupertinoIcons.refresh, size: 17),
                label: const Text('重试'),
              ),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _handleBack,
                child: Text(widget.isReanalysis ? '返回错题详情' : '返回首页'),
              ),
              if ((_debugInfo ?? '').isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () =>
                      setState(() => _showDebugInfo = !_showDebugInfo),
                  child: Text(
                    _showDebugInfo ? '收起诊断信息' : '查看诊断信息',
                    style: TextStyle(fontSize: 12.5, color: p.inkMuted),
                  ),
                ),
                if (_showDebugInfo)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: p.subtle,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: p.hairline),
                    ),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        _debugInfo!,
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: p.inkSecondary,
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _LoadingView extends StatefulWidget {
  const _LoadingView({
    required this.step,
    required this.steps,
    required this.stageLabels,
    required this.isReanalysis,
    this.progressText,
    this.onCaptureNextInBackground,
    this.onBackHomeInBackground,
  });

  final int step;
  final List<String> steps;
  final List<String> stageLabels;
  final bool isReanalysis;
  final String? progressText;
  final VoidCallback? onCaptureNextInBackground;
  final VoidCallback? onBackHomeInBackground;

  @override
  State<_LoadingView> createState() => _LoadingViewState();
}

class _LoadingViewState extends State<_LoadingView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 1800),
      vsync: this,
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    final activeStage = widget.step.clamp(0, widget.stageLabels.length - 1);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            EditorialCard(
              padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  AnimatedBuilder(
                    animation: _pulseController,
                    builder: (_, __) {
                      final scale = 0.94 + _pulseController.value * 0.08;
                      final ringAlpha = 0.14 + _pulseController.value * 0.14;
                      return SizedBox(
                        width: 84,
                        height: 84,
                        child: Stack(
                          alignment: Alignment.center,
                          children: <Widget>[
                            Transform.scale(
                              scale: scale,
                              child: Container(
                                width: 78,
                                height: 78,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: p.cobalt.withValues(alpha: ringAlpha),
                                ),
                              ),
                            ),
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: p.cobaltTint,
                              ),
                              child: Icon(
                                CupertinoIcons.sparkles,
                                size: 26,
                                color: p.cobalt,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  Text(
                    widget.progressText ?? widget.steps[widget.step],
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.2,
                      color: p.inkPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    widget.progressText != null
                        ? '识别到多道题，完成后进入拆分保存'
                        : widget.isReanalysis
                            ? '重新解析完成后将原地更新这道错题'
                            : '单题解析完成后将自动存入错题本',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: p.inkSecondary,
                    ),
                  ),
                  const SizedBox(height: 22),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      minHeight: 4,
                      backgroundColor: p.subtle,
                      color: p.cobalt,
                    ),
                  ),
                  const SizedBox(height: 20),
                  ...widget.stageLabels.asMap().entries.map((entry) {
                    final index = entry.key;
                    final label = entry.value;
                    final done =
                        widget.progressText == null && index < activeStage;
                    final current =
                        widget.progressText == null && index == activeStage;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: <Widget>[
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: Center(
                              child: done
                                  ? Icon(
                                      CupertinoIcons.checkmark_circle_fill,
                                      size: 16,
                                      color: p.emerald,
                                    )
                                  : current
                                      ? SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: p.cobalt,
                                          ),
                                        )
                                      : Container(
                                          width: 7,
                                          height: 7,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: p.hairline,
                                          ),
                                        ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: current || done
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: done
                                    ? p.inkSecondary
                                    : current
                                        ? p.inkPrimary
                                        : p.inkMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
            if (widget.onCaptureNextInBackground != null) ...<Widget>[
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  key: const Key('loading-capture-next'),
                  onPressed: widget.onCaptureNextInBackground,
                  icon: const Icon(CupertinoIcons.camera_fill, size: 17),
                  label: const Text('后台解析，继续拍下一题'),
                ),
              ),
              if (widget.onBackHomeInBackground != null) ...<Widget>[
                const SizedBox(height: 4),
                TextButton(
                  key: const Key('loading-back-home'),
                  onPressed: widget.onBackHomeInBackground,
                  child: Text(
                    '先回首页',
                    style: TextStyle(fontSize: 13, color: p.inkSecondary),
                  ),
                ),
              ],
              const SizedBox(height: 2),
              Text(
                '后台解析不会中断，单题完成后自动入库',
                style: TextStyle(fontSize: 12, color: p.inkMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
