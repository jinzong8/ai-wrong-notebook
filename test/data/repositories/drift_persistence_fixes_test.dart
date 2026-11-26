import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/data/local/app_database.dart' as db;
import 'package:smart_wrong_notebook/src/data/remote/ai/ai_analysis_service.dart';
import 'package:smart_wrong_notebook/src/data/repositories/drift_analysis_job_repository.dart';
import 'package:smart_wrong_notebook/src/data/repositories/drift_question_repository.dart';
import 'package:smart_wrong_notebook/src/data/repositories/drift_review_log_repository.dart';
import 'package:smart_wrong_notebook/src/data/repositories/question_repository.dart';
import 'package:smart_wrong_notebook/src/data/repositories/settings_repository.dart';
import 'package:smart_wrong_notebook/src/data/services/ai_learning_task_coordinator.dart';
import 'package:smart_wrong_notebook/src/data/services/app_analysis_job_runner.dart';
import 'package:smart_wrong_notebook/src/data/services/scan_task_lifecycle_service.dart';
import 'package:smart_wrong_notebook/src/domain/models/ai_provider_config.dart';
import 'package:smart_wrong_notebook/src/domain/models/ai_task_spec.dart';
import 'package:smart_wrong_notebook/src/domain/models/analysis_job.dart';
import 'package:smart_wrong_notebook/src/domain/models/analysis_result.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/mastery_level.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/review_log.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/domain/services/ai_route_resolver.dart';
import 'package:smart_wrong_notebook/src/domain/services/analysis_job_queue_executor.dart';
import 'package:smart_wrong_notebook/src/features/settings/presentation/data_management_screen.dart';
import 'package:smart_wrong_notebook/src/features/settings/presentation/prompt_settings_screen.dart';

class _LoopbackHttpOverrides extends HttpOverrides {}

class _MidFlightDeleteRunner implements AnalysisJobRunner {
  _MidFlightDeleteRunner({
    required this.onStarted,
    required this.resumeCompleter,
  });

  final Future<void> Function(AnalysisJob job) onStarted;
  final Completer<void> resumeCompleter;

  @override
  Future<String> run(AnalysisJobExecutionContext context) async {
    await onStarted(context.job);
    await resumeCompleter.future;
    return '{"status":"ok"}';
  }
}

class _SlowAiService extends AiAnalysisService {
  _SlowAiService({
    required super.settingsRepository,
    required this.onStarted,
    required this.gate,
  });

  final void Function() onStarted;
  final Completer<void> gate;

  @override
  Future<AiQuestionExtractionResult> extractQuestionStructure({
    required String subjectName,
    required String imagePath,
    String textHint = '',
  }) async {
    onStarted();
    await gate.future;
    return AiQuestionExtractionResult(
      extractedQuestionText: textHint.isEmpty ? '求 x+1=2' : textHint,
      normalizedQuestionText: textHint.isEmpty ? '求 x+1=2' : textHint,
      subject: Subject.math,
    );
  }

  @override
  Future<AnalysisResult> analyzeExtractedQuestion({
    required String correctedText,
    required String subjectName,
    String? imagePath,
  }) async {
    onStarted();
    await gate.future;
    return const AnalysisResult(
      subject: Subject.math,
      finalAnswer: 'x = 1',
      steps: <String>['移项得 x = 1'],
      aiTags: <String>['方程'],
      knowledgePoints: <String>['一元一次方程'],
      mistakeReason: '粗心',
      studyAdvice: '验算',
    );
  }

  @override
  Future<String> answerQuestionFollowUp({
    required QuestionRecord question,
    required String userQuestion,
    List<AiFollowUpMessage> history = const <AiFollowUpMessage>[],
  }) async {
    onStarted();
    await gate.future;
    return '答疑回复';
  }
}

AnalysisJob _makeJob({
  required String id,
  required String parentQuestionId,
  required AiTaskType type,
  String payloadJson = '{}',
}) {
  final spec = AiTaskSpec(
    id: id,
    parentQuestionId: parentQuestionId,
    type: type,
    workloadProfile: AiWorkloadProfile.routine,
    requiredCapabilities: const <AiCapability>{AiCapability.structuredOutput},
    qualityPolicy: AiQualityPolicy.reliableRequired,
    queuePriority: AiQueuePriority.firstPass,
  );
  const resolver = SingleProviderAiRouteResolver(
    routeId: 'default:gpt-5',
    providerConfigId: 'default',
    modelName: 'gpt-5',
  );
  return AnalysisJob.queued(
    id: id,
    idempotencyKey: 'idem-$id',
    taskSpec: spec,
    route: resolver.resolve(spec, promptVersion: '${type.name}-v1'),
    payloadJson: payloadJson,
    createdAt: DateTime(2026, 7, 20, 12),
  );
}

QuestionRecord _buildQuestion({
  required String id,
  String imagePath = '',
  DateTime? createdAt,
  QuestionContentFormat contentFormat = QuestionContentFormat.plain,
  bool isFavorite = false,
  List<String> tags = const <String>[],
  List<String> aiTags = const <String>[],
  List<String> aiKnowledgePoints = const <String>[],
  List<String> customTags = const <String>[],
}) {
  final ts = createdAt ?? DateTime(2026, 7, 20, 10);
  return QuestionRecord(
    id: id,
    imagePath: imagePath,
    subject: Subject.math,
    extractedQuestionText: '已知函数 f(x)',
    normalizedQuestionText: '已知函数 f(x)',
    contentFormat: contentFormat,
    tags: tags,
    createdAt: ts,
    updatedAt: ts,
    lastReviewedAt: null,
    reviewCount: 0,
    isFavorite: isFavorite,
    contentStatus: ContentStatus.ready,
    masteryLevel: MasteryLevel.reviewing,
    analysisResult: null,
    aiTags: aiTags,
    aiKnowledgePoints: aiKnowledgePoints,
    customTags: customTags,
  );
}

void main() {
  group('DriftQuestionRepository persistence fixes', () {
    late db.AppDatabase database;
    late DriftQuestionRepository questionRepo;
    late Directory tempDir;

    setUp(() async {
      database = db.AppDatabase.memory();
      questionRepo = DriftQuestionRepository(database);
      tempDir = await Directory.systemTemp.createTemp('drift-fixes-test-');
    });

    tearDown(() async {
      await database.close();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
        'round-trips comma-containing knowledgePoints/tags, contentFormat, and isFavorite losslessly',
        () async {
      final record = _buildQuestion(
        id: 'q-comma-1',
        contentFormat: QuestionContentFormat.latexMixed,
        isFavorite: true,
        tags: const <String>['错题集A, 第一章', '高频考点'],
        aiTags: const <String>['函数, 单调性', '数形结合'],
        aiKnowledgePoints: const <String>[
          '区间 (-∞, 0), 点(x, y)',
          '对称轴 x = -b/(2a), 顶点坐标',
        ],
        customTags: const <String>['期中重点, 必考', '二刷'],
      );

      await questionRepo.saveDraft(record);
      final loaded = await questionRepo.getById('q-comma-1');

      expect(loaded, isNotNull);
      expect(loaded!.contentFormat, QuestionContentFormat.latexMixed);
      expect(loaded.isFavorite, isTrue);
      expect(loaded.tags, const <String>['错题集A, 第一章', '高频考点']);
      expect(loaded.aiTags, const <String>['函数, 单调性', '数形结合']);
      expect(loaded.aiKnowledgePoints, const <String>[
        '区间 (-∞, 0), 点(x, y)',
        '对称轴 x = -b/(2a), 顶点坐标',
      ]);
      expect(loaded.customTags, const <String>['期中重点, 必考', '二刷']);
    });

    test('decodes legacy comma-separated rows and sorts listAll newest first',
        () async {
      final older = DateTime(2026, 7, 1, 9);
      final newer = DateTime(2026, 7, 15, 9);

      await database.into(database.questionRecords).insert(
            db.QuestionRecordsCompanion.insert(
              id: 'legacy-older',
              subject: Subject.math.name,
              originalText: '旧题',
              correctedText: '旧题',
              masteryLevel: MasteryLevel.newQuestion.name,
              contentStatus: ContentStatus.ready.name,
              createdAt: older,
              updatedAt: older,
              tags: const Value('tag1,tag2'),
              aiTags: const Value('代数,几何'),
              aiKnowledgePoints: const Value('勾股定理,全等三角形'),
              customTags: const Value('错题'),
            ),
          );

      await questionRepo.saveDraft(
        _buildQuestion(id: 'modern-newer', createdAt: newer),
      );

      final all = await questionRepo.listAll();
      expect(all.map((q) => q.id).toList(), <String>[
        'modern-newer',
        'legacy-older',
      ]);

      final legacy = all.last;
      expect(legacy.tags, const <String>['tag1', 'tag2']);
      expect(legacy.aiTags, const <String>['代数', '几何']);
      expect(legacy.aiKnowledgePoints, const <String>['勾股定理', '全等三角形']);
      expect(legacy.customTags, const <String>['错题']);
      expect(legacy.contentFormat, QuestionContentFormat.plain);
      expect(legacy.isFavorite, isFalse);
    });

    test(
        'delete removes unreferenced image file while preserving shared batch image',
        () async {
      final soloImage = File('${tempDir.path}/solo.jpg');
      final sharedImage = File('${tempDir.path}/shared_batch.jpg');
      await soloImage.writeAsString('solo-bytes');
      await sharedImage.writeAsString('shared-bytes');

      await questionRepo.saveDraft(
        _buildQuestion(id: 'q-solo', imagePath: soloImage.path),
      );
      await questionRepo.saveDraft(
        _buildQuestion(id: 'q-batch-1', imagePath: sharedImage.path),
      );
      await questionRepo.saveDraft(
        _buildQuestion(id: 'q-batch-2', imagePath: sharedImage.path),
      );

      // Deleting solo question removes its image file.
      await questionRepo.delete('q-solo');
      expect(await soloImage.exists(), isFalse);

      // Deleting one child of a shared batch preserves the shared image.
      await questionRepo.delete('q-batch-1');
      expect(await sharedImage.exists(), isTrue);

      // Deleting the final question referencing the batch image deletes it.
      await questionRepo.delete('q-batch-2');
      expect(await sharedImage.exists(), isFalse);
    });
  });

  group('DriftReviewLogRepository CRUD, migration, and cascade delete', () {
    late db.AppDatabase database;
    late DriftQuestionRepository questionRepo;
    late DriftReviewLogRepository reviewLogRepo;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      database = db.AppDatabase.memory();
      questionRepo = DriftQuestionRepository(database);
      reviewLogRepo = DriftReviewLogRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test('supports insert, getByQuestionId, listAll, clear, and cascade delete',
        () async {
      await questionRepo.saveDraft(_buildQuestion(id: 'q-1'));
      await questionRepo.saveDraft(_buildQuestion(id: 'q-2'));

      final log1 = ReviewLog(
        id: 'log-uuid-1',
        questionRecordId: 'q-1',
        reviewedAt: DateTime(2026, 7, 20, 10, 0),
        result: 'reviewing',
        masteryAfter: MasteryLevel.reviewing,
      );
      final log2 = ReviewLog(
        id: 'log-uuid-2',
        questionRecordId: 'q-1',
        reviewedAt: DateTime(2026, 7, 20, 11, 0),
        result: 'mastered',
        masteryAfter: MasteryLevel.mastered,
      );
      final log3 = ReviewLog(
        id: 'log-uuid-3',
        questionRecordId: 'q-2',
        reviewedAt: DateTime(2026, 7, 20, 12, 0),
        result: 'reviewing',
        masteryAfter: MasteryLevel.reviewing,
      );

      await reviewLogRepo.insert(log1);
      await reviewLogRepo.insert(log2);
      await reviewLogRepo.insert(log3);

      final q1Logs = await reviewLogRepo.getByQuestionId('q-1');
      expect(q1Logs, hasLength(2));
      expect(q1Logs.first.id, 'log-uuid-2');
      expect(q1Logs.first.result, 'mastered');
      expect(q1Logs.first.masteryAfter, MasteryLevel.mastered);
      expect(q1Logs.last.id, 'log-uuid-1');
      expect(q1Logs.last.result, 'reviewing');
      expect(q1Logs.last.masteryAfter, MasteryLevel.reviewing);

      expect(await reviewLogRepo.listAll(), hasLength(3));

      // Deleting q-1 cascades review log deletion for q-1 only.
      await questionRepo.delete('q-1');
      expect(await reviewLogRepo.getByQuestionId('q-1'), isEmpty);
      final remaining = await reviewLogRepo.listAll();
      expect(remaining, hasLength(1));
      expect(remaining.single.id, 'log-uuid-3');

      // clear() empties all remaining logs.
      await reviewLogRepo.clear();
      expect(await reviewLogRepo.listAll(), isEmpty);
    });

    test('migrates legacy SharedPreferences review_logs once idempotently',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'review_logs': jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'legacy-log-1',
            'questionRecordId': 'q-legacy',
            'reviewedAt': DateTime(2026, 6, 10, 8, 30).toIso8601String(),
            'result': 'mastered',
            'masteryAfter': 'mastered',
          },
        ]),
      });

      final migratedRepo = DriftReviewLogRepository(database);
      final logs = await migratedRepo.listAll();
      expect(logs, hasLength(1));
      expect(logs.single.id, 'legacy-log-1');
      expect(logs.single.questionRecordId, 'q-legacy');
      expect(logs.single.result, 'mastered');
      expect(logs.single.masteryAfter, MasteryLevel.mastered);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('review_logs'), isNull);

      // Re-instantiating does not duplicate rows.
      final secondRepo = DriftReviewLogRepository(database);
      expect(await secondRepo.listAll(), hasLength(1));
    });
  });

  group('Zombie auto-save prevention and queue robustness', () {
    late db.AppDatabase database;
    late DriftAnalysisJobRepository jobRepo;
    late DriftQuestionRepository questionRepo;

    setUp(() {
      database = db.AppDatabase.memory();
      jobRepo = DriftAnalysisJobRepository(database);
      questionRepo = DriftQuestionRepository(database);
    });

    tearDown(() async {
      await database.close();
    });

    test(
        'AnalysisJobQueueExecutor does NOT invoke onJobCompleted or emit completedJobs when running job is deleted mid-flight',
        () async {
      final resumeCompleter = Completer<void>();
      final startedCompleter = Completer<void>();
      final completedEvents = <AnalysisJob>[];
      var onJobCompletedCount = 0;

      final executor = AnalysisJobQueueExecutor(
        repository: jobRepo,
        runner: _MidFlightDeleteRunner(
          onStarted: (job) async {
            if (!startedCompleter.isCompleted) {
              startedCompleter.complete();
            }
          },
          resumeCompleter: resumeCompleter,
        ),
        onJobCompleted: (_) async {
          onJobCompletedCount++;
        },
      );
      final sub = executor.completedJobs.listen(completedEvents.add);
      addTearDown(sub.cancel);

      final job = _makeJob(
        id: 'scan-discard-1:first-pass',
        parentQuestionId: 'scan-discard-1',
        type: AiTaskType.firstPassAnalysis,
      );
      await jobRepo.enqueue(job);

      final drainFuture = executor.processUntilIdle();
      await startedCompleter.future;

      // User discards scan task while runner is mid-flight.
      await jobRepo.deleteByParentQuestionId('scan-discard-1');
      resumeCompleter.complete();
      await drainFuture;

      expect(onJobCompletedCount, 0);
      expect(completedEvents, isEmpty);
      expect(await jobRepo.listAll(), isEmpty);
    });

    test(
        'AppAnalysisJobRunner skips autoSaveSingleQuestion when job was deleted while analyzing',
        () async {
      final settings = InMemorySettingsRepository();
      final gate = Completer<void>();
      final started = Completer<void>();
      final service = _SlowAiService(
        settingsRepository: settings,
        onStarted: () {
          if (!started.isCompleted) started.complete();
        },
        gate: gate,
      );
      final runner = AppAnalysisJobRunner(
        service,
        questionRepository: questionRepo,
        analysisJobRepository: jobRepo,
      );
      final executor = AnalysisJobQueueExecutor(
        repository: jobRepo,
        runner: runner,
      );

      final draft = _buildQuestion(id: 'q-zombie-check');
      final job = _makeJob(
        id: 'q-zombie-check:first-pass',
        parentQuestionId: draft.id,
        type: AiTaskType.firstPassAnalysis,
        payloadJson: jsonEncode(<String, dynamic>{'question': draft.toJson()}),
      );
      await jobRepo.enqueue(job);

      final drain = executor.processUntilIdle();
      await started.future;

      // Discard task mid-analysis.
      await jobRepo.deleteByParentQuestionId(draft.id);
      gate.complete();
      await drain;

      expect(await questionRepo.listAll(), isEmpty);
    });

    test(
        'QueuedAiLearningTaskCoordinator throws cancellation error instead of hanging if job row is cleared',
        () async {
      final settings = InMemorySettingsRepository();
      await settings.saveAiProviderConfig(
        const AiProviderConfig(
          id: 'default',
          displayName: 'Test',
          baseUrl: 'https://api.example.com/v1',
          model: 'gpt-5',
          apiKey: 'sk-test',
        ),
      );
      final gate = Completer<void>();
      final started = Completer<void>();
      final service = _SlowAiService(
        settingsRepository: settings,
        onStarted: () {
          if (!started.isCompleted) started.complete();
        },
        gate: gate,
      );
      final executor = AnalysisJobQueueExecutor(
        repository: jobRepo,
        runner: AppAnalysisJobRunner(service, questionRepository: questionRepo),
      );
      final coordinator = QueuedAiLearningTaskCoordinator(
        settingsRepository: settings,
        repository: jobRepo,
        executor: executor,
        questionRepository: questionRepo,
      );

      final followUpFuture = coordinator.answerQuestionFollowUp(
        question: _buildQuestion(id: 'q-followup-cancel'),
        userQuestion: '这步怎么来的？',
      );
      final expectation = expectLater(
        followUpFuture,
        throwsA(
          isA<AiAnalysisException>().having(
            (e) => e.toString(),
            'message',
            contains('AI 任务已取消或结束'),
          ),
        ),
      );

      await started.future;
      await jobRepo.clearAll();
      await expectation;
      gate.complete();
    });

    test('ScanTaskLifecycleService.countTasks counts only scan-related jobs',
        () async {
      final lifecycle = ScanTaskLifecycleService(
        analysisJobs: jobRepo,
        questions: InMemoryQuestionRepository(),
      );

      await jobRepo.enqueue(_makeJob(
        id: 'scan-1:extract',
        parentQuestionId: 'scan-1',
        type: AiTaskType.extraction,
      ));
      await jobRepo.enqueue(_makeJob(
        id: 'scan-1:first-pass',
        parentQuestionId: 'scan-1',
        type: AiTaskType.firstPassAnalysis,
      ));
      await jobRepo.enqueue(_makeJob(
        id: 'q-saved:followup',
        parentQuestionId: 'q-saved',
        type: AiTaskType.followUp,
      ));
      await jobRepo.enqueue(_makeJob(
        id: 'q-saved:exercises',
        parentQuestionId: 'q-saved-2',
        type: AiTaskType.exerciseGeneration,
      ));
      await jobRepo.enqueue(_makeJob(
        id: 'exercise-answer:judge',
        parentQuestionId: 'exercise-answer',
        type: AiTaskType.answerJudgement,
      ));

      expect(await lifecycle.countTasks(), 1);
    });
  });

  group('Prompt safety and PromptSettingsScreen', () {
    test(
        'custom system_prompt appends to built-in JSON schema instructions instead of replacing them',
        () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final capturedBodies = <String>[];

        server.listen((request) async {
          final body = await utf8.decoder.bind(request).join();
          capturedBodies.add(body);
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': jsonEncode(<String, dynamic>{
                    'subject': '数学',
                    'reconstructedQuestionText': '求 1 + 1 的值',
                    'finalAnswer': '2',
                    'finalAnswerDerivation': '由 1 + 1 = 2 得出',
                    'steps': <String>['1 + 1 = 2'],
                    'aiTags': <String>['加法'],
                    'knowledgePoints': <String>['整数加法'],
                    'mistakeReason': '粗心',
                    'studyAdvice': '细心计算',
                  }),
                },
              },
            ],
          }));
          await request.response.close();
        });

        final settings = InMemorySettingsRepository();
        await settings.saveAiProviderConfig(
          AiProviderConfig(
            id: 'local',
            displayName: 'Local',
            baseUrl: 'http://${server.address.address}:${server.port}/v1',
            model: 'gpt-5',
            apiKey: 'test-key',
          ),
        );
        await settings.setString('system_prompt', '  请面向初一学生，用温和鼓励的语气逐步讲解  ');
        await settings.setString('extraction_system_prompt', '  注意保留上下角标细节  ');

        final service = AiAnalysisService(settingsRepository: settings);
        final analysisPrompt = await service.loadAnalysisSystemPromptForTest();
        final extractionPrompt =
            await service.loadExtractionSystemPromptForTest();

        expect(analysisPrompt, contains('"finalAnswer"'));
        expect(analysisPrompt, contains('"reconstructedQuestionText"'));
        expect(analysisPrompt, contains('请面向初一学生，用温和鼓励的语气逐步讲解'));

        expect(extractionPrompt, contains('"extractedQuestionText"'));
        expect(extractionPrompt, contains('"normalizedQuestionText"'));
        expect(extractionPrompt, contains('注意保留上下角标细节'));

        final result = await service.analyzeExtractedQuestion(
          correctedText: '求 1 + 1 的值',
          subjectName: Subject.math.name,
        );
        expect(result.finalAnswer, '2');
        expect(capturedBodies, isNotEmpty);
        expect(capturedBodies.first, contains('reconstructedQuestionText'));
        expect(capturedBodies.first, contains('请面向初一学生，用温和鼓励的语气逐步讲解'));
      }, _LoopbackHttpOverrides());
    });

    testWidgets(
        'PromptSettingsScreen loads once, resets default via button, and navigates back to /settings',
        (tester) async {
      final settings = InMemorySettingsRepository();
      await settings.setString('system_prompt', '原有偏好');

      final router = GoRouter(
        initialLocation: '/settings/prompts',
        routes: <RouteBase>[
          GoRoute(
            path: '/settings',
            builder: (_, __) => const Scaffold(body: Text('设置主页')),
            routes: <RouteBase>[
              GoRoute(
                path: 'prompts',
                builder: (_, __) => const PromptSettingsScreen(),
              ),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            settingsRepositoryProvider.overrideWithValue(settings),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('原有偏好'), findsOneWidget);
      expect(find.byKey(const Key('prompt-reset-default')), findsOneWidget);

      await tester.tap(find.byKey(const Key('prompt-reset-default')));
      await tester.pumpAndSettle();

      expect(await settings.getString('system_prompt'), isEmpty);
      expect(find.text('已恢复默认提示词'), findsOneWidget);

      await tester.tap(find.byType(IconButton).first);
      await tester.pumpAndSettle();

      expect(find.text('设置主页'), findsOneWidget);
    });
  });

  group('DataManagementScreen orphan review log cleanup', () {
    testWidgets(
        'allows clearing when questions and scan tasks are zero but review logs exist',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final database = db.AppDatabase.memory();
      addTearDown(database.close);
      final reviewLogRepo = DriftReviewLogRepository(database);
      await reviewLogRepo.insert(
        ReviewLog(
          id: 'orphan-log-1',
          questionRecordId: 'deleted-q',
          reviewedAt: DateTime(2026, 7, 20),
          result: 'reviewing',
          masteryAfter: MasteryLevel.reviewing,
        ),
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: <Override>[
            questionRepositoryProvider
                .overrideWithValue(InMemoryQuestionRepository()),
            reviewLogRepositoryProvider.overrideWithValue(reviewLogRepo),
          ],
          child: const MaterialApp(home: DataManagementScreen()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('清空所有数据'));
      await tester.pumpAndSettle();

      expect(find.text('错题、复习记录与对话记录将被清空。'), findsOneWidget);

      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();

      expect(await reviewLogRepo.listAll(), isEmpty);
    });
  });
}
