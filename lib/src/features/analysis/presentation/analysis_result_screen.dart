import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/common/widgets/app_back_scope.dart';
import 'package:smart_wrong_notebook/src/common/widgets/editorial_surface.dart';
import 'package:smart_wrong_notebook/src/data/services/question_analysis_coordinator.dart';
import 'package:smart_wrong_notebook/src/data/services/single_question_auto_save.dart';
import 'package:smart_wrong_notebook/src/domain/models/analysis_result.dart';
import 'package:smart_wrong_notebook/src/domain/models/mastery_level.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_split_result.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/camera_capture_crop_screen.dart';
import 'package:smart_wrong_notebook/src/shared/widgets/math_content_view.dart';

class AnalysisResultScreen extends ConsumerStatefulWidget {
  const AnalysisResultScreen({super.key});

  @override
  ConsumerState<AnalysisResultScreen> createState() =>
      _AnalysisResultScreenState();
}

class _AnalysisResultScreenState extends ConsumerState<AnalysisResultScreen> {
  int _activeCandidateIndex = 0;
  bool _savingSingle = false;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    final selectedRecord = ref.watch(currentQuestionProvider);
    final backgroundTasks =
        ref.watch(backgroundAnalysisTasksProvider).valueOrNull ??
            const <QuestionAnalysisTaskSnapshot>[];
    final record = _latestTaskResultFor(
      selectedRecord,
      backgroundTasks,
    );

    if (record == null) {
      return AppBackScope(
        onBack: () => context.go('/'),
        child: Scaffold(
          backgroundColor: p.canvas,
          appBar: AppBar(
            title: const Text('AI 解析结果'),
            leading: IconButton(
              icon: const Icon(CupertinoIcons.chevron_left),
              onPressed: () => context.go('/'),
            ),
          ),
          body: const Center(child: Text('未找到错题记录')),
        ),
      );
    }

    final result = record.analysisResult;
    final splitResult = record.splitResult;
    final hasMultipleCandidates = isMultiQuestionAnalysisResult(record);
    final safeCandidateIndex = (splitResult?.hasMultipleCandidates ?? false)
        ? _activeCandidateIndex.clamp(0, splitResult!.candidates.length - 1)
        : 0;
    final activeCandidate = (splitResult?.hasMultipleCandidates ?? false)
        ? splitResult!.candidates[safeCandidateIndex]
        : null;
    final activeCandidateAnalysis = activeCandidate == null
        ? null
        : record.candidateAnalyses.firstWhereOrNull(
            (candidate) => candidate.candidateId == activeCandidate.id);
    final displayResult = hasMultipleCandidates
        ? activeCandidateAnalysis?.analysisResult
        : result;
    final displayAiTags = hasMultipleCandidates
        ? activeCandidateAnalysis?.aiTags ?? const <String>[]
        : record.aiTags;
    final displayKnowledgePoints = hasMultipleCandidates
        ? activeCandidateAnalysis?.aiKnowledgePoints ?? const <String>[]
        : result?.knowledgePoints ?? const <String>[];
    final displayQuestionText = activeCandidateAnalysis?.questionText ??
        activeCandidate?.text ??
        record.correctedText;
    final hasRetryingCandidate = record.candidateAnalyses.any((candidate) =>
        candidate.status == CandidateAnalysisStatus.queued ||
        candidate.status == CandidateAnalysisStatus.running);
    final canSaveAny = hasMultipleCandidates
        ? record.candidateAnalyses.any((c) => c.isSuccessful)
        : displayResult != null;
    final candidateInsight = hasMultipleCandidates
        ? _candidateInsight(
            candidateOrder: activeCandidate?.order ?? 1,
            total: splitResult?.candidates.length ?? 1,
            hasIndependentAnalysis: activeCandidateAnalysis != null,
          )
        : null;
    final isNeedsReview = displayResult?.visualAssumptionStatus ==
        VisualAssumptionStatus.needsReview;
    final masteryColor = _masteryColor(record.masteryLevel, p);

    return AppBackScope(
      enabled: !_savingSingle,
      onBack: () => context.go('/'),
      child: Scaffold(
        backgroundColor: p.canvas,
        appBar: AppBar(
          title: const Text('AI 解析结果'),
          leading: IconButton(
            icon: const Icon(CupertinoIcons.chevron_left),
            onPressed: () => context.go('/'),
          ),
          actions: <Widget>[
            PopupMenuButton<String>(
              key: const Key('analysis-more-menu'),
              enabled: !_savingSingle,
              onSelected: (value) {
                if (value == 'retake') {
                  _openRetakeCapture(context, record);
                } else if (value == 'edit_text') {
                  ref.read(currentQuestionProvider.notifier).state = record;
                  context.go('/analysis/text-correction');
                }
              },
              itemBuilder: (_) => <PopupMenuEntry<String>>[
                PopupMenuItem<String>(
                  value: 'retake',
                  child: Row(
                    children: <Widget>[
                      Icon(CupertinoIcons.camera, color: p.cobalt, size: 18),
                      const SizedBox(width: 8),
                      const Text('重新拍照'),
                    ],
                  ),
                ),
                if (!hasMultipleCandidates)
                  PopupMenuItem<String>(
                    value: 'edit_text',
                    child: Row(
                      children: <Widget>[
                        Icon(CupertinoIcons.pencil, color: p.cobalt, size: 18),
                        const SizedBox(width: 8),
                        const Text('修改题干'),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: <Widget>[
            EditorialCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      EditorialPill(
                        label: displayResult?.subject?.label ??
                            record.subject.label,
                        backgroundColor: p.cobaltTint,
                        textColor: p.cobalt,
                      ),
                      if (displayResult?.subject != null)
                        EditorialPill(
                          label: 'AI识别',
                          backgroundColor: p.emeraldTint,
                          textColor: p.emerald,
                        ),
                      EditorialPill(
                        label: _masteryLabel(record.masteryLevel),
                        backgroundColor: masteryColor.withValues(
                            alpha: p.isDark ? 0.16 : 0.11),
                        textColor: masteryColor,
                      ),
                      if (hasMultipleCandidates &&
                          splitResult != null) ...<Widget>[
                        EditorialPill(
                          label: '共 ${splitResult.candidates.length} 题',
                          backgroundColor: p.subtle,
                          textColor: p.inkPrimary,
                        ),
                        EditorialPill(
                          label: _splitStrategyLabel(splitResult.strategy),
                          backgroundColor: p.subtle,
                          textColor: p.inkSecondary,
                        ),
                        if (activeCandidate != null)
                          EditorialPill(
                            label: '当前第 ${activeCandidate.order} 题',
                            backgroundColor: p.ochreTint,
                            textColor: p.ochre,
                          ),
                      ],
                    ],
                  ),
                  if (hasMultipleCandidates) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      '这张图片已识别为多题内容，保存时会进入逐题确认。',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: p.inkSecondary,
                      ),
                    ),
                  ],
                  if (displayAiTags.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 12),
                    Text(
                      'AI标签',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: p.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: displayAiTags
                          .map((tag) => _TagChip(
                                label: tag,
                                bgColor: p.ochreTint,
                                textColor: p.ochre,
                              ))
                          .toList(),
                    ),
                  ],
                  if (record.customTags.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 10),
                    Text(
                      '自定义标签',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: p.inkMuted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: record.customTags
                          .map((t) => _TagChip(
                                label: t,
                                bgColor: p.cobaltTint,
                                textColor: p.cobalt,
                              ))
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
            if (hasMultipleCandidates && splitResult != null) ...<Widget>[
              const SizedBox(height: 12),
              _CandidateSwitcherCard(
                splitResult: splitResult,
                candidateAnalyses: record.candidateAnalyses,
                safeCandidateIndex: safeCandidateIndex,
                onSelected: (index) =>
                    setState(() => _activeCandidateIndex = index),
              ),
            ],
            if (displayResult == null) ...<Widget>[
              const SizedBox(height: 14),
              EditorialCard(
                accentColor: p.danger,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    EditorialSectionHeader(
                      title: _candidateFailureTitle(
                        activeCandidateAnalysis,
                        order: activeCandidate?.order ?? 1,
                      ),
                      icon: CupertinoIcons.exclamationmark_triangle,
                      iconColor: p.danger,
                    ),
                    const SizedBox(height: 10),
                    MathContentView(
                      _candidateFailureMessage(activeCandidateAnalysis),
                      style: TextStyle(
                        fontSize: 14,
                        color: p.inkPrimary,
                        height: 1.55,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasMultipleCandidates &&
                  activeCandidateAnalysis != null) ...<Widget>[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: activeCandidateAnalysis.status ==
                                CandidateAnalysisStatus.failed &&
                            activeCandidate != null
                        ? () => _retryCandidate(
                              record,
                              activeCandidateAnalysis,
                            )
                        : null,
                    icon: Icon(_candidateRetryIcon(activeCandidateAnalysis),
                        size: 17),
                    label: Text(_candidateRetryLabel(
                      activeCandidateAnalysis,
                      activeCandidate?.order ?? 1,
                    )),
                  ),
                ),
              ],
            ],
            if (displayResult != null) ...<Widget>[
              const SizedBox(height: 14),
              // 原题
              EditorialCard(
                accentColor: p.cobalt,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    EditorialSectionHeader(
                      title: '原题',
                      icon: CupertinoIcons.doc_text,
                      iconColor: p.cobalt,
                    ),
                    const SizedBox(height: 12),
                    if (record.imagePath.isNotEmpty &&
                        File(record.imagePath).existsSync()) ...<Widget>[
                      EditorialPhotoPreview(
                        imagePath: record.imagePath,
                        maxHeight: 144,
                      ),
                      const SizedBox(height: 12),
                    ],
                    MathContentView(
                      displayQuestionText,
                      contentFormat: hasMultipleCandidates
                          ? QuestionContentFormat.latexMixed
                          : record.contentFormat,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: p.inkPrimary,
                        height: 1.62,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // 正确解答 / 可能解法
              EditorialCard(
                accentColor: isNeedsReview ? p.terracotta : p.emerald,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    EditorialSectionHeader(
                      title: isNeedsReview ? '可能解法' : '正确解答',
                      icon: isNeedsReview
                          ? CupertinoIcons.exclamationmark_triangle
                          : CupertinoIcons.checkmark_circle,
                      iconColor: isNeedsReview ? p.terracotta : p.emerald,
                    ),
                    const SizedBox(height: 10),
                    MathContentView(
                      displayResult.finalAnswer,
                      style: TextStyle(
                        fontSize: 15,
                        color: isNeedsReview ? p.inkPrimary : p.emerald,
                        fontWeight: FontWeight.w600,
                        height: 1.55,
                      ),
                    ),
                    if (_consistencyNotice(displayResult, p) !=
                        null) ...<Widget>[
                      const SizedBox(height: 10),
                      _ConsistencyNotice(
                        notice: _consistencyNotice(displayResult, p)!,
                      ),
                    ],
                    if (_shouldOfferRetakeOrCorrection(displayResult)) ...<Widget>[
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: FilledButton.tonalIcon(
                              key: const Key('analysis-retake-button'),
                              onPressed: () =>
                                  _openRetakeCapture(context, record),
                              icon: const Icon(CupertinoIcons.camera, size: 16),
                              label: const Text('重新拍照'),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                              ),
                            ),
                          ),
                          if (_shouldOfferQuestionCorrection(
                            displayResult,
                            hasMultipleCandidates: hasMultipleCandidates,
                          )) ...<Widget>[
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                key: const Key('analysis-edit-text-button'),
                                onPressed: () =>
                                    context.go('/analysis/text-correction'),
                                icon:
                                    const Icon(CupertinoIcons.pencil, size: 16),
                                label: const Text('修改题干'),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 10,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              if (displayResult.steps.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                EditorialStepTimeline(steps: displayResult.steps),
              ],
              const SizedBox(height: 12),
              // 错因分析
              EditorialCard(
                accentColor: p.terracotta,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    EditorialSectionHeader(
                      title: '错因分析',
                      icon: CupertinoIcons.exclamationmark_triangle,
                      iconColor: p.terracotta,
                    ),
                    const SizedBox(height: 10),
                    MathContentView(
                      displayResult.mistakeReason,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: p.inkPrimary,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // 学习建议
              EditorialCard(
                accentColor: p.ochre,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    EditorialSectionHeader(
                      title: '学习建议',
                      icon: CupertinoIcons.lightbulb,
                      iconColor: p.ochre,
                    ),
                    const SizedBox(height: 10),
                    MathContentView(
                      displayResult.studyAdvice,
                      style: TextStyle(
                        fontSize: 14.5,
                        color: p.inkPrimary,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
              if (candidateInsight != null) ...<Widget>[
                const SizedBox(height: 12),
                EditorialCard(
                  accentColor: p.emerald,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      EditorialSectionHeader(
                        title: '当前子题状态',
                        icon: CupertinoIcons.layers,
                        iconColor: p.emerald,
                      ),
                      const SizedBox(height: 10),
                      MathContentView(
                        candidateInsight,
                        style: TextStyle(
                          fontSize: 13.5,
                          color: p.inkPrimary,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        activeCandidateAnalysis != null
                            ? '当前已切换到第 ${activeCandidate?.order ?? 1} 题独立解析。'
                            : '第 ${activeCandidate?.order ?? 1} 题暂无独立解析。',
                        style: TextStyle(
                          fontSize: 12,
                          color: p.inkSecondary,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              if (displayKnowledgePoints.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                EditorialCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      EditorialSectionHeader(
                        title: '知识点',
                        icon: CupertinoIcons.bookmark,
                        iconColor: p.cobalt,
                      ),
                      const SizedBox(height: 10),
                      ...displayKnowledgePoints.map((kp) => Container(
                            width: double.infinity,
                            margin: const EdgeInsets.only(bottom: 6),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 11, vertical: 7),
                            decoration: BoxDecoration(
                              color: p.subtle,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: MathContentView(
                              kp,
                              style: TextStyle(
                                fontSize: 13,
                                height: 1.45,
                                fontWeight: FontWeight.w500,
                                color: p.inkPrimary,
                              ),
                            ),
                          )),
                    ],
                  ),
                ),
              ],
            ],
            const SizedBox(height: 20),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (canSaveAny) ...<Widget>[
                  FilledButton.icon(
                    onPressed: hasRetryingCandidate || _savingSingle
                        ? null
                        : () => _handleSaveAction(record,
                            hasMultipleCandidates: hasMultipleCandidates),
                    icon: _savingSingle
                        ? const SizedBox.square(
                            dimension: 17,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : Icon(
                            hasMultipleCandidates
                                ? CupertinoIcons.square_split_2x2
                                : CupertinoIcons.tray_arrow_down,
                            size: 18,
                          ),
                    label: Text(
                      hasRetryingCandidate
                          ? '有题正在重新解析'
                          : _savingSingle
                              ? '正在保存...'
                              : '保存到错题本',
                    ),
                  ),
                  const SizedBox(height: 10),
                ],
                OutlinedButton.icon(
                  onPressed:
                      _savingSingle ? null : () => _discardResult(record),
                  icon: const Icon(CupertinoIcons.delete, size: 17),
                  label: const Text('放弃本次结果'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleSaveAction(
    QuestionRecord record, {
    required bool hasMultipleCandidates,
  }) async {
    if (hasMultipleCandidates) {
      final splitter = ref.read(questionSplitServiceProvider);
      ref.read(currentQuestionSplitSessionProvider.notifier).state =
          await buildQuestionSplitSession(
        record,
        splitter: splitter,
      );
      if (!mounted) return;
      context.go('/capture/split-confirmation');
      return;
    }

    // Plan A fallback: single question skips split confirmation and saves
    // directly into the wrong-question notebook.
    setState(() => _savingSingle = true);
    try {
      final saved = await autoSaveSingleQuestion(
        analyzed: record,
        repository: ref.read(questionRepositoryProvider),
      );
      try {
        await ref
            .read(scanTaskLifecycleServiceProvider)
            .completeSaved(saved.id);
      } catch (_) {}
      if (!mounted) return;
      invalidateQuestionList(ref);
      ref.invalidate(scanTaskCountProvider);
      ref.read(currentQuestionProvider.notifier).state = saved;
      ref.read(currentQuestionSplitSessionProvider.notifier).state = null;
      ref.read(questionDetailReturnRouteProvider.notifier).state =
          ref.read(captureReturnRouteProvider);
      ref.read(questionDetailModeProvider.notifier).state =
          QuestionDetailMode.capture;
      final messenger = ScaffoldMessenger.maybeOf(context);
      context.go('/notebook/question/${saved.id}');
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('已保存到错题本'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _savingSingle = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$error')),
      );
    }
  }

  Future<void> _discardResult(QuestionRecord record) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('放弃本次结果'),
        content: const Text('确定放弃这次解析结果吗？此操作不可恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('放弃'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(scanTaskLifecycleServiceProvider).discard(record);
      ref.read(currentQuestionProvider.notifier).state = null;
      ref.read(currentQuestionSplitSessionProvider.notifier).state = null;
      ref.invalidate(scanTaskCountProvider);
      if (mounted) context.go('/');
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('放弃失败：$error')),
      );
    }
  }

  QuestionRecord? _latestTaskResultFor(
    QuestionRecord? selected,
    List<QuestionAnalysisTaskSnapshot> tasks,
  ) {
    if (selected == null) return null;
    for (final task in tasks) {
      if (task.handle.parentQuestionId != selected.id) continue;
      final result = task.resultQuestion;
      if (result != null) return result;
    }
    return selected;
  }

  String _candidateFailureTitle(
    CandidateAnalysisSnapshot? candidate, {
    required int order,
  }) {
    return switch (candidate?.status) {
      CandidateAnalysisStatus.queued => '第 $order 题排队中',
      CandidateAnalysisStatus.running => '正在重新解析第 $order 题',
      _ => '第 $order 题解析失败',
    };
  }

  String _candidateFailureMessage(CandidateAnalysisSnapshot? candidate) {
    return switch (candidate?.status) {
      CandidateAnalysisStatus.queued => '已加入解析队列，完成后会补全到当前结果。',
      CandidateAnalysisStatus.running => '正在重新解析本题，完成后会补全到当前结果。',
      _ => candidate?.errorMessage?.isNotEmpty == true
          ? '已自动重试，仍未成功。该题暂不可保存，可单独重试。\n${candidate!.errorMessage}'
          : '已自动重试，仍未成功。该题暂不可保存，可单独重试。',
    };
  }

  IconData _candidateRetryIcon(CandidateAnalysisSnapshot candidate) {
    return switch (candidate.status) {
      CandidateAnalysisStatus.queued => CupertinoIcons.clock,
      CandidateAnalysisStatus.running => CupertinoIcons.arrow_clockwise,
      CandidateAnalysisStatus.success => CupertinoIcons.checkmark,
      CandidateAnalysisStatus.failed => CupertinoIcons.refresh,
    };
  }

  String _candidateRetryLabel(
    CandidateAnalysisSnapshot candidate,
    int order,
  ) {
    return switch (candidate.status) {
      CandidateAnalysisStatus.queued => '第 $order 题排队中',
      CandidateAnalysisStatus.running => '正在重新解析第 $order 题',
      CandidateAnalysisStatus.success => '第 $order 题已解析',
      CandidateAnalysisStatus.failed => '重试第 $order 题',
    };
  }

  Future<void> _retryCandidate(
    QuestionRecord source,
    CandidateAnalysisSnapshot candidate,
  ) async {
    final coordinator = ref.read(questionAnalysisCoordinatorProvider);
    final CandidateAnalysisRetryCoordinator? retryCoordinator =
        coordinator is CandidateAnalysisRetryCoordinator
            ? coordinator as CandidateAnalysisRetryCoordinator
            : null;
    if (retryCoordinator == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('当前解析任务不支持单题重试，请返回首页重新解析。')),
      );
      return;
    }
    try {
      final queued = await retryCoordinator.retryCandidate(source, candidate);
      if (!mounted) return;
      if (queued) {
        ref.read(currentQuestionProvider.notifier).state =
            _withQueuedCandidate(source, candidate.candidateId);
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            queued
                ? '已加入队列，将只重新解析第 ${candidate.order} 题'
                : '第 ${candidate.order} 题已在解析队列中',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重新解析失败：$error')),
      );
    }
  }

  QuestionRecord _withQueuedCandidate(
    QuestionRecord source,
    String candidateId,
  ) {
    return source.copyWith(
      candidateAnalyses: source.candidateAnalyses.map((candidate) {
        if (candidate.candidateId != candidateId) return candidate;
        return CandidateAnalysisSnapshot(
          candidateId: candidate.candidateId,
          order: candidate.order,
          questionText: candidate.questionText,
          analysisResult: candidate.analysisResult,
          savedExercises: candidate.savedExercises,
          subject: candidate.subject,
          aiTags: candidate.aiTags,
          aiKnowledgePoints: candidate.aiKnowledgePoints,
          status: CandidateAnalysisStatus.queued,
        );
      }).toList(growable: false),
    );
  }

  bool _shouldOfferRetakeOrCorrection(AnalysisResult result) {
    return result.visualAssumptionStatus ==
            VisualAssumptionStatus.needsReview ||
        result.consistencyStatus == AnalysisConsistencyStatus.needsReview;
  }

  bool _shouldOfferQuestionCorrection(
    AnalysisResult result, {
    required bool hasMultipleCandidates,
  }) {
    if (hasMultipleCandidates) return false;
    return _shouldOfferRetakeOrCorrection(result);
  }

  Future<void> _openRetakeCapture(
    BuildContext context,
    QuestionRecord record,
  ) async {
    ref.read(currentQuestionProvider.notifier).state = record;
    await openCameraCaptureFlow(
      context,
      ref,
      returnRoute: '/analysis/result',
      retakeTarget: RetakeCaptureTarget(
        returnRoute: '/analysis/result',
        discardScanTaskQuestion: record,
        subject: record.subject,
      ),
    );
  }

  String _candidateInsight({
    required int candidateOrder,
    required int total,
    required bool hasIndependentAnalysis,
  }) {
    return hasIndependentAnalysis
        ? '当前正在查看第 $candidateOrder / $total 题，已切换到独立解析结果。'
        : '当前正在查看第 $candidateOrder / $total 题，题干切换已生效。';
  }

  String _splitStrategyLabel(Object strategy) {
    switch (strategy.toString().split('.').last) {
      case 'numbered':
        return '编号拆题';
      case 'paragraph':
        return '分段拆题';
      default:
        return '单题回退';
    }
  }

  _ConsistencyNoticeData? _consistencyNotice(
    AnalysisResult result,
    EditorialPalette p,
  ) {
    switch (result.consistencyStatus) {
      case AnalysisConsistencyStatus.repaired:
        if (result.visualAssumptionStatus ==
            VisualAssumptionStatus.needsReview) {
          return _ConsistencyNoticeData(
            text: result.consistencyNote.isNotEmpty
                ? result.consistencyNote
                : 'AI 已复核答案；图中关键标注含义仍需核对',
            icon: CupertinoIcons.exclamationmark_triangle,
            color: p.terracotta,
            background: p.terracottaTint,
          );
        }
        return _ConsistencyNoticeData(
          text: 'AI 已复核并修正答案',
          icon: CupertinoIcons.checkmark_shield,
          color: p.emerald,
          background: p.emeraldTint,
        );
      case AnalysisConsistencyStatus.needsReview:
        if (result.visualAssumptionStatus ==
            VisualAssumptionStatus.needsReview) {
          return _ConsistencyNoticeData(
            text: result.consistencyNote.isNotEmpty
                ? result.consistencyNote
                : '图中关键标注含义需核对，当前为可能解法',
            icon: CupertinoIcons.exclamationmark_triangle,
            color: p.terracotta,
            background: p.terracottaTint,
          );
        }
        return _ConsistencyNoticeData(
          text: '答案与步骤可能不一致，请核对',
          icon: CupertinoIcons.exclamationmark_triangle,
          color: p.terracotta,
          background: p.terracottaTint,
        );
      case AnalysisConsistencyStatus.unchecked:
      case AnalysisConsistencyStatus.consistent:
      case AnalysisConsistencyStatus.unverifiable:
        return null;
    }
  }
}

extension _IterableFirstOrNullExtension<E> on Iterable<E> {
  E? firstWhereOrNull(bool Function(E item) test) {
    for (final item in this) {
      if (test(item)) return item;
    }
    return null;
  }
}

class _CandidateSwitcherCard extends StatelessWidget {
  const _CandidateSwitcherCard({
    required this.splitResult,
    required this.candidateAnalyses,
    required this.safeCandidateIndex,
    required this.onSelected,
  });

  final QuestionSplitResult splitResult;
  final List<CandidateAnalysisSnapshot> candidateAnalyses;
  final int safeCandidateIndex;
  final void Function(int index) onSelected;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);

    return EditorialCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          EditorialSectionHeader(
            title: '题号切换',
            icon: CupertinoIcons.square_list,
            iconColor: p.cobalt,
            trailing: Text(
              '共 ${splitResult.candidates.length} 题',
              style: TextStyle(fontSize: 12, color: p.inkMuted),
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: splitResult.candidates.asMap().entries.map((entry) {
                final candidate = entry.value;
                final isActive = entry.key == safeCandidateIndex;
                final analysis = candidateAnalyses.firstWhereOrNull(
                  (item) => item.candidateId == candidate.id,
                );
                final statusColor = switch (analysis?.status) {
                  CandidateAnalysisStatus.failed => p.danger,
                  CandidateAnalysisStatus.queued ||
                  CandidateAnalysisStatus.running =>
                    p.ochre,
                  _ => p.inkSecondary,
                };
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('第 ${candidate.order} 题'),
                    selected: isActive,
                    onSelected: (_) => onSelected(entry.key),
                    labelStyle: TextStyle(
                      fontSize: 13.5,
                      color: isActive
                          ? (p.isDark ? const Color(0xFF0B1526) : Colors.white)
                          : statusColor,
                      fontWeight: FontWeight.w600,
                    ),
                    selectedColor: p.cobalt,
                    backgroundColor: p.subtle,
                    side: BorderSide(
                      color: isActive ? p.cobalt : p.hairline,
                    ),
                    showCheckmark: false,
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConsistencyNoticeData {
  const _ConsistencyNoticeData({
    required this.text,
    required this.icon,
    required this.color,
    required this.background,
  });

  final String text;
  final IconData icon;
  final Color color;
  final Color background;
}

class _ConsistencyNotice extends StatelessWidget {
  const _ConsistencyNotice({required this.notice});

  final _ConsistencyNoticeData notice;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color:
            p.isDark ? notice.color.withValues(alpha: 0.14) : notice.background,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(notice.icon, size: 15, color: notice.color),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              notice.text,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: p.isDark ? p.inkPrimary : notice.color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip(
      {required this.label, required this.bgColor, required this.textColor});

  final String label;
  final Color bgColor;
  final Color textColor;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
      decoration: BoxDecoration(
        color: p.isDark ? textColor.withValues(alpha: 0.14) : bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: p.isDark ? p.inkPrimary : textColor,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

String _masteryLabel(MasteryLevel level) {
  switch (level) {
    case MasteryLevel.newQuestion:
      return '新收录';
    case MasteryLevel.reviewing:
      return '复习中';
    case MasteryLevel.mastered:
      return '已掌握';
  }
}

Color _masteryColor(MasteryLevel level, EditorialPalette p) {
  switch (level) {
    case MasteryLevel.newQuestion:
      return p.inkSecondary;
    case MasteryLevel.reviewing:
      return p.ochre;
    case MasteryLevel.mastered:
      return p.emerald;
  }
}
