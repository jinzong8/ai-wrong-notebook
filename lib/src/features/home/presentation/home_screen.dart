import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/common/widgets/editorial_surface.dart';
import 'package:smart_wrong_notebook/src/common/widgets/stats_chart.dart';
import 'package:smart_wrong_notebook/src/data/services/question_analysis_coordinator.dart';
import 'package:smart_wrong_notebook/src/domain/models/mastery_level.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/camera_capture_crop_screen.dart';
import 'package:smart_wrong_notebook/src/features/home/presentation/background_analysis_section.dart';
import 'package:smart_wrong_notebook/src/shared/widgets/math_content_view.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = EditorialPalette.of(context);
    final questionsAsync = ref.watch(questionListProvider);
    final dueAsync = ref.watch(dueReviewProvider);
    final analysisTasksAsync = ref.watch(backgroundAnalysisTasksProvider);

    return ColoredBox(
      color: p.canvas,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
          children: <Widget>[
            EditorialCard(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              '开始拍错题',
                              style: TextStyle(
                                fontSize: 21,
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.4,
                                color: p.inkPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '拍单题自动存入错题本，多题自动拆分保存',
                              style: TextStyle(
                                fontSize: 12.5,
                                color: p.inkSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: p.cobaltTint,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          CupertinoIcons.viewfinder,
                          size: 21,
                          color: p.cobalt,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => openCameraCaptureFlow(context, ref),
                    icon: const Icon(CupertinoIcons.camera, size: 19),
                    label: const Text('拍照录题'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 52),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            analysisTasksAsync.when(
              data: (tasks) {
                if (tasks.isEmpty) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: BackgroundAnalysisSection(
                    tasks: tasks,
                    onOpenResult: (task) {
                      final result = task.resultQuestion;
                      if (result == null) return;
                      ref.read(currentQuestionProvider.notifier).state = result;
                      context.go('/analysis/result');
                    },
                    onRetry: (task) => _retryTask(context, ref, task),
                    onDelete: (task) => _deleteTask(context, ref, task),
                  ),
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            dueAsync.when(
              data: (due) => due.isNotEmpty
                  ? Padding(
                      padding: const EdgeInsets.only(bottom: 18),
                      child: _ReviewBanner(
                        count: due.length,
                        onTap: () => context.go('/review'),
                      ),
                    )
                  : const SizedBox.shrink(),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),
            Text('学习统计', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            RepaintBoundary(
              child: questionsAsync.when(
                data: (questions) =>
                    _buildStatsSection(context, ref, questions, p),
                loading: () => const _StatsGridSkeleton(),
                error: (e, _) => Text('加载失败: $e'),
              ),
            ),
            const SizedBox(height: 22),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text('最近新增', style: Theme.of(context).textTheme.titleLarge),
                TextButton(
                  onPressed: () => context.go('/notebook'),
                  child: const Text('查看全部'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            questionsAsync.when(
              data: (questions) {
                final ordered = [...questions]
                  ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
                return _RecentList(
                  questions: ordered.take(5).toList(),
                  ref: ref,
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text('加载失败: $e'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _retryTask(
    BuildContext context,
    WidgetRef ref,
    QuestionAnalysisTaskSnapshot task,
  ) async {
    try {
      await ref
          .read(scanTaskLifecycleServiceProvider)
          .prepareRetry(task.sourceQuestion);
      ref.read(currentQuestionProvider.notifier).state = task.sourceQuestion;
      if (context.mounted) context.go('/analysis/loading');
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重新排队失败：$error')),
      );
    }
  }

  Future<void> _deleteTask(
    BuildContext context,
    WidgetRef ref,
    QuestionAnalysisTaskSnapshot task,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除扫题任务'),
        content: const Text('确定删除这次扫题及其解析结果吗？此操作不可恢复。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(scanTaskLifecycleServiceProvider)
          .discard(task.sourceQuestion);
      ref.invalidate(scanTaskCountProvider);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('删除失败：$error')),
      );
    }
  }

  Widget _buildStatsSection(
    BuildContext context,
    WidgetRef ref,
    List<QuestionRecord> questions,
    EditorialPalette p,
  ) {
    final total = questions.length;
    final mastered =
        questions.where((q) => q.masteryLevel == MasteryLevel.mastered).length;
    final pending = total - mastered;
    final now = DateTime.now();
    final todayNew = questions.where((q) {
      final createdAt = q.createdAt;
      return createdAt.year == now.year &&
          createdAt.month == now.month &&
          createdAt.day == now.day;
    }).length;
    final progress = total == 0 ? 0.0 : mastered / total;
    final percent = (progress * 100).round();

    return Column(
      children: <Widget>[
        StatsGrid(
          total: total,
          todayNew: todayNew,
          pending: pending,
          mastered: mastered,
          onTotalTap: () => _openNotebook(context, ref),
          onTodayNewTap: () => _openNotebook(
            context,
            ref,
            createdToday: true,
          ),
          onMasteredTap: () => _openNotebook(
            context,
            ref,
            masteryLevel: MasteryLevel.mastered,
          ),
          onPendingTap: () => context.go('/review'),
        ),
        if (total > 0) ...<Widget>[
          const SizedBox(height: 12),
          EditorialCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Text(
                      '掌握进度',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: p.inkSecondary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '$percent%',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: p.cobalt,
                        fontFeatures: const <FontFeature>[
                          FontFeature.tabularFigures(),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 8,
                    backgroundColor: p.subtle,
                    color: p.cobalt,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: <Widget>[
                    Text(
                      '$mastered / $total 已掌握',
                      style: TextStyle(fontSize: 12, color: p.inkSecondary),
                    ),
                    const Spacer(),
                    Text(
                      '$pending 待复习',
                      style: TextStyle(fontSize: 12, color: p.inkSecondary),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  void _openNotebook(
    BuildContext context,
    WidgetRef ref, {
    MasteryLevel? masteryLevel,
    bool createdToday = false,
  }) {
    ref.read(selectedSubjectFilterProvider.notifier).state = null;
    ref.read(selectedMasteryFilterProvider.notifier).state = masteryLevel;
    ref.read(selectedCreatedTodayFilterProvider.notifier).state = createdToday;
    ref.read(selectedKnowledgePointFilterProvider.notifier).state = null;
    ref.read(selectedTagsFilterProvider.notifier).state = const <String>[];
    ref.read(searchQueryProvider.notifier).state = '';
    context.go('/notebook');
  }
}

class _StatsGridSkeleton extends StatelessWidget {
  const _StatsGridSkeleton();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: _StatCardSkeleton()),
            SizedBox(width: 10),
            Expanded(child: _StatCardSkeleton()),
          ],
        ),
        SizedBox(height: 10),
        Row(
          children: <Widget>[
            Expanded(child: _StatCardSkeleton()),
            SizedBox(width: 10),
            Expanded(child: _StatCardSkeleton()),
          ],
        ),
      ],
    );
  }
}

class _StatCardSkeleton extends StatelessWidget {
  const _StatCardSkeleton();

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    return Container(
      height: 76,
      decoration: BoxDecoration(
        color: p.subtle,
        borderRadius: BorderRadius.circular(14),
      ),
    );
  }
}

class _RecentList extends StatelessWidget {
  const _RecentList({required this.questions, required this.ref});

  final List<QuestionRecord> questions;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);

    if (questions.isEmpty) {
      return EditorialCard(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          children: <Widget>[
            Icon(
              CupertinoIcons.book,
              size: 38,
              color: p.inkMuted.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 10),
            Text(
              '暂无错题，拍照开始添加',
              style: TextStyle(fontSize: 13.5, color: p.inkSecondary),
            ),
          ],
        ),
      );
    }
    return Column(
      children: List.generate(questions.length, (index) {
        final q = questions[index];
        return _RecentQuestionCard(
          key: ValueKey(q.id),
          question: q,
          onTap: () {
            ref.read(currentQuestionProvider.notifier).state = q;
            context.go('/notebook/question/${q.id}');
          },
        );
      }),
    );
  }
}

class _RecentQuestionCard extends StatelessWidget {
  const _RecentQuestionCard({
    super.key,
    required this.question,
    required this.onTap,
  });

  final QuestionRecord question;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    final aiTags = question.aiTags;
    final customTags = question.customTags;
    final allTags = [...aiTags, ...customTags];

    return Semantics(
      button: true,
      label: '错题: ${question.correctedText}，科目: ${question.subject.label}',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: EditorialCard(
          onTap: onTap,
          borderRadius: 14,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: <Widget>[
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: question.subject.color
                      .withValues(alpha: p.isDark ? 0.16 : 0.10),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(
                  question.subject.icon,
                  size: 17,
                  color: question.subject.color,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    MathContentView(
                      question.correctedText,
                      contentFormat: question.contentFormat,
                      mode: MathContentViewMode.compact,
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: p.inkPrimary,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: <Widget>[
                        Text(
                          question.subject.label,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: question.subject.color,
                          ),
                        ),
                        if (allTags.isNotEmpty) ...<Widget>[
                          const SizedBox(width: 8),
                          ...allTags.take(2).map((tag) {
                            final isAiTag = aiTags.contains(tag);
                            final tagColor = isAiTag ? p.ochre : p.cobalt;
                            final tagBg = isAiTag ? p.ochreTint : p.cobaltTint;
                            return Container(
                              margin: const EdgeInsets.only(right: 5),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: tagBg,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: MathContentView(
                                tag,
                                mode: MathContentViewMode.compact,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w500,
                                  color: p.isDark ? p.inkPrimary : tagColor,
                                ),
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                CupertinoIcons.chevron_right,
                size: 16,
                color: p.inkMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReviewBanner extends StatelessWidget {
  const _ReviewBanner({required this.count, required this.onTap});

  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);

    return Semantics(
      button: true,
      label: '待复习 $count 道错题，点击进入复习',
      child: EditorialCard(
        accentColor: p.terracotta,
        onTap: onTap,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Row(
          children: <Widget>[
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: p.terracottaTint,
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                CupertinoIcons.arrow_2_circlepath,
                color: p.terracotta,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '待复习',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: p.inkPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$count 道错题等待巩固',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: p.terracotta,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              CupertinoIcons.chevron_right,
              color: p.inkMuted,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
