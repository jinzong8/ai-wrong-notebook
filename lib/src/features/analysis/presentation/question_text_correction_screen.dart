import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/common/widgets/app_back_scope.dart';
import 'package:smart_wrong_notebook/src/common/widgets/editorial_surface.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';

class QuestionTextCorrectionScreen extends ConsumerStatefulWidget {
  const QuestionTextCorrectionScreen({
    super.key,
    this.returnToDetail = false,
  });

  /// When `true`, the screen was opened from an already-saved
  /// `QuestionDetailScreen`, so navigating back returns to that detail view
  /// and submitting re-analyzes and updates the saved question in place.
  final bool returnToDetail;

  @override
  ConsumerState<QuestionTextCorrectionScreen> createState() =>
      _QuestionTextCorrectionScreenState();
}

class _QuestionTextCorrectionScreenState
    extends ConsumerState<QuestionTextCorrectionScreen> {
  late final TextEditingController _textController;
  String? _errorText;
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(
      text: ref.read(currentQuestionProvider)?.correctedText ?? '',
    );
  }

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _navigateBack(QuestionRecord record) {
    if (widget.returnToDetail) {
      context.go('/notebook/question/${record.id}');
    } else {
      context.go('/analysis/result');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    final record = ref.watch(currentQuestionProvider);
    if (record == null) {
      return AppBackScope(
        onBack: () => context.go('/'),
        child: Scaffold(
          backgroundColor: p.canvas,
          appBar: AppBar(
            title: const Text('核对题干'),
            leading: IconButton(
              icon: const Icon(CupertinoIcons.chevron_left),
              onPressed: () => context.go('/'),
            ),
          ),
          body: const Center(child: Text('未找到本次解析结果')),
        ),
      );
    }

    final note = record.analysisResult?.consistencyNote.trim() ?? '';
    return AppBackScope(
      enabled: !_submitting,
      onBack: () => _navigateBack(record),
      child: Scaffold(
        backgroundColor: p.canvas,
        appBar: AppBar(
          title: const Text('核对题干'),
          leading: IconButton(
            icon: const Icon(CupertinoIcons.chevron_left),
            onPressed: _submitting ? null : () => _navigateBack(record),
          ),
        ),
        body: SafeArea(
          child: Column(
            children: <Widget>[
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                  children: <Widget>[
                    if (record.imagePath.isNotEmpty &&
                        File(record.imagePath).existsSync()) ...<Widget>[
                      EditorialPhotoPreview(
                        imagePath: record.imagePath,
                        maxHeight: 156,
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (note.isNotEmpty) ...<Widget>[
                      EditorialCard(
                        accentColor: p.terracotta,
                        backgroundColor: p.terracottaTint,
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(
                              CupertinoIcons.exclamationmark_triangle,
                              size: 16,
                              color: p.terracotta,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                note,
                                style: TextStyle(
                                  fontSize: 13,
                                  height: 1.5,
                                  color: p.inkPrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    EditorialCard(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          EditorialSectionHeader(
                            title: '修正题干与条件',
                            icon: CupertinoIcons.pencil,
                            iconColor: p.cobalt,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            widget.returnToDetail
                                ? '修改识别有误的数字、符号或条件后，AI 将重新解析并原地更新这道错题。'
                                : '补充或修正识别有误的题干内容后，AI 将按新题干重新解析。',
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.45,
                              color: p.inkSecondary,
                            ),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _textController,
                            minLines: 8,
                            maxLines: 16,
                            autofocus: true,
                            enabled: !_submitting,
                            style: TextStyle(
                              fontSize: 14.5,
                              height: 1.6,
                              color: p.inkPrimary,
                            ),
                            onChanged: (_) {
                              if (_errorText != null) {
                                setState(() => _errorText = null);
                              }
                            },
                            decoration: InputDecoration(
                              labelText: '题干',
                              alignLabelWithHint: true,
                              errorText: _errorText,
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
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                decoration: BoxDecoration(
                  color: p.canvas,
                  border: Border(top: BorderSide(color: p.hairline)),
                ),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _submitting ? null : () => _submit(record),
                    icon: _submitting
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(CupertinoIcons.arrow_clockwise, size: 17),
                    label: const Text('重新解析'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _submit(QuestionRecord record) async {
    final correctedText = _textController.text.trim();
    if (correctedText.isEmpty) {
      setState(() => _errorText = '题干不能为空');
      return;
    }
    if (correctedText == record.correctedText.trim()) {
      setState(() => _errorText = '请补正或补充题干后再重新解析');
      return;
    }

    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _submitting = true);
    try {
      await ref.read(scanTaskLifecycleServiceProvider).prepareRetry(record);
      ref.read(currentQuestionSplitSessionProvider.notifier).state = null;
      ref.read(currentQuestionProvider.notifier).state =
          record.createReanalysisDraft(correctedText: correctedText);
      if (!mounted) return;

      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.go(
        widget.returnToDetail
            ? '/analysis/loading?reanalysis=1'
            : '/analysis/loading',
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _errorText = '无法创建重新解析任务：$error';
      });
    }
  }
}
