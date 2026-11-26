import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/data/remote/ai/ai_analysis_service.dart';
import 'package:smart_wrong_notebook/src/data/repositories/question_repository.dart';
import 'package:smart_wrong_notebook/src/data/services/ai_learning_task_coordinator.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/analysis_result.dart';
import 'package:smart_wrong_notebook/src/domain/models/generated_exercise.dart';
import 'package:smart_wrong_notebook/src/domain/models/mastery_level.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_split_result.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/domain/services/exercise_round_service.dart';
import 'package:smart_wrong_notebook/src/features/analysis/presentation/exercise_practice_screen.dart';
import 'package:smart_wrong_notebook/src/features/analysis/presentation/widgets/geometry_diagram_widget.dart';
import 'package:smart_wrong_notebook/src/features/ocr/presentation/question_split_confirmation_screen.dart';

QuestionRecord _makeQuestion({List<GeneratedExercise>? exercises}) {
  final now = DateTime.now();
  return QuestionRecord(
    id: 'q-1',
    imagePath: '/tmp/q-1.jpg',
    subject: Subject.math,
    extractedQuestionText: 'sample',
    normalizedQuestionText: 'corrected',
    contentFormat: QuestionContentFormat.plain,
    tags: const [],
    createdAt: now,
    updatedAt: now,
    lastReviewedAt: null,
    reviewCount: 0,
    isFavorite: false,
    contentStatus: ContentStatus.ready,
    masteryLevel: MasteryLevel.newQuestion,
    analysisResult: null,
    savedExercises: exercises ??
        [
          GeneratedExercise(
            id: 'e-1',
            questionId: 'q-1',
            generationMode: ExerciseGenerationMode.practice,
            difficulty: '简单',
            question: '1+1=?',
            options: ['A. 1', 'B. 2', 'C. 3', 'D. 4'],
            answer: 'B',
            explanation: 'basic addition',
            createdAt: now,
            order: 0,
          ),
          GeneratedExercise(
            id: 'e-2',
            questionId: 'q-1',
            generationMode: ExerciseGenerationMode.practice,
            difficulty: '中等',
            question: '2+2=?',
            options: ['A. 2', 'B. 3', 'C. 4', 'D. 5'],
            answer: 'C',
            explanation: 'basic addition',
            createdAt: now,
            order: 1,
          ),
        ],
  );
}

Widget _buildApp(QuestionRecord question, InMemoryQuestionRepository repo,
    {GoRouter? router, List<Override> overrides = const <Override>[]}) {
  return ProviderScope(
    overrides: <Override>[
      questionRepositoryProvider.overrideWithValue(repo),
      currentQuestionProvider.overrideWith((ref) => question),
      ...overrides,
    ],
    child: router != null
        ? MaterialApp.router(routerConfig: router)
        : const MaterialApp(home: ExercisePracticeScreen()),
  );
}

class _FakeLearningTaskCoordinator implements AiLearningTaskCoordinator {
  @override
  Future<String> answerQuestionFollowUp({
    required QuestionRecord question,
    required String userQuestion,
    List<AiFollowUpMessage> history = const <AiFollowUpMessage>[],
  }) async {
    return 'fake follow-up answer';
  }

  @override
  Future<List<GeneratedExercise>> generateExercisesForQuestion(
    QuestionRecord question, {
    bool forceNew = false,
  }) async {
    if (!forceNew) return question.savedExercises;
    final now = DateTime.now();
    final generated = <GeneratedExercise>[
      GeneratedExercise(
        id: 'new-exercise-1',
        questionId: question.id,
        generationMode: ExerciseGenerationMode.practice,
        difficulty: '简单',
        question: '3+3=?',
        options: ['A. 5', 'B. 6', 'C. 7', 'D. 8'],
        answer: 'B',
        explanation: 'basic addition',
        createdAt: now,
        order: 0,
      ),
      GeneratedExercise(
        id: 'new-exercise-2',
        questionId: question.id,
        generationMode: ExerciseGenerationMode.practice,
        difficulty: '中等',
        question: '4+4=?',
        options: ['A. 6', 'B. 7', 'C. 8', 'D. 9'],
        answer: 'C',
        explanation: 'basic addition',
        createdAt: now,
        order: 1,
      ),
    ];
    return appendGeneratedExerciseRound(
      questionId: question.id,
      existingExercises: question.savedExercises,
      generatedExercises: generated,
    );
  }

  @override
  Future<bool> judgeAnswer({
    required String question,
    required String userAnswer,
    required String correctAnswer,
    List<String>? options,
  }) async {
    return userAnswer == correctAnswer;
  }
}

GoRouter _practiceRouter({String initialLocation = '/exercise/practice'}) {
  return GoRouter(
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: '/exercise/practice',
        builder: (_, __) => const ExercisePracticeScreen(),
      ),
      GoRoute(
        path: '/capture/split-confirmation',
        builder: (_, __) => const QuestionSplitConfirmationScreen(),
      ),
      GoRoute(
        path: '/analysis/result',
        builder: (_, __) => const Scaffold(body: Text('analysis result')),
      ),
      GoRoute(
        path: '/notebook/question/:id',
        builder: (_, state) => Scaffold(
          body: Text('question ${state.pathParameters['id']}'),
        ),
      ),
      GoRoute(
        path: '/notebook',
        builder: (_, __) => const Scaffold(body: Text('notebook')),
      ),
    ],
  );
}

void main() {
  testWidgets('displays first exercise on load', (tester) async {
    final repo = InMemoryQuestionRepository();
    final question = _makeQuestion();
    await repo.saveDraft(question);

    await tester.pumpWidget(_buildApp(question, repo));
    await tester.pumpAndSettle();

    expect(find.text('举一反三 1/2'), findsOneWidget);
    expect(find.text('1+1=?'), findsOneWidget);
  });

  testWidgets('shows continue and save actions after finishing round',
      (tester) async {
    final repo = InMemoryQuestionRepository();
    final question = _makeQuestion();
    await repo.saveDraft(question);

    await tester.pumpWidget(_buildApp(question, repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('B'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.tap(find.text('下一题'));
    await tester.pump();
    await tester.tap(find.text('C'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.tap(find.text('完成练习'));
    await tester.pump();

    expect(find.text('举一反三完成'), findsOneWidget);
    expect(find.text('再生成一组'), findsOneWidget);
    expect(find.text('返回错题详情'), findsOneWidget);
    expect(find.text('保存这道题'), findsNothing);
    expect(find.text('本轮练习结果已保存到错题本'), findsOneWidget);

    final saved = await repo.getById('q-1');
    expect(saved?.savedExercises.length, 2);
    expect(saved?.savedExercises.every((exercise) => exercise.roundIndex == 1),
        isTrue);
    expect(
        saved?.savedExercises.every((exercise) => exercise.isCorrect == true),
        isTrue);
  });

  testWidgets('continue practice starts another persisted round',
      (tester) async {
    final repo = InMemoryQuestionRepository();
    final question = _makeQuestion();
    await repo.saveDraft(question);

    await tester.pumpWidget(_buildApp(
      question,
      repo,
      overrides: <Override>[
        aiLearningTaskCoordinatorProvider
            .overrideWithValue(_FakeLearningTaskCoordinator()),
      ],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('B'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.tap(find.text('下一题'));
    await tester.pump();
    await tester.tap(find.text('C'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.tap(find.text('完成练习'));
    await tester.pump();
    await tester.tap(find.text('再生成一组'));
    await tester.pumpAndSettle();

    expect(find.text('举一反三 1/2'), findsOneWidget);
    final saved = await repo.getById('q-1');
    expect(saved?.savedExercises.length, 4);
    expect(saved?.savedExercises.where((exercise) => exercise.roundIndex == 2),
        hasLength(2));
    expect(
        saved?.savedExercises
            .where((exercise) => exercise.roundIndex == 2)
            .every((exercise) =>
                exercise.isCorrect == null && exercise.userAnswer == null),
        isTrue);
  });

  testWidgets('save current analysis candidate selects only that draft',
      (tester) async {
    final repo = InMemoryQuestionRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        questionRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    final question = _makeQuestion().copyWith(
      splitResult: const QuestionSplitResult(
        sourceText: '第一题\n第二题',
        strategy: QuestionSplitStrategy.numbered,
        candidates: <QuestionSplitCandidate>[
          QuestionSplitCandidate(
            id: 'candidate-0',
            order: 1,
            text: '第一题',
            strategy: QuestionSplitStrategy.numbered,
          ),
          QuestionSplitCandidate(
            id: 'candidate-1',
            order: 2,
            text: '第二题',
            strategy: QuestionSplitStrategy.numbered,
          ),
        ],
      ),
      candidateAnalyses: <CandidateAnalysisSnapshot>[
        CandidateAnalysisSnapshot(
          candidateId: 'candidate-0',
          order: 1,
          questionText: '第一题',
          analysisResult: const AnalysisResult(
            finalAnswer: '第一题答案',
            steps: <String>['第一题步骤'],
            aiTags: <String>[],
            knowledgePoints: <String>[],
            mistakeReason: '',
            studyAdvice: '',
          ),
          savedExercises: _makeQuestion().savedExercises,
        ),
        CandidateAnalysisSnapshot(
          candidateId: 'candidate-1',
          order: 2,
          questionText: '第二题',
          analysisResult: const AnalysisResult(
            finalAnswer: '第二题答案',
            steps: <String>['第二题步骤'],
            aiTags: <String>[],
            knowledgePoints: <String>[],
            mistakeReason: '',
            studyAdvice: '',
          ),
          savedExercises: _makeQuestion().savedExercises,
        ),
      ],
    );
    container.read(currentQuestionProvider.notifier).state = question;
    container.read(currentPracticeContextProvider.notifier).state =
        const PracticeContext(
      source: PracticeContextSource.analysis,
      candidateId: 'candidate-1',
      candidateOrder: 2,
      returnRoute: '/analysis/result',
    );
    final router = _practiceRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('B'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.tap(find.text('下一题'));
    await tester.pump();
    await tester.tap(find.text('C'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.tap(find.text('完成练习'));
    await tester.pump();
    await tester.tap(find.text('保存这道题'));
    await tester.pump();

    final session = container.read(currentQuestionSplitSessionProvider);
    expect(session?.drafts.map((draft) => draft.selected).toList(),
        <bool>[false, true]);
  });

  testWidgets(
      'refreshes practice exercises when diagramData appears for same question',
      (tester) async {
    final repo = InMemoryQuestionRepository();
    final container = ProviderContainer(
      overrides: <Override>[
        questionRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    final now = DateTime.now();
    final withoutDiagram = GeneratedExercise(
      id: 'e-1',
      questionId: 'q-1',
      generationMode: ExerciseGenerationMode.practice,
      difficulty: '简单',
      question: '求三角形面积',
      options: const ['A. 6', 'B. 8', 'C. 10', 'D. 12'],
      answer: 'A',
      explanation: '面积公式',
      createdAt: now,
      order: 0,
    );
    final withDiagram = withoutDiagram.copyWith(
      diagramData: const <String, dynamic>{
        'elements': [
          {
            'type': 'polygon',
            'points': [
              [0.2, 0.8],
              [0.8, 0.8],
              [0.5, 0.2],
            ],
          },
        ],
      },
    );

    container.read(currentQuestionProvider.notifier).state =
        _makeQuestion(exercises: <GeneratedExercise>[withoutDiagram]);
    final router = _practiceRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(GeometryDiagramWidget), findsNothing);

    container.read(currentQuestionProvider.notifier).state =
        _makeQuestion(exercises: <GeneratedExercise>[withDiagram]);
    await tester.pump();

    expect(find.byType(GeometryDiagramWidget), findsOneWidget);
  });

  testWidgets('renders diagramData with dynamic map elements from memory',
      (tester) async {
    final diagramData = <String, dynamic>{
      'elements': <Object?>[
        <Object?, Object?>{
          'type': 'polygon',
          'points': <Object?>[
            <Object?>[0.2, 0.8],
            <Object?>[0.8, 0.8],
            <Object?>[0.5, 0.2],
          ],
        },
        <Object?, Object?>{
          'type': 'rightAngle',
          'x': 0.2,
          'y': 0.8,
        },
      ],
      'auxiliaryLines': <Object?>[],
    };

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: GeometryDiagramWidget(diagramData: diagramData),
      ),
    ));
    await tester.pump();

    expect(find.byType(CustomPaint), findsAtLeastNWidgets(1));
  });

  testWidgets(
      'assigns A/B/C/D labels to unlabelled numeric options and grades B. 12 / lowercase b accurately',
      (tester) async {
    final now = DateTime.now();
    final repo = InMemoryQuestionRepository();
    final question = _makeQuestion(
      exercises: <GeneratedExercise>[
        GeneratedExercise(
          id: 'num-1',
          questionId: 'q-1',
          generationMode: ExerciseGenerationMode.practice,
          difficulty: '简单',
          question: '6 + 6 = ?',
          options: const <String>['10', '12', '15', '20'],
          answer: 'B. 12',
          explanation: '6 加 6 等于 12',
          createdAt: now,
          order: 0,
        ),
        GeneratedExercise(
          id: 'num-2',
          questionId: 'q-1',
          generationMode: ExerciseGenerationMode.practice,
          difficulty: '中等',
          question: '3 * 5 = ?',
          options: const <String>['10', '12', '15', '20'],
          answer: 'c',
          explanation: '3 乘 5 等于 15',
          createdAt: now,
          order: 1,
        ),
      ],
    );
    await repo.saveDraft(question);

    await tester.pumpWidget(_buildApp(question, repo));
    await tester.pumpAndSettle();

    // Distinct A/B/C/D badges instead of duplicate '1' labels
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);
    expect(find.text('D'), findsOneWidget);
    expect(find.text('1'), findsNothing);

    await tester.tap(find.text('B'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('回答正确'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('回答正确'), findsOneWidget);

    await tester.tap(find.text('下一题'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('C'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('回答正确'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('回答正确'), findsOneWidget);
  });

  testWidgets('keeps free-input user answer visible after submission',
      (tester) async {
    final now = DateTime.now();
    final repo = InMemoryQuestionRepository();
    final question = _makeQuestion(
      exercises: <GeneratedExercise>[
        GeneratedExercise(
          id: 'free-1',
          questionId: 'q-1',
          generationMode: ExerciseGenerationMode.practice,
          difficulty: '简单',
          question: '解方程 x + 3 = 8',
          answer: 'x=5',
          explanation: '移项得 x = 8 - 3 = 5',
          createdAt: now,
          order: 0,
        ),
      ],
    );
    await repo.saveDraft(question);

    await tester.pumpWidget(_buildApp(question, repo));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'x=4');
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pumpAndSettle();

    expect(find.text('你的作答'), findsOneWidget);
    expect(find.text('x=4'), findsOneWidget);
    expect(find.text('回答错误'), findsOneWidget);
    expect(find.text('正确答案：x=5'), findsOneWidget);
  });

  testWidgets(
      'persists partial mid-round progress and supports completion list & ?review=1 explanation browsing',
      (tester) async {
    final now = DateTime.now();
    final repo = InMemoryQuestionRepository();
    final question = _makeQuestion(
      exercises: <GeneratedExercise>[
        GeneratedExercise(
          id: 'r-1',
          questionId: 'q-1',
          generationMode: ExerciseGenerationMode.practice,
          difficulty: '简单',
          question: '第一道练习题',
          options: const <String>['A. 1', 'B. 2'],
          answer: 'B',
          explanation: '第一题详细解析',
          createdAt: now,
          order: 0,
        ),
        GeneratedExercise(
          id: 'r-2',
          questionId: 'q-1',
          generationMode: ExerciseGenerationMode.practice,
          difficulty: '中等',
          question: '第二道练习题',
          options: const <String>['A. 3', 'B. 4'],
          answer: 'B',
          explanation: '第二题详细解析',
          createdAt: now,
          order: 1,
        ),
      ],
    );
    await repo.saveDraft(question);

    final container = ProviderContainer(
      overrides: <Override>[
        questionRepositoryProvider.overrideWithValue(repo),
      ],
    );
    addTearDown(container.dispose);

    container.read(currentQuestionProvider.notifier).state = question;
    container.read(questionDetailModeProvider.notifier).state =
        QuestionDetailMode.review;
    container.read(activeReviewSessionProvider.notifier).state =
        const ReviewSessionState(queueIds: <String>['q-1'], currentIndex: 0);

    final router = _practiceRouter();
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // Answer Question 1 of 2 -> persisted immediately before finishing round!
    await tester.tap(find.text('B'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pumpAndSettle();

    final midSaved = await repo.getById('q-1');
    expect(midSaved!.savedExercises.first.isCorrect, isTrue);
    expect(midSaved.savedExercises.last.isCorrect, isNull);

    // Finish Question 2 (intentionally wrong) -> completion summary lists rows
    await tester.tap(find.text('下一题'));
    await tester.pumpAndSettle();
    expect(find.text('上一题'), findsOneWidget);

    await tester.tap(find.text('A'));
    await tester.pump();
    await tester.tap(find.text('提交答案'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成练习'));
    await tester.pumpAndSettle();

    expect(find.text('第 1 题 · 答对'), findsOneWidget);
    expect(find.text('第 2 题 · 答错'), findsOneWidget);

    // Tap '第 2 题 · 答错' row to jump back and inspect explanation
    await tester.tap(find.text('第 2 题 · 答错'));
    await tester.pumpAndSettle();
    expect(find.text('第二题详细解析'), findsOneWidget);

    // Step back to Question 1 via '上一题'
    await tester.tap(find.text('上一题'));
    await tester.pumpAndSettle();
    expect(find.text('第一题详细解析'), findsOneWidget);

    // Jump back to completion and return to detail -> clears review mode leak
    await tester.tap(find.text('第 2 题'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成练习'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('返回错题详情'));
    await tester.pumpAndSettle();

    expect(
        container.read(questionDetailModeProvider), QuestionDetailMode.browse);
    expect(container.read(activeReviewSessionProvider), isNull);

    // Re-open completed round with ?review=1 -> starts on Question 1 directly!
    router.go('/exercise/practice?review=1');
    await tester.pumpAndSettle();

    expect(find.text('举一反三 1/2'), findsOneWidget);
    expect(find.text('第一道练习题'), findsOneWidget);
    expect(find.text('第一题详细解析'), findsOneWidget);
  });
}
