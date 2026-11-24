import 'package:smart_wrong_notebook/src/data/repositories/question_repository.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';

/// Returns `true` when an analysis result contains more than one candidate
/// question and should go through the multi-question review + split-save flow.
bool isMultiQuestionAnalysisResult(QuestionRecord record) {
  return (record.splitResult?.hasMultipleCandidates ?? false) ||
      record.candidateAnalyses.length > 1;
}

/// Normalizes a single-question analysis result for direct persistence into the
/// wrong-question notebook.
///
/// When [existingSaved] is provided (for example, after in-place text
/// correction and re-analysis from `QuestionDetailScreen`), user-owned metadata
/// such as `createdAt`, `reviewCount`, `lastReviewedAt`, `isFavorite`,
/// `masteryLevel`, `customTags`, and any existing batch lineage are preserved.
///
/// Brand-new single questions are stored as standalone records with
/// `parentQuestionId`, `rootQuestionId`, and `splitOrder` cleared so they never
/// display spurious multi-question batch badges.
QuestionRecord prepareSingleQuestionForSave(
  QuestionRecord analyzed, {
  QuestionRecord? existingSaved,
}) {
  final reconstructed =
      analyzed.analysisResult?.reconstructedQuestionText.trim() ?? '';
  final normalized = analyzed.normalizedQuestionText.trim().isNotEmpty
      ? analyzed.normalizedQuestionText.trim()
      : analyzed.extractedQuestionText.trim().isNotEmpty
          ? analyzed.extractedQuestionText.trim()
          : reconstructed;
  final extracted = analyzed.extractedQuestionText.trim().isNotEmpty
      ? analyzed.extractedQuestionText.trim()
      : normalized;

  final now = DateTime.now();
  final resolvedSubject = analyzed.analysisResult?.subject ?? analyzed.subject;
  final resolvedAiTags = analyzed.aiTags.isNotEmpty
      ? analyzed.aiTags
      : (analyzed.analysisResult?.aiTags ?? const <String>[]);
  final resolvedKnowledgePoints = analyzed.aiKnowledgePoints.isNotEmpty
      ? analyzed.aiKnowledgePoints
      : (analyzed.analysisResult?.knowledgePoints ?? const <String>[]);

  return QuestionRecord(
    id: analyzed.id,
    imagePath: analyzed.imagePath.isNotEmpty
        ? analyzed.imagePath
        : (existingSaved?.imagePath ?? ''),
    subject: resolvedSubject,
    extractedQuestionText: extracted,
    normalizedQuestionText: normalized,
    contentFormat: analyzed.contentFormat,
    tags: existingSaved?.tags ?? analyzed.tags,
    createdAt: existingSaved?.createdAt ?? analyzed.createdAt,
    updatedAt: now,
    lastReviewedAt: existingSaved?.lastReviewedAt ?? analyzed.lastReviewedAt,
    reviewCount: existingSaved?.reviewCount ?? analyzed.reviewCount,
    isFavorite: existingSaved?.isFavorite ?? analyzed.isFavorite,
    contentStatus: ContentStatus.ready,
    masteryLevel: existingSaved?.masteryLevel ?? analyzed.masteryLevel,
    analysisResult: analyzed.analysisResult,
    savedExercises: analyzed.savedExercises.isNotEmpty
        ? analyzed.savedExercises
        : (existingSaved?.savedExercises ?? const []),
    aiTags: resolvedAiTags,
    aiKnowledgePoints: resolvedKnowledgePoints,
    customTags: existingSaved?.customTags ?? analyzed.customTags,
    splitResult: null,
    candidateAnalyses: const <CandidateAnalysisSnapshot>[],
    parentQuestionId: existingSaved?.parentQuestionId,
    rootQuestionId: existingSaved?.rootQuestionId,
    splitOrder: existingSaved?.splitOrder,
  );
}

/// Idempotently saves (or updates in-place) a single analyzed question directly
/// into [repository].
Future<QuestionRecord> autoSaveSingleQuestion({
  required QuestionRecord analyzed,
  required QuestionRepository repository,
}) async {
  final existing = await repository.getById(analyzed.id);
  final prepared = prepareSingleQuestionForSave(
    analyzed,
    existingSaved: existing,
  );
  await repository.saveDraft(prepared);
  return prepared;
}
