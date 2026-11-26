import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/data/repositories/question_repository.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/mastery_level.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/review_log.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/domain/repositories/review_log_repository.dart';
import 'package:smart_wrong_notebook/src/features/review/presentation/review_history_screen.dart';

QuestionRecord _question(String id, String text) {
  final now = DateTime(2026);
  return QuestionRecord(
    id: id,
    imagePath: '',
    subject: Subject.math,
    extractedQuestionText: text,
    normalizedQuestionText: text,
    contentFormat: QuestionContentFormat.plain,
    tags: const <String>[],
    createdAt: now,
    updatedAt: now,
    lastReviewedAt: null,
    reviewCount: 0,
    isFavorite: false,
    contentStatus: ContentStatus.ready,
    masteryLevel: MasteryLevel.newQuestion,
    analysisResult: null,
  );
}

ReviewLog _log({
  required String id,
  required String questionId,
  required DateTime reviewedAt,
  required String result,
  required MasteryLevel masteryAfter,
}) {
  return ReviewLog(
    id: id,
    questionRecordId: questionId,
    reviewedAt: reviewedAt,
    result: result,
    masteryAfter: masteryAfter,
  );
}

Future<void> _pumpHistory(
  WidgetTester tester, {
  required InMemoryQuestionRepository questionRepository,
  required InMemoryReviewLogRepository reviewLogRepository,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        questionRepositoryProvider.overrideWithValue(questionRepository),
        reviewLogRepositoryProvider.overrideWithValue(reviewLogRepository),
      ],
      child: const MaterialApp(home: ReviewHistoryScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows empty state when there are no review logs',
      (tester) async {
    await _pumpHistory(
      tester,
      questionRepository: InMemoryQuestionRepository(),
      reviewLogRepository: InMemoryReviewLogRepository(),
    );

    expect(find.text('复习记录'), findsOneWidget);
    expect(find.text('暂无复习记录'), findsOneWidget);
    expect(find.text('完成错题复习打卡后将在此显示历史记录'), findsOneWidget);
  });

  testWidgets('shows review logs with question text in newest order',
      (tester) async {
    final questionRepository = InMemoryQuestionRepository();
    final reviewLogRepository = InMemoryReviewLogRepository();
    await questionRepository.saveDraft(_question('q-1', '较早题目'));
    await questionRepository.saveDraft(_question('q-2', '较新题目'));
    await reviewLogRepository.insert(_log(
      id: 'log-old',
      questionId: 'q-1',
      reviewedAt: DateTime(2026, 1, 1, 9),
      result: 'reviewing',
      masteryAfter: MasteryLevel.reviewing,
    ));
    await reviewLogRepository.insert(_log(
      id: 'log-new',
      questionId: 'q-2',
      reviewedAt: DateTime(2026, 1, 2, 9),
      result: 'mastered',
      masteryAfter: MasteryLevel.mastered,
    ));

    await _pumpHistory(
      tester,
      questionRepository: questionRepository,
      reviewLogRepository: reviewLogRepository,
    );

    expect(find.text('较新题目'), findsOneWidget);
    expect(find.text('较早题目'), findsOneWidget);
    expect(find.textContaining('已掌握'), findsWidgets);
    expect(find.textContaining('复习中'), findsWidgets);

    final newerTop = tester.getTopLeft(find.text('较新题目')).dy;
    final olderTop = tester.getTopLeft(find.text('较早题目')).dy;
    expect(newerTop, lessThan(olderTop));
  });

  testWidgets('shows deleted fallback for logs without matching question',
      (tester) async {
    final reviewLogRepository = InMemoryReviewLogRepository();
    await reviewLogRepository.insert(_log(
      id: 'log-deleted',
      questionId: 'missing-question',
      reviewedAt: DateTime(2026),
      result: 'mastered',
      masteryAfter: MasteryLevel.mastered,
    ));

    await _pumpHistory(
      tester,
      questionRepository: InMemoryQuestionRepository(),
      reviewLogRepository: reviewLogRepository,
    );

    expect(find.text('已删除'), findsOneWidget);
    expect(find.textContaining('已掌握'), findsWidgets);
  });

  testWidgets(
      'refreshes immediately when new logs are inserted and invalidateQuestionList is triggered',
      (tester) async {
    final questionRepository = InMemoryQuestionRepository();
    final reviewLogRepository = InMemoryReviewLogRepository();
    late WidgetRef capturedRef;

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          questionRepositoryProvider.overrideWithValue(questionRepository),
          reviewLogRepositoryProvider.overrideWithValue(reviewLogRepository),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              capturedRef = ref;
              return const ReviewHistoryScreen();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('暂无复习记录'), findsOneWidget);

    await questionRepository.saveDraft(_question('q-live', '实时刷新的错题'));
    await reviewLogRepository.insert(_log(
      id: 'log-live',
      questionId: 'q-live',
      reviewedAt: DateTime(2026, 2, 1, 10),
      result: 'mastered',
      masteryAfter: MasteryLevel.mastered,
    ));
    invalidateQuestionList(capturedRef);
    await tester.pumpAndSettle();

    expect(find.text('暂无复习记录'), findsNothing);
    expect(find.text('实时刷新的错题'), findsOneWidget);
  });

  testWidgets(
      'tapping history entry clears activeReviewSessionProvider and opens detail in browse mode',
      (tester) async {
    final questionRepository = InMemoryQuestionRepository();
    final reviewLogRepository = InMemoryReviewLogRepository();
    final q = _question('q-tap', '点击查看的错题');
    await questionRepository.saveDraft(q);
    await reviewLogRepository.insert(_log(
      id: 'log-tap',
      questionId: 'q-tap',
      reviewedAt: DateTime(2026, 2, 2, 12),
      result: 'reviewing',
      masteryAfter: MasteryLevel.reviewing,
    ));

    final container = ProviderContainer(
      overrides: <Override>[
        questionRepositoryProvider.overrideWithValue(questionRepository),
        reviewLogRepositoryProvider.overrideWithValue(reviewLogRepository),
      ],
    );
    addTearDown(container.dispose);

    container.read(activeReviewSessionProvider.notifier).state =
        const ReviewSessionState(queueIds: <String>['q-tap'], currentIndex: 0);

    final router = GoRouter(
      initialLocation: '/review/history',
      routes: <RouteBase>[
        GoRoute(
          path: '/review/history',
          builder: (_, __) => const ReviewHistoryScreen(),
        ),
        GoRoute(
          path: '/notebook/question/:id',
          builder: (_, state) =>
              Scaffold(body: Text('DETAIL ${state.pathParameters['id']}')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('点击查看的错题'));
    await tester.pumpAndSettle();

    expect(find.text('DETAIL q-tap'), findsOneWidget);
    expect(container.read(activeReviewSessionProvider), isNull);
    expect(
        container.read(questionDetailReturnRouteProvider), '/review/history');
    expect(
        container.read(questionDetailModeProvider), QuestionDetailMode.browse);
  });
}
