import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/common/widgets/editorial_surface.dart';
import 'package:smart_wrong_notebook/src/domain/models/mastery_level.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/camera_capture_crop_screen.dart';
import 'package:smart_wrong_notebook/src/shared/utils/local_date_utils.dart';
import 'package:smart_wrong_notebook/src/shared/widgets/math_content_view.dart';

class NotebookScreen extends ConsumerStatefulWidget {
  const NotebookScreen({super.key});

  @override
  ConsumerState<NotebookScreen> createState() => _NotebookScreenState();
}

class _NotebookScreenState extends ConsumerState<NotebookScreen> {
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchController.text = ref.read(searchQueryProvider);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    QuestionRecord question,
  ) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('删除后无法恢复，确定要删除这道错题吗？'),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () async {
              await ref.read(questionRepositoryProvider).delete(question.id);
              invalidateQuestionList(ref);
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  PopupMenuItem<NotebookSortOrder> _buildSortMenuItem(
    BuildContext context,
    NotebookSortOrder value,
    String label,
    NotebookSortOrder selected,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final isSelected = value == selected;
    return PopupMenuItem<NotebookSortOrder>(
      value: value,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                color: isSelected ? colorScheme.primary : colorScheme.onSurface,
              ),
            ),
          ),
          if (isSelected)
            Icon(
              CupertinoIcons.checkmark,
              size: 16,
              color: colorScheme.primary,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final searchQuery = ref.watch(searchQueryProvider);
    ref.listen<String>(searchQueryProvider, (prev, next) {
      if (next != _searchController.text) {
        _searchController.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    });

    final selectedSort = ref.watch(selectedNotebookSortProvider);
    final allQuestions =
        ref.watch(questionListProvider).valueOrNull ?? const <QuestionRecord>[];
    final questionsAsync = ref.watch(filteredQuestionListProvider);
    final selectedSubject = ref.watch(selectedSubjectFilterProvider);
    final selectedMastery = ref.watch(selectedMasteryFilterProvider);
    final selectedCreatedToday = ref.watch(selectedCreatedTodayFilterProvider);
    final selectedKnowledgePoint =
        ref.watch(selectedKnowledgePointFilterProvider);
    final selectedTags = ref.watch(selectedTagsFilterProvider);

    final subjectCounts = <Subject, int>{};
    for (final q in allQuestions) {
      subjectCounts[q.subject] = (subjectCounts[q.subject] ?? 0) + 1;
    }
    final visibleSubjects = allQuestions.isEmpty
        ? Subject.selectableValues
        : (Subject.selectableValues
            .where((s) => (subjectCounts[s] ?? 0) > 0 || selectedSubject == s)
            .toList()
          ..sort((a, b) {
            final countCmp =
                (subjectCounts[b] ?? 0).compareTo(subjectCounts[a] ?? 0);
            if (countCmp != 0) return countCmp;
            return a.index.compareTo(b.index);
          }));

    return Scaffold(
      appBar: AppBar(
        title: const Text('错题本'),
        actions: [
          PopupMenuButton<NotebookSortOrder>(
            key: const Key('notebook-sort-button'),
            tooltip: '排序',
            initialValue: selectedSort,
            icon: const Icon(CupertinoIcons.arrow_up_arrow_down),
            onSelected: (order) {
              ref.read(selectedNotebookSortProvider.notifier).state = order;
            },
            itemBuilder: (context) => <PopupMenuEntry<NotebookSortOrder>>[
              _buildSortMenuItem(
                context,
                NotebookSortOrder.newestFirst,
                '最新录入',
                selectedSort,
              ),
              _buildSortMenuItem(
                context,
                NotebookSortOrder.oldestFirst,
                '最早录入',
                selectedSort,
              ),
              _buildSortMenuItem(
                context,
                NotebookSortOrder.mostReviewed,
                '复习最多',
                selectedSort,
              ),
            ],
          ),
          IconButton(
            icon: const Icon(CupertinoIcons.camera),
            onPressed: () => openCameraCaptureFlow(
              context,
              ref,
              returnRoute: '/notebook',
            ),
            tooltip: '添加错题',
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索错题',
                prefixIcon: const Icon(CupertinoIcons.search, size: 20),
                suffixIcon:
                    (searchQuery.isNotEmpty || _searchController.text.isNotEmpty)
                        ? IconButton(
                            icon: const Icon(CupertinoIcons.xmark_circle,
                                size: 18),
                            onPressed: () {
                              _searchController.clear();
                              ref.read(searchQueryProvider.notifier).state = '';
                            },
                          )
                        : null,
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                filled: true,
                fillColor: colorScheme.surface,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: colorScheme.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: colorScheme.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide:
                      BorderSide(color: Theme.of(context).colorScheme.primary),
                ),
              ),
              onChanged: (v) {
                ref.read(searchQueryProvider.notifier).state = v;
              },
            ),
          ),
          // Filter chips
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              children: <Widget>[
                _Chip(
                  key: const Key('notebook-filter-all'),
                  label: '全部',
                  selected: selectedSubject == null &&
                      selectedMastery == null &&
                      !selectedCreatedToday &&
                      selectedKnowledgePoint == null &&
                      selectedTags.isEmpty,
                  onTap: () {
                    ref.read(selectedSubjectFilterProvider.notifier).state =
                        null;
                    ref.read(selectedMasteryFilterProvider.notifier).state =
                        null;
                    ref
                        .read(selectedCreatedTodayFilterProvider.notifier)
                        .state = false;
                    ref
                        .read(selectedKnowledgePointFilterProvider.notifier)
                        .state = null;
                    ref.read(selectedTagsFilterProvider.notifier).state =
                        <String>[];
                  },
                ),
                const SizedBox(width: 8),
                if (selectedCreatedToday) ...<Widget>[
                  _Chip(
                    label: '今日新增',
                    selected: true,
                    onTap: () {
                      ref
                          .read(selectedCreatedTodayFilterProvider.notifier)
                          .state = false;
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                if (selectedKnowledgePoint != null) ...<Widget>[
                  _Chip(
                    key: const Key('notebook-active-kp-chip'),
                    label: '📚 $selectedKnowledgePoint',
                    selected: true,
                    onTap: () {
                      ref
                          .read(selectedKnowledgePointFilterProvider.notifier)
                          .state = null;
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                ...selectedTags.map(
                  (tag) => Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _Chip(
                      label: '# $tag',
                      selected: true,
                      onTap: () {
                        ref.read(selectedTagsFilterProvider.notifier).state =
                            selectedTags.where((item) => item != tag).toList();
                      },
                    ),
                  ),
                ),
                ...visibleSubjects.map((s) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _Chip(
                        key: Key('notebook-subject-chip-${s.name}'),
                        label: s.label,
                        count: subjectCounts[s],
                        selected: selectedSubject == s,
                        onTap: () {
                          ref
                              .read(selectedSubjectFilterProvider.notifier)
                              .state = selectedSubject == s ? null : s;
                        },
                      ),
                    )),
                ...MasteryLevel.values.map((level) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: _Chip(
                        key: Key('notebook-mastery-chip-${level.name}'),
                        label: _masteryFilterLabel(level),
                        selected: selectedMastery == level,
                        onTap: () {
                          ref
                              .read(selectedMasteryFilterProvider.notifier)
                              .state = selectedMastery == level ? null : level;
                        },
                      ),
                    )),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // List
          Expanded(
            child: questionsAsync.when(
              data: (questions) {
                if (questions.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Icon(CupertinoIcons.question,
                            size: 64,
                            color: colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.45)),
                        const SizedBox(height: 16),
                        Text('暂无错题',
                            style: TextStyle(
                                fontSize: 16, color: colorScheme.onSurface)),
                        const SizedBox(height: 8),
                        Text('点击右上角相机图标拍照录题',
                            style: TextStyle(
                                fontSize: 13,
                                color: colorScheme.onSurfaceVariant)),
                      ],
                    ),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async {
                    invalidateQuestionList(ref);
                  },
                  child: ListView.builder(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                    itemCount: questions.length,
                    itemBuilder: (context, index) {
                      final q = questions[index];
                      return RepaintBoundary(
                        child: _QuestionCard(
                          question: q,
                          onTap: () {
                            ref
                                .read(activeReviewSessionProvider.notifier)
                                .state = null;
                            ref.read(currentQuestionProvider.notifier).state =
                                q;
                            ref
                                .read(
                                    questionDetailReturnRouteProvider.notifier)
                                .state = '/notebook';
                            ref
                                .read(questionDetailModeProvider.notifier)
                                .state = QuestionDetailMode.browse;
                            context.go('/notebook/question/${q.id}');
                          },
                          onDelete: () => _confirmDelete(context, ref, q),
                          onKnowledgePointTap: (kp) {
                            ref
                                .read(selectedKnowledgePointFilterProvider
                                    .notifier)
                                .state = kp;
                          },
                        ),
                      );
                    },
                  ),
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('加载失败: $e')),
            ),
          ),
        ],
      ),
    );
  }
}

String _masteryFilterLabel(MasteryLevel level) {
  return switch (level) {
    MasteryLevel.newQuestion => '新收录',
    MasteryLevel.reviewing => '复习中',
    MasteryLevel.mastered => '已掌握',
  };
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final fg = selected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primary
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: count != null && count! > 0
            ? Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    label,
                    style: TextStyle(fontSize: 13, color: fg),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: fg.withValues(alpha: selected ? 0.9 : 0.72),
                    ),
                  ),
                ],
              )
            : Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: fg,
                ),
              ),
      ),
    );
  }
}

class _QuestionCard extends StatelessWidget {
  const _QuestionCard({
    required this.question,
    required this.onTap,
    required this.onDelete,
    required this.onKnowledgePointTap,
  });

  final QuestionRecord question;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final void Function(String knowledgePoint) onKnowledgePointTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final masteryColor = _masteryColor(context, question.masteryLevel);
    final aiTags = question.aiTags;
    final customTags = question.customTags;
    final allTags = [...aiTags, ...customTags];

    return Dismissible(
      key: ValueKey(question.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        onDelete();
        return false;
      },
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        margin: const EdgeInsets.only(bottom: 10),
        decoration: BoxDecoration(
          color:
              isDark ? Colors.red.withValues(alpha: 0.14) : Colors.red.shade50,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(CupertinoIcons.trash, color: Colors.red),
      ),
      child: Semantics(
        button: true,
        label:
            '错题: ${question.correctedText}，科目: ${question.subject.label}，状态: ${_masteryLabel(question.masteryLevel)}，日期: ${_formatDate(question.createdAt)}，左滑删除',
        child: Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: colorScheme.outlineVariant),
                boxShadow: [
                  BoxShadow(
                      color:
                          Colors.black.withValues(alpha: isDark ? 0.12 : 0.03),
                      blurRadius: 8,
                      offset: const Offset(0, 2))
                ],
              ),
              child: Row(
                children: <Widget>[
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: question.subject.color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Icon(question.subject.icon,
                        size: 20, color: question.subject.color),
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
                          style: const TextStyle(
                              fontWeight: FontWeight.w500, fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: <Widget>[
                            Text(
                              '${question.subject.label} · ${_formatDate(question.createdAt)}',
                              style: TextStyle(
                                  fontSize: 12, color: question.subject.color),
                            ),
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: masteryColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _masteryLabel(question.masteryLevel),
                                style: TextStyle(
                                    fontSize: 11,
                                    color: masteryColor,
                                    fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                        if (_batchLabel(question) != null) ...<Widget>[
                          const SizedBox(height: 4),
                          Text(
                            _batchLabel(question)!,
                            style: TextStyle(
                                fontSize: 11,
                                color: colorScheme.onSurfaceVariant),
                          ),
                        ],
                        // AI 知识点标签（有颜色区分 AI 生成和手动）
                        if (allTags.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: allTags.take(5).map((tag) {
                              final isAiTag = aiTags.contains(tag);
                              final tagColor = isAiTag
                                  ? const Color(0xFFB45309)
                                  : colorScheme.primary;
                              final tagBackground = isDark
                                  ? tagColor.withValues(alpha: 0.14)
                                  : isAiTag
                                      ? const Color(0xFFFEF6E4)
                                      : const Color(0xFFEBF2FF);
                              return GestureDetector(
                                onTap: () => onKnowledgePointTap(tag),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 2.5),
                                  decoration: BoxDecoration(
                                    color: tagBackground,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: MathContentView(
                                    tag,
                                    mode: MathContentViewMode.compact,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w500,
                                      color: isDark
                                          ? colorScheme.onSurface
                                          : tagColor,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Icon(CupertinoIcons.chevron_right,
                      color:
                          colorScheme.onSurfaceVariant.withValues(alpha: 0.65),
                      size: 22),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) => formatRelativeLocalDate(date);

  Color _masteryColor(BuildContext context, MasteryLevel level) {
    final p = EditorialPalette.of(context);
    switch (level) {
      case MasteryLevel.newQuestion:
        return p.inkSecondary;
      case MasteryLevel.reviewing:
        return p.ochre;
      case MasteryLevel.mastered:
        return p.emerald;
    }
  }

  String _masteryLabel(MasteryLevel level) => _masteryFilterLabel(level);

  String? _batchLabel(QuestionRecord question) {
    if (question.parentQuestionId == null && question.rootQuestionId == null) {
      return null;
    }
    final order = question.splitOrder;
    return order == null ? '来自同一拍照批次' : '来自同一拍照批次 · 第 $order 题';
  }
}
