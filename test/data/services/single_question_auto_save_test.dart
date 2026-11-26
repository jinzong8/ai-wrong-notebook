import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/data/remote/ai/ai_analysis_service.dart';
import 'package:smart_wrong_notebook/src/data/repositories/question_repository.dart';
import 'package:smart_wrong_notebook/src/data/repositories/settings_repository.dart';
import 'package:smart_wrong_notebook/src/data/services/app_analysis_job_runner.dart';
import 'package:smart_wrong_notebook/src/data/services/scan_task_lifecycle_service.dart';
import 'package:smart_wrong_notebook/src/data/services/single_question_auto_save.dart';
import 'package:smart_wrong_notebook/src/domain/models/ai_provider_config.dart';
import 'package:smart_wrong_notebook/src/domain/models/ai_task_spec.dart';
import 'package:smart_wrong_notebook/src/domain/models/analysis_job.dart';
import 'package:smart_wrong_notebook/src/domain/models/analysis_result.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/mastery_level.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_split_result.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/domain/services/ai_route_resolver.dart';
import 'package:smart_wrong_notebook/src/domain/services/analysis_job_queue_executor.dart';
import 'package:smart_wrong_notebook/src/features/analysis/presentation/analysis_loading_screen.dart';
import 'package:smart_wrong_notebook/src/features/analysis/presentation/question_text_correction_screen.dart';
import 'package:smart_wrong_notebook/src/features/notebook/presentation/question_detail_screen.dart';

class _ConfiguredSettingsRepository implements SettingsRepository {
  @override
  Future<AiProviderConfig?> getAiProviderConfig() async =>
      const AiProviderConfig(
        id: 'test',
        displayName: 'Test',
        baseUrl: 'https://api.test.com',
        model: 'gpt-5',
        apiKey: 'sk-test',
      );

  @override
  Future<String?> getString(String key) async => null;

  @override
  Future<void> saveAiProviderConfig(AiProviderConfig config) async {}

  @override
  Future<void> setString(String key, String value) async {}
}

void main() {
  group('single_question_auto_save helpers', () {
    test('detects single vs multi-question analysis results accurately', () {
      final single = QuestionRecord.draft(
        id: 'q-1',
        imagePath: '/tmp/q1.jpg',
        subject: Subject.math,
        recognizedText: '解方程 x+1=3',
      );
      expect(isMultiQuestionAnalysisResult(single), isFalse);

      final singleWithFallbackSplit = single.copyWith(
        splitResult: const QuestionSplitResult(
          sourceText: '解方程 x+1=3',
          strategy: QuestionSplitStrategy.fallback,
          candidates: <QuestionSplitCandidate>[
            QuestionSplitCandidate(
              id: 'c-1',
              order: 1,
              text: '解方程 x+1=3',
              strategy: QuestionSplitStrategy.fallback,
            ),
          ],
        ),
      );
      expect(isMultiQuestionAnalysisResult(singleWithFallbackSplit), isFalse);

      final multi = single.copyWith(
        splitResult: const QuestionSplitResult(
          sourceText: '1. 第一题\n2. 第二题',
          strategy: QuestionSplitStrategy.numbered,
          candidates: <QuestionSplitCandidate>[
            QuestionSplitCandidate(
              id: 'c-1',
              order: 1,
              text: '1. 第一题',
              strategy: QuestionSplitStrategy.numbered,
            ),
            QuestionSplitCandidate(
              id: 'c-2',
              order: 2,
              text: '2. 第二题',
              strategy: QuestionSplitStrategy.numbered,
            ),
          ],
        ),
      );
      expect(isMultiQuestionAnalysisResult(multi), isTrue);
    });

    test(
        'prepareSingleQuestionForSave clears batch metadata for new single questions and preserves user metadata on re-analysis',
        () async {
      final repo = InMemoryQuestionRepository();
      final fresh = QuestionRecord.draft(
        id: 'q-solo',
        imagePath: '/tmp/solo.jpg',
        subject: Subject.unknown,
        recognizedText: '已知 2x = 6，求 x',
      ).copyWith(
        contentStatus: ContentStatus.ready,
        splitResult: const QuestionSplitResult(
          sourceText: '已知 2x = 6，求 x',
          strategy: QuestionSplitStrategy.fallback,
          candidates: <QuestionSplitCandidate>[
            QuestionSplitCandidate(
              id: 'c-1',
              order: 1,
              text: '已知 2x = 6，求 x',
              strategy: QuestionSplitStrategy.fallback,
            ),
          ],
        ),
        analysisResult: const AnalysisResult(
          subject: Subject.math,
          finalAnswer: 'x = 3',
          steps: <String>['两边同时除以 2'],
          aiTags: <String>['方程'],
          knowledgePoints: <String>['一元一次方程'],
          mistakeReason: '计算失误',
          studyAdvice: '细心验算',
        ),
        aiTags: const <String>['方程'],
        aiKnowledgePoints: const <String>['一元一次方程'],
      );

      final firstSaved = await autoSaveSingleQuestion(
        analyzed: fresh,
        repository: repo,
      );
      expect(firstSaved.parentQuestionId, isNull);
      expect(firstSaved.rootQuestionId, isNull);
      expect(firstSaved.splitOrder, isNull);
      expect(firstSaved.splitResult, isNull);
      expect(firstSaved.subject, Subject.math);
      expect(await repo.listAll(), hasLength(1));

      // Simulate user adding custom tags & reviewing before re-analyzing.
      final reviewed = firstSaved.copyWith(
        customTags: const <String>['期中错题'],
        reviewCount: 2,
        masteryLevel: MasteryLevel.reviewing,
      );
      await repo.update(reviewed);

      final reanalyzed = reviewed
          .createReanalysisDraft(correctedText: '已知 2x = 8，求 x')
          .copyWith(
            contentStatus: ContentStatus.ready,
            analysisResult: const AnalysisResult(
              subject: Subject.math,
              finalAnswer: 'x = 4',
              steps: <String>['两边同时除以 2 得 x = 4'],
              aiTags: <String>['一元一次方程'],
              knowledgePoints: <String>['等式性质'],
              mistakeReason: '抄错数字',
              studyAdvice: '核对题干',
            ),
            aiTags: const <String>['一元一次方程'],
            aiKnowledgePoints: const <String>['等式性质'],
          );

      final updated = await autoSaveSingleQuestion(
        analyzed: reanalyzed,
        repository: repo,
      );
      final all = await repo.listAll();
      expect(all, hasLength(1));
      expect(updated.id, 'q-solo');
      expect(updated.correctedText, '已知 2x = 8，求 x');
      expect(updated.analysisResult?.finalAnswer, 'x = 4');
      expect(updated.customTags, <String>['期中错题']);
      expect(updated.reviewCount, 2);
      expect(updated.masteryLevel, MasteryLevel.reviewing);
      expect(updated.createdAt, firstSaved.createdAt);
    });

    test(
        'AppAnalysisJobRunner auto-saves single question but holds multi-question for split confirmation',
        () async {
      final repo = InMemoryQuestionRepository();
      final settingsRepo = _ConfiguredSettingsRepository();

      AnalysisJob makeFirstPassJob(QuestionRecord q) {
        final spec = AiTaskSpec(
          id: '${q.id}:first-pass',
          parentQuestionId: q.id,
          type: AiTaskType.firstPassAnalysis,
          workloadProfile: AiWorkloadProfile.routine,
          requiredCapabilities: const <AiCapability>{
            AiCapability.structuredOutput,
          },
          qualityPolicy: AiQualityPolicy.reliableRequired,
          queuePriority: AiQueuePriority.firstPass,
        );
        const resolver = SingleProviderAiRouteResolver(
          routeId: 'default:gpt-5',
          providerConfigId: 'default',
          modelName: 'gpt-5',
        );
        return AnalysisJob.queued(
          id: spec.id,
          idempotencyKey: spec.id,
          taskSpec: spec,
          route: resolver.resolve(spec, promptVersion: 'analysis-v1'),
          payloadJson: jsonEncode(<String, dynamic>{'question': q.toJson()}),
          createdAt: DateTime(2026, 7, 15, 10),
        ).copyWith(status: AnalysisJobStatus.running, attemptCount: 1);
      }

      // 1. Single question -> auto-saved directly into repo.
      final singleAi = TestAiAnalysisService(
        settingsRepository: settingsRepo,
        extractionResult: const AiQuestionExtractionResult(
          extractedQuestionText: '求 x+2=5 的解',
          normalizedQuestionText: '求 x+2=5 的解',
          subject: Subject.math,
        ),
        analysisResultValue: const AnalysisResult(
          subject: Subject.math,
          finalAnswer: 'x = 3',
          steps: <String>['移项得 x = 3'],
          aiTags: <String>['方程'],
          knowledgePoints: <String>['一元一次方程'],
          mistakeReason: '粗心',
          studyAdvice: '验算',
        ),
      );
      final singleRunner = AppAnalysisJobRunner(
        singleAi,
        questionRepository: repo,
      );
      final qSingle = QuestionRecord.draft(
        id: 'q-bg-single',
        imagePath: '/tmp/single.jpg',
        subject: Subject.math,
        recognizedText: '求 x+2=5 的解',
      );
      await singleRunner.run(AnalysisJobExecutionContext(
        job: makeFirstPassJob(qSingle),
        dependencyResults: const <String, String>{},
      ));
      final savedAfterSingle = await repo.listAll();
      expect(savedAfterSingle, hasLength(1));
      expect(savedAfterSingle.single.id, 'q-bg-single');
      expect(savedAfterSingle.single.splitOrder, isNull);

      // 2. Multi-question -> NOT auto-saved; awaits split confirmation.
      final multiAi = TestAiAnalysisService(
        settingsRepository: settingsRepo,
        extractionResult: const AiQuestionExtractionResult(
          extractedQuestionText: '1. 第一题\n2. 第二题',
          normalizedQuestionText: '1. 第一题\n2. 第二题',
          subject: Subject.math,
        ),
        analysisResultValue: const AnalysisResult(
          subject: Subject.math,
          finalAnswer: '默认',
          steps: <String>['步骤'],
          aiTags: <String>[],
          knowledgePoints: <String>[],
          mistakeReason: '',
          studyAdvice: '',
        ),
        candidateAnalysisResults: const <AnalysisResult>[
          AnalysisResult(
            subject: Subject.math,
            finalAnswer: '答案1',
            steps: <String>['步骤1'],
            aiTags: <String>['标签1'],
            knowledgePoints: <String>['考点1'],
            mistakeReason: '错因1',
            studyAdvice: '建议1',
          ),
          AnalysisResult(
            subject: Subject.math,
            finalAnswer: '答案2',
            steps: <String>['步骤2'],
            aiTags: <String>['标签2'],
            knowledgePoints: <String>['考点2'],
            mistakeReason: '错因2',
            studyAdvice: '建议2',
          ),
        ],
      );
      final multiRunner = AppAnalysisJobRunner(
        multiAi,
        questionRepository: repo,
      );
      final qMulti = QuestionRecord.draft(
        id: 'q-bg-multi',
        imagePath: '/tmp/multi.jpg',
        subject: Subject.math,
        recognizedText: '1. 第一题\n2. 第二题',
      );
      await multiRunner.run(AnalysisJobExecutionContext(
        job: makeFirstPassJob(qMulti),
        dependencyResults: const <String, String>{},
      ));
      // Still only the single question in repository!
      final savedAfterMulti = await repo.listAll();
      expect(savedAfterMulti, hasLength(1));
      expect(savedAfterMulti.single.id, 'q-bg-single');
    });
  });

  group('QuestionDetailScreen in-place re-analysis flow', () {
    testWidgets(
        'needsReview saved question can correct text and re-analyze in place without duplicating',
        (tester) async {
      final repo = InMemoryQuestionRepository();
      final settingsRepo = _ConfiguredSettingsRepository();
      final aiService = TestAiAnalysisService(
        settingsRepository: settingsRepo,
        extractionResult: const AiQuestionExtractionResult(
          extractedQuestionText: 'unused',
          normalizedQuestionText: 'unused',
          subject: Subject.math,
        ),
        analysisResultValue: const AnalysisResult(
          subject: Subject.math,
          finalAnswer: '面积 = 25',
          steps: <String>['边长为 5，正方形面积为 25'],
          aiTags: <String>['几何'],
          knowledgePoints: <String>['正方形面积'],
          mistakeReason: '公式记忆错误',
          studyAdvice: '熟记面积公式',
        ),
      );

      final initial = QuestionRecord.draft(
        id: 'q-reanalyze-1',
        imagePath: '',
        subject: Subject.math,
        recognizedText: '正方形边长为 3，求面积',
      ).copyWith(
        contentStatus: ContentStatus.ready,
        customTags: const <String>['错题标注'],
        analysisResult: const AnalysisResult(
          subject: Subject.math,
          finalAnswer: '9',
          steps: <String>['3×3=9'],
          aiTags: <String>['几何'],
          knowledgePoints: <String>['面积'],
          mistakeReason: '识别存疑',
          studyAdvice: '请核对数字',
          consistencyStatus: AnalysisConsistencyStatus.needsReview,
          consistencyNote: '图中边长数字可能为 5，请核对',
          visualAssumptionStatus: VisualAssumptionStatus.needsReview,
        ),
      );
      await repo.saveDraft(initial);

      final container = ProviderContainer(
        overrides: <Override>[
          questionRepositoryProvider.overrideWithValue(repo),
          settingsRepositoryProvider.overrideWithValue(settingsRepo),
          aiAnalysisServiceProvider.overrideWithValue(aiService),
          scanTaskLifecycleServiceProvider.overrideWithValue(
            ScanTaskLifecycleService(analysisJobs: null, questions: repo),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(currentQuestionProvider.notifier).state = initial;

      final router = GoRouter(
        initialLocation: '/notebook/question/q-reanalyze-1',
        routes: <RouteBase>[
          GoRoute(
            path: '/notebook',
            builder: (_, __) => const Scaffold(body: Text('NOTEBOOK')),
          ),
          GoRoute(
            path: '/notebook/question/:id',
            builder: (_, __) => const QuestionDetailScreen(),
          ),
          GoRoute(
            path: '/analysis/text-correction',
            builder: (_, state) => QuestionTextCorrectionScreen(
              returnToDetail: state.uri.queryParameters['from'] == 'detail',
            ),
          ),
          GoRoute(
            path: '/analysis/loading',
            builder: (_, state) => AnalysisLoadingScreen(
              isReanalysis: state.uri.queryParameters['reanalysis'] == '1',
            ),
          ),
          GoRoute(
            path: '/analysis/result',
            builder: (_, __) => const Scaffold(body: Text('RESULT')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();

      // Detail screen offers both 重新拍照 and 修改题干 on the needsReview answer card!
      expect(find.byKey(const Key('detail-retake-button')), findsOneWidget);
      expect(find.text('重新拍照'), findsOneWidget);
      expect(find.byKey(const Key('detail-edit-text-button')), findsOneWidget);
      expect(find.text('修改题干'), findsOneWidget);
      await tester.ensureVisible(find.text('修改题干'));
      await tester.tap(find.text('修改题干'));
      await tester.pumpAndSettle();

      expect(find.text('核对题干'), findsOneWidget);
      expect(find.text('图片不清？重拍'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '正方形边长为 5，求面积');
      await tester.tap(find.text('重新解析'));
      await tester.pump();
      await tester.pump();
      await tester.pumpAndSettle();

      // Returns directly to QuestionDetailScreen with updated in-place record!
      expect(find.text('错题详情'), findsOneWidget);
      expect(find.textContaining('面积 = 25'), findsOneWidget);
      final allSaved = await repo.listAll();
      expect(allSaved, hasLength(1));
      expect(allSaved.single.id, 'q-reanalyze-1');
      expect(allSaved.single.correctedText, '正方形边长为 5，求面积');
      expect(allSaved.single.customTags, <String>['错题标注']);
      expect(allSaved.single.splitOrder, isNull);
    });

    testWidgets(
        'needsReview detail 重新拍照 opens camera in in-place replace mode and overflow menu also exposes retake',
        (tester) async {
      final repo = InMemoryQuestionRepository();
      final settingsRepo = _ConfiguredSettingsRepository();
      final initial = QuestionRecord.draft(
        id: 'q-retake-detail-1',
        imagePath: '',
        subject: Subject.math,
        recognizedText: '不等式组 D 选项被裁断',
      ).copyWith(
        contentStatus: ContentStatus.ready,
        analysisResult: const AnalysisResult(
          subject: Subject.math,
          finalAnswer: 'a >= 2',
          steps: <String>['解不等式得 x > 2'],
          aiTags: <String>['不等式组'],
          knowledgePoints: <String>['公共解集'],
          mistakeReason: 'D 选项被截断',
          studyAdvice: '核对 D 选项完整内容',
          consistencyStatus: AnalysisConsistencyStatus.needsReview,
          consistencyNote: '如需确定选项字母，应核对 D 选项的完整内容。',
          visualAssumptionStatus: VisualAssumptionStatus.needsReview,
        ),
      );
      await repo.saveDraft(initial);

      final container = ProviderContainer(
        overrides: <Override>[
          questionRepositoryProvider.overrideWithValue(repo),
          settingsRepositoryProvider.overrideWithValue(settingsRepo),
        ],
      );
      addTearDown(container.dispose);
      container.read(currentQuestionProvider.notifier).state = initial;

      final router = GoRouter(
        initialLocation: '/notebook/question/q-retake-detail-1',
        routes: <RouteBase>[
          GoRoute(
            path: '/notebook/question/:id',
            builder: (_, __) => const QuestionDetailScreen(),
          ),
          GoRoute(
            path: '/capture/camera',
            builder: (_, __) => const Scaffold(body: Text('CAMERA_RETAKE')),
          ),
        ],
      );
      addTearDown(router.dispose);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byKey(const Key('detail-retake-button')));
      await tester.tap(find.byKey(const Key('detail-retake-button')));
      await tester.pumpAndSettle();

      expect(find.text('CAMERA_RETAKE'), findsOneWidget);
      final target = container.read(retakeCaptureTargetProvider);
      expect(target, isNotNull);
      expect(target!.isInPlaceReplace, isTrue);
      expect(target.replaceQuestionId, 'q-retake-detail-1');
      expect(target.returnRoute, '/notebook/question/q-retake-detail-1');
      expect(target.subject, Subject.math);
    });

    test(
        'autoSaveSingleQuestion deletes replaced orphaned image but preserves shared batch image',
        () async {
      final tempDir = Directory.systemTemp.createTempSync('retake_cleanup_');
      try {
        final oldStandalone = File('${tempDir.path}/old_standalone.jpg')
          ..writeAsBytesSync(<int>[1, 2, 3]);
        final newStandalone = File('${tempDir.path}/new_standalone.jpg')
          ..writeAsBytesSync(<int>[4, 5, 6]);
        final sharedBatch = File('${tempDir.path}/shared_batch.jpg')
          ..writeAsBytesSync(<int>[7, 8, 9]);
        final newSibling = File('${tempDir.path}/new_sibling.jpg')
          ..writeAsBytesSync(<int>[10, 11, 12]);

        final repo = InMemoryQuestionRepository();
        final originalTime = DateTime(2026, 11, 20, 14, 30);

        final standalone = QuestionRecord.fromJson(<String, dynamic>{
          ...QuestionRecord.draft(
            id: 'q-solo',
            imagePath: oldStandalone.path,
            subject: Subject.math,
            recognizedText: '旧图题目',
          ).toJson(),
          'createdAt': originalTime.toIso8601String(),
          'customTags': <String>['重点'],
          'reviewCount': 3,
        });
        await repo.saveDraft(standalone);

        final replacedSolo = await autoSaveSingleQuestion(
          analyzed: QuestionRecord.draft(
            id: 'q-solo',
            imagePath: newStandalone.path,
            subject: Subject.math,
            recognizedText: '清晰新图题目',
          ).copyWith(contentStatus: ContentStatus.ready),
          repository: repo,
        );

        expect(replacedSolo.imagePath, newStandalone.path);
        expect(replacedSolo.createdAt, originalTime);
        expect(replacedSolo.customTags, <String>['重点']);
        expect(replacedSolo.reviewCount, 3);
        expect(oldStandalone.existsSync(), isFalse);
        expect(newStandalone.existsSync(), isTrue);

        // Shared image between two batch siblings must NOT be deleted when only one sibling is retaken.
        final sib1 = QuestionRecord.draft(
          id: 'q-sib-1',
          imagePath: sharedBatch.path,
          subject: Subject.math,
          recognizedText: '子题 1',
        );
        final sib2 = QuestionRecord.draft(
          id: 'q-sib-2',
          imagePath: sharedBatch.path,
          subject: Subject.math,
          recognizedText: '子题 2',
        );
        await repo.saveDrafts(<QuestionRecord>[sib1, sib2]);

        await autoSaveSingleQuestion(
          analyzed: QuestionRecord.draft(
            id: 'q-sib-1',
            imagePath: newSibling.path,
            subject: Subject.math,
            recognizedText: '子题 1 清晰版',
          ).copyWith(contentStatus: ContentStatus.ready),
          repository: repo,
        );

        expect(sharedBatch.existsSync(), isTrue);
        expect(newSibling.existsSync(), isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });
  });
}
