import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/common/widgets/editorial_surface.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_split_session.dart';
import 'package:smart_wrong_notebook/src/shared/widgets/math_content_view.dart';

const _mathPreviewFormat = QuestionContentFormat.latexMixed;

class QuestionSplitConfirmationScreen extends ConsumerStatefulWidget {
  const QuestionSplitConfirmationScreen({super.key});

  @override
  ConsumerState<QuestionSplitConfirmationScreen> createState() =>
      _QuestionSplitConfirmationScreenState();
}

class _QuestionSplitConfirmationScreenState
    extends ConsumerState<QuestionSplitConfirmationScreen> {
  int _activeIndex = 0;
  String? _errorMessage;
  bool _isSaving = false;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    final session = ref.watch(currentQuestionSplitSessionProvider);
    final source = session?.source;
    final drafts = session?.drafts ?? const <QuestionSplitDraft>[];
    final hasImage = source != null &&
        source.imagePath.isNotEmpty &&
        File(source.imagePath).existsSync();

    if (session == null || source == null) {
      return Scaffold(
        backgroundColor: p.canvas,
        appBar: AppBar(title: const Text('拆分保存')),
        body: const Center(child: Text('未找到待保存题目')),
      );
    }

    final safeIndex =
        drafts.isEmpty ? 0 : _activeIndex.clamp(0, drafts.length - 1);
    final activeDraft = drafts.isEmpty ? null : drafts[safeIndex];
    final selectedCount =
        drafts.where((draft) => draft.canSave && draft.selected).length;

    return Scaffold(
      backgroundColor: p.canvas,
      appBar: AppBar(
        title: const Text('拆分保存'),
        leading: IconButton(
          icon: const Icon(CupertinoIcons.chevron_left),
          onPressed: () => context.go('/analysis/result'),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
          children: <Widget>[
            EditorialCard(
              accentColor: p.cobalt,
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  EditorialSectionHeader(
                    title: '逐题确认后保存',
                    icon: CupertinoIcons.square_split_2x2,
                    iconColor: p.cobalt,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '检测到多道题目，可勾选需要收进错题本的题目并逐题微调题干。',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.45,
                      color: p.inkSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: <Widget>[
                      EditorialPill(
                        label: '可保存 ${drafts.length} 题',
                        backgroundColor: p.cobaltTint,
                        textColor: p.cobalt,
                      ),
                      EditorialPill(
                        label: '已选 $selectedCount 题',
                        backgroundColor: p.emeraldTint,
                        textColor: p.emerald,
                      ),
                      EditorialPill(
                        label: source.subject.label,
                        backgroundColor: p.ochreTint,
                        textColor: p.ochre,
                      ),
                      if (session.failedCandidateCount > 0)
                        EditorialPill(
                          label: '${session.failedCandidateCount} 题未解析成功',
                          backgroundColor: p.dangerTint,
                          textColor: p.danger,
                        ),
                      if (session.retryingCandidateCount > 0)
                        EditorialPill(
                          label: '${session.retryingCandidateCount} 题重新解析中',
                          backgroundColor: p.ochreTint,
                          textColor: p.ochre,
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (hasImage) ...<Widget>[
              const SizedBox(height: 12),
              EditorialPhotoPreview(
                imagePath: source.imagePath,
                maxHeight: 196,
              ),
            ],
            const SizedBox(height: 12),
            EditorialCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  EditorialSectionHeader(
                    title: '题目列表',
                    icon: CupertinoIcons.list_bullet,
                    iconColor: p.cobalt,
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        TextButton(
                          onPressed:
                              _isSaving ? null : () => _setAllSelected(true),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: const Text('全选'),
                        ),
                        TextButton(
                          onPressed:
                              _isSaving ? null : () => _setAllSelected(false),
                          style: TextButton.styleFrom(
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                          ),
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '仅展示解析成功的题目。取消不需要保存的题目，点击切换当前编辑项。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: p.inkSecondary,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...drafts.asMap().entries.map((entry) {
                    final index = entry.key;
                    final draft = entry.value;
                    final isActive = index == safeIndex;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: InkWell(
                        onTap: () => setState(() => _activeIndex = index),
                        borderRadius: BorderRadius.circular(12),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                          decoration: BoxDecoration(
                            color: isActive ? p.cobaltTint : p.subtle,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: isActive
                                  ? p.cobalt.withValues(alpha: 0.45)
                                  : p.hairline,
                            ),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: <Widget>[
                              Checkbox(
                                value: draft.canSave && draft.selected,
                                onChanged: draft.canSave
                                    ? (value) => _updateDraft(
                                          index,
                                          draft.copyWith(
                                              selected: value ?? false),
                                        )
                                    : null,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(5)),
                              ),
                              Container(
                                width: 24,
                                height: 24,
                                decoration: BoxDecoration(
                                  color: isActive ? p.cobalt : p.card,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Center(
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: isActive
                                          ? (p.isDark
                                              ? const Color(0xFF0B1526)
                                              : Colors.white)
                                          : p.inkSecondary,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: MathContentView(
                                  draft.text.trim().isEmpty
                                      ? '待补充题目内容'
                                      : draft.text,
                                  contentFormat: _mathPreviewFormat,
                                  mode: MathContentViewMode.compact,
                                  maxLines: 1,
                                  style: TextStyle(
                                    fontSize: 13.5,
                                    fontWeight: FontWeight.w500,
                                    color: draft.canSave && draft.selected
                                        ? p.inkPrimary
                                        : p.inkMuted,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Icon(
                                CupertinoIcons.chevron_right,
                                size: 15,
                                color: isActive ? p.cobalt : p.inkMuted,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (activeDraft != null)
              EditorialCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    EditorialSectionHeader(
                      title: '当前题目内容',
                      icon: CupertinoIcons.pencil,
                      iconColor: p.cobalt,
                      trailing: Text(
                        '第 ${activeDraft.originalOrder} 题',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: p.inkMuted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '支持轻量修改，保存时会按当前内容逐题落库。',
                      style: TextStyle(fontSize: 12, color: p.inkSecondary),
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      key: ValueKey(activeDraft.id),
                      initialValue: _displayEditableText(activeDraft.text),
                      maxLines: 8,
                      minLines: 5,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.55,
                        color: p.inkPrimary,
                      ),
                      onChanged: (value) => _updateDraft(
                          safeIndex, activeDraft.copyWith(text: value)),
                      decoration: InputDecoration(
                        hintText: '请输入题目内容',
                        filled: true,
                        fillColor: p.subtle,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: p.hairline),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(color: p.hairline),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    _FormulaPreviewCard(
                      content: activeDraft.text,
                      contentFormat: activeDraft.contentFormat,
                    ),
                  ],
                ),
              ),
            if (_errorMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              EditorialCard(
                accentColor: p.danger,
                backgroundColor: p.dangerTint,
                padding: const EdgeInsets.all(12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(CupertinoIcons.exclamationmark_triangle,
                        size: 16, color: p.danger),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(fontSize: 12.5, color: p.danger),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _isSaving ||
                      selectedCount == 0 ||
                      session.retryingCandidateCount > 0
                  ? null
                  : () => _saveQuestions(_draftsForSelected(session)),
              icon: _isSaving
                  ? const SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(CupertinoIcons.tray_arrow_down, size: 18),
              label: Text(_isSaving ? '正在保存...' : '保存已勾选题目 ($selectedCount)'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 50),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              selectedCount == 0
                  ? '请至少勾选一道题后再保存。'
                  : session.retryingCandidateCount > 0
                      ? '有题正在重新解析，完成后再决定保存，避免中断本次重试。'
                      : session.failedCandidateCount > 0
                          ? '将保存已勾选的 $selectedCount 道题；${session.failedCandidateCount} 道未解析成功的题不会写入错题本。'
                          : '将保存已勾选的 $selectedCount 道题；未勾选题目不会写入错题本。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: p.inkSecondary),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => context.go('/analysis/result'),
              icon: const Icon(CupertinoIcons.chevron_left, size: 17),
              label: const Text('返回结果页'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(double.infinity, 48),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _updateDraft(int index, QuestionSplitDraft updatedDraft) {
    final session = ref.read(currentQuestionSplitSessionProvider);
    if (session == null) return;

    final nextDrafts = [...session.drafts];
    nextDrafts[index] =
        updatedDraft.copyWith(text: _normalizeEditableText(updatedDraft.text));
    ref.read(currentQuestionSplitSessionProvider.notifier).state =
        session.copyWith(drafts: nextDrafts);

    if (_errorMessage != null) {
      setState(() => _errorMessage = null);
    }
  }

  void _setAllSelected(bool selected) {
    final session = ref.read(currentQuestionSplitSessionProvider);
    if (session == null) return;
    ref.read(currentQuestionSplitSessionProvider.notifier).state =
        session.copyWith(
      drafts: session.drafts
          .map((draft) => draft.copyWith(
                selected: draft.canSave ? selected : false,
              ))
          .toList(),
    );
    if (_errorMessage != null) {
      setState(() => _errorMessage = null);
    }
  }

  String _displayEditableText(String text) => text
      .replaceAll(r'\\(', r'\(')
      .replaceAll(r'\\)', r'\)')
      .replaceAll(r'\\[', r'\[')
      .replaceAll(r'\\]', r'\]');

  String _normalizeEditableText(String text) => text
      .replaceAll(r'\\(', r'\(')
      .replaceAll(r'\\)', r'\)')
      .replaceAll(r'\\[', r'\[')
      .replaceAll(r'\\]', r'\]');

  List<QuestionSplitDraft> _draftsForSelected(QuestionSplitSession session) {
    return session.drafts
        .where((draft) => draft.canSave && draft.selected)
        .toList();
  }

  Future<void> _saveQuestions(List<QuestionSplitDraft> draftsToSave) async {
    final session = ref.read(currentQuestionSplitSessionProvider);
    if (session == null || _isSaving) return;

    final normalizedDrafts = draftsToSave
        .map(
            (draft) => draft.copyWith(text: _normalizeEditableText(draft.text)))
        .toList();
    if (normalizedDrafts.isEmpty) {
      setState(() => _errorMessage = '请至少选择一道解析成功的题目后再保存');
      return;
    }

    if (normalizedDrafts.any((draft) => draft.text.trim().isEmpty)) {
      setState(() => _errorMessage = '保存范围内有空内容，请补充后再保存');
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final confirmed = await _confirmSave(session, normalizedDrafts.length);
    if (confirmed != true) return;

    setState(() {
      _isSaving = true;
      _errorMessage = null;
    });

    try {
      final records = normalizedDrafts.asMap().entries.map((entry) {
        return buildSplitQuestionRecord(
          source: session.source,
          draft: entry.value,
          sortOrder: entry.value.originalOrder,
        );
      }).toList();

      await ref.read(questionRepositoryProvider).saveDrafts(records);
      try {
        await ref
            .read(scanTaskLifecycleServiceProvider)
            .completeSaved(session.source.id);
      } catch (_) {
        // The saved notebook records remain authoritative.
      }
      invalidateQuestionList(ref);
      ref.invalidate(scanTaskCountProvider);
      ref.read(currentQuestionProvider.notifier).state = records.first;
      ref.read(currentQuestionSplitSessionProvider.notifier).state = null;
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('已保存 ${records.length} 道题到错题本'),
          duration: const Duration(seconds: 2),
        ),
      );
      router.go('/notebook/question/${records.first.id}');
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSaving = false;
        _errorMessage = '保存失败：$e';
      });
    }
  }

  Future<bool?> _confirmSave(
    QuestionSplitSession session,
    int selectedCount,
  ) {
    if (session.failedCandidateCount == 0) return Future<bool?>.value(true);
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存已解析题目'),
        content: Text(
          '将保存 $selectedCount 道已解析题。另 ${session.failedCandidateCount} 道未解析成功的题不会保存，本次扫描结果将结束。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('返回处理'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('继续保存'),
          ),
        ],
      ),
    );
  }
}

class _FormulaPreviewCard extends StatelessWidget {
  const _FormulaPreviewCard({required this.content, this.contentFormat});

  final String content;
  final QuestionContentFormat? contentFormat;

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    final trimmed = content.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: p.subtle,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '公式预览',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: p.inkMuted,
            ),
          ),
          const SizedBox(height: 6),
          trimmed.isEmpty
              ? Text(
                  '暂无可预览内容',
                  style: TextStyle(fontSize: 13, color: p.inkMuted),
                )
              : MathContentView(
                  trimmed,
                  contentFormat: contentFormat,
                  style: TextStyle(fontSize: 14, color: p.inkPrimary),
                ),
        ],
      ),
    );
  }
}
