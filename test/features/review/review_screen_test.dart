import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/data/repositories/question_repository.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/mastery_level.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/domain/repositories/review_log_repository.dart';
import 'package:smart_wrong_notebook/src/features/review/presentation/review_screen.dart';

QuestionRecord _reviewQuestion(
  String id, {
  String text = 'sample',
  String? rootQuestionId,
  int? splitOrder,
  MasteryLevel masteryLevel = MasteryLevel.newQuestion,
  int reviewCount = 0,
  DateTime? createdAt,
  DateTime? lastReviewedAt,
}) {
  final now = createdAt ?? DateTime(2026);
  return QuestionRecord(
    id: id,
    imagePath: '/tmp/$id.jpg',
    subject: Subject.math,
    extractedQuestionText: text,
    normalizedQuestionText: text,
    contentFormat: QuestionContentFormat.plain,
    tags: const <String>[],
    createdAt: now,
    updatedAt: now,
    lastReviewedAt: lastReviewedAt,
    reviewCount: reviewCount,
    isFavorite: false,
    contentStatus: ContentStatus.ready,
    masteryLevel: masteryLevel,
    analysisResult: null,
    rootQuestionId: rootQuestionId,
    splitOrder: splitOrder,
  );
}

Future<void> _pumpReviewScreen(
  WidgetTester tester,
  InMemoryQuestionRepository repository, {
  InMemoryReviewLogRepository? reviewLogRepository,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        questionRepositoryProvider.overrideWithValue(repository),
        if (reviewLogRepository != null)
          reviewLogRepositoryProvider.overrideWithValue(reviewLogRepository),
      ],
      child: const MaterialApp(home: ReviewScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('ReviewScreen', () {
    testWidgets('shows sensible empty states on both pending and mastered tabs',
        (tester) async {
      await _pumpReviewScreen(tester, InMemoryQuestionRepository());

      expect(find.text('待复习 0'), findsOneWidget);
      expect(find.text('已掌握 0'), findsOneWidget);
      expect(find.text('太棒了！'), findsOneWidget);
      expect(find.text('暂无待复习错题'), findsOneWidget);
      expect(
          find.byKey(const Key('start-continuous-review-button')), findsNothing);

      await tester.tap(find.text('已掌握 0'));
      await tester.pumpAndSettle();

      expect(find.text('暂无已掌握错题'), findsOneWidget);
      expect(find.text('在复习中标记「已掌握」后会归档到这里'), findsOneWidget);
      expect(find.text('太棒了！'), findsNothing);
    });

    testWidgets('shows summary card with correct counts', (tester) async {
      await _pumpReviewScreen(tester, InMemoryQuestionRepository());

      expect(find.text('整体进度'), findsOneWidget);
      expect(find.text('共 0 题'), findsOneWidget);
    });

    testWidgets('shows history link immediately without scrolling',
        (tester) async {
      await _pumpReviewScreen(tester, InMemoryQuestionRepository());

      expect(find.text('复习记录'), findsOneWidget);
      expect(find.byIcon(CupertinoIcons.chevron_right), findsWidgets);
    });

    testWidgets('starts continuous review session when tapping CTA or card',
        (tester) async {
      final repository = InMemoryQuestionRepository();
      await repository.saveDrafts(<QuestionRecord>[
        _reviewQuestion(
          'q-reviewed',
          text: '已复习过但未掌握',
          masteryLevel: MasteryLevel.reviewing,
          createdAt: DateTime(2026, 1, 3),
          lastReviewedAt: DateTime(2026, 1, 4, 10),
        ),
        _reviewQuestion(
          'q-unreviewed-1',
          text: '新错题一',
          createdAt: DateTime(2026, 1, 2),
        ),
        _reviewQuestion(
          'q-unreviewed-2',
          text: '新错题二',
          createdAt: DateTime(2026, 1, 5),
        ),
        _reviewQuestion(
          'q-mastered',
          text: '已掌握题',
          masteryLevel: MasteryLevel.mastered,
        ),
      ]);

      final container = ProviderContainer(
        overrides: <Override>[
          questionRepositoryProvider.overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);

      final router = GoRouter(
        initialLocation: '/review',
        routes: <RouteBase>[
          GoRoute(
            path: '/review',
            builder: (_, __) => const ReviewScreen(),
          ),
          GoRoute(
            path: '/review/history',
            builder: (_, __) => const Scaffold(body: Text('HISTORY')),
          ),
          GoRoute(
            path: '/notebook/question/:id',
            builder: (_, state) => Scaffold(
              body: Text('DETAIL ${state.pathParameters['id']}'),
            ),
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

      expect(find.text('开始连续复习 (3 题)'), findsOneWidget);

      // Tap CTA -> starts queue ordered by sortDueReviewQuestions
      await tester.tap(find.byKey(const Key('start-continuous-review-button')));
      await tester.pumpAndSettle();

      expect(find.text('DETAIL q-unreviewed-2'), findsOneWidget);
      final ctaSession = container.read(activeReviewSessionProvider);
      expect(ctaSession, isNotNull);
      expect(
        ctaSession!.queueIds,
        <String>['q-unreviewed-2', 'q-unreviewed-1', 'q-reviewed'],
      );
      expect(ctaSession.currentIndex, 0);
      expect(container.read(questionDetailReturnRouteProvider), '/review');
      expect(
          container.read(questionDetailModeProvider), QuestionDetailMode.review);

      // Return to /review and tap a specific pending card -> starts from tapped card
      router.go('/review');
      await tester.pumpAndSettle();
      await tester.tap(find.text('新错题一'));
      await tester.pumpAndSettle();

      expect(find.text('DETAIL q-unreviewed-1'), findsOneWidget);
      final cardSession = container.read(activeReviewSessionProvider);
      expect(
        cardSession!.queueIds,
        <String>['q-unreviewed-1', 'q-unreviewed-2', 'q-reviewed'],
      );
      expect(cardSession.currentIndex, 0);

      // Return to /review, switch to 已掌握 tab, tap mastered card -> browse mode & session cleared
      router.go('/review');
      await tester.pumpAndSettle();
      await tester.tap(find.text('已掌握 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已掌握题'));
      await tester.pumpAndSettle();

      expect(find.text('DETAIL q-mastered'), findsOneWidget);
      expect(container.read(activeReviewSessionProvider), isNull);
      expect(
          container.read(questionDetailModeProvider), QuestionDetailMode.browse);
    });

    testWidgets('does not show batch label for standalone due question',
        (tester) async {
      final repository = InMemoryQuestionRepository();
      await repository.saveDraft(_reviewQuestion('q-1', text: '单题'));

      await _pumpReviewScreen(tester, repository);

      expect(find.text('单题'), findsOneWidget);
      expect(find.textContaining('来自同一拍照批次'), findsNothing);
    });

    testWidgets('shows batch labels for due sibling questions', (tester) async {
      final repository = InMemoryQuestionRepository();
      await repository.saveDrafts(<QuestionRecord>[
        _reviewQuestion('q-1',
            text: '第一题', rootQuestionId: 'root-1', splitOrder: 1),
        _reviewQuestion('q-2',
            text: '第二题', rootQuestionId: 'root-1', splitOrder: 2),
      ]);

      await _pumpReviewScreen(tester, repository);

      expect(find.text('第一题'), findsOneWidget);
      expect(find.text('第二题'), findsOneWidget);
      expect(find.text('来自同一拍照批次 · 第 1 题'), findsOneWidget);
      expect(find.text('来自同一拍照批次 · 第 2 题'), findsOneWidget);
    });

    testWidgets('shows mastery status without quick action buttons',
        (tester) async {
      final repository = InMemoryQuestionRepository();
      await repository.saveDrafts(<QuestionRecord>[
        _reviewQuestion('q-new', text: '新增题'),
        _reviewQuestion('q-reviewing',
            text: '复习题', masteryLevel: MasteryLevel.reviewing),
      ]);

      await _pumpReviewScreen(tester, repository);

      expect(find.text('新增题'), findsOneWidget);
      expect(find.text('复习题'), findsOneWidget);
      expect(find.text('待复习'), findsWidgets);
      expect(find.text('仍需复习'), findsNothing);
      expect(find.text('继续巩固'), findsNothing);
      expect(find.widgetWithText(FilledButton, '已掌握'), findsNothing);
    });
  });
}
