import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/app/router.dart';
import 'package:smart_wrong_notebook/src/data/repositories/question_repository.dart';
import 'package:smart_wrong_notebook/src/data/repositories/settings_repository.dart';
import 'package:smart_wrong_notebook/src/domain/models/ai_provider_config.dart';
import 'package:smart_wrong_notebook/src/domain/models/analysis_result.dart';
import 'package:smart_wrong_notebook/src/domain/models/content_status.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_record.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_split_result.dart';
import 'package:smart_wrong_notebook/src/domain/models/question_split_session.dart';
import 'package:smart_wrong_notebook/src/domain/models/subject.dart';
import 'package:smart_wrong_notebook/src/domain/repositories/review_log_repository.dart';
import 'package:smart_wrong_notebook/src/features/home/presentation/home_screen.dart';

class _FakeSettingsRepository implements SettingsRepository {
  @override
  Future<AiProviderConfig?> getAiProviderConfig() async => null;

  @override
  Future<void> saveAiProviderConfig(AiProviderConfig config) async {}

  @override
  Future<String?> getString(String key) async =>
      key == 'onboarding_done' ? 'true' : null;

  @override
  Future<void> setString(String key, String value) async {}
}

QuestionRecord _sampleQuestion({String id = 'q-back-1'}) {
  return QuestionRecord.draft(
    id: id,
    subject: Subject.math,
    imagePath: '',
    recognizedText: '求 2 + 3 的值',
  ).copyWith(
    contentStatus: ContentStatus.ready,
    analysisResult: const AnalysisResult(
      finalAnswer: '5',
      steps: <String>['2 + 3 = 5'],
      mistakeReason: '计算粗心',
      knowledgePoints: <String>['加法'],
      aiTags: <String>['加法'],
      studyAdvice: '细心验算',
    ),
  );
}

void main() {
  testWidgets(
      'system back pops nested settings route, switches non-home tabs to home, and requires double-back on home to exit',
      (tester) async {
    final settingsRepo = _FakeSettingsRepository();
    final questionRepo = InMemoryQuestionRepository();
    var exitCount = 0;
    final router = buildRouter(
      settingsRepo,
      onExitApp: () => exitCount++,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          settingsRepositoryProvider.overrideWithValue(settingsRepo),
          questionRepositoryProvider.overrideWithValue(questionRepo),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // 1. Nested route /settings/provider -> back pops to /settings
    router.go('/settings/provider');
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path,
        '/settings/provider');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/settings');
    expect(exitCount, 0);

    // 2. Non-home tab /settings -> back switches to Home (/)
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    expect(exitCount, 0);

    // 3. Non-home tab /notebook -> back switches to Home (/)
    router.go('/notebook');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    expect(exitCount, 0);

    // 4. First back on Home shows toast and does NOT exit
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('再返回一次退出应用'), findsOneWidget);
    expect(exitCount, 0);

    // 5. Second back within 2s exits
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(exitCount, 1);
  });

  testWidgets(
      'system back on QuestionDetailScreen returns to actual originating screen instead of exiting app',
      (tester) async {
    final settingsRepo = _FakeSettingsRepository();
    final questionRepo = InMemoryQuestionRepository();
    final question = _sampleQuestion();
    await questionRepo.saveDraft(question);

    var exitCount = 0;
    final router = buildRouter(
      settingsRepo,
      onExitApp: () => exitCount++,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          settingsRepositoryProvider.overrideWithValue(settingsRepo),
          questionRepositoryProvider.overrideWithValue(questionRepo),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // Open question detail from Home recent list -> back returns to Home (/)
    await tester.scrollUntilVisible(
      find.text('求 2 + 3 的值'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('求 2 + 3 的值'));
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path,
        '/notebook/question/${question.id}');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');
    expect(exitCount, 0);

    // Open question detail from Notebook -> back returns to Notebook (/notebook)
    router.go('/notebook');
    await tester.pumpAndSettle();
    await tester.tap(find.text('求 2 + 3 的值'));
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path,
        '/notebook/question/${question.id}');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/notebook');
    expect(exitCount, 0);
  });

  testWidgets(
      'system back on top-level flow screens navigates cleanly without closing app',
      (tester) async {
    final settingsRepo = _FakeSettingsRepository();
    final questionRepo = InMemoryQuestionRepository();
    final question = _sampleQuestion();
    await questionRepo.saveDraft(question);

    var exitCount = 0;
    final router = buildRouter(
      settingsRepo,
      onExitApp: () => exitCount++,
    );
    final container = ProviderContainer(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(settingsRepo),
        questionRepositoryProvider.overrideWithValue(questionRepo),
        reviewLogRepositoryProvider
            .overrideWithValue(InMemoryReviewLogRepository()),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    // /review/history -> /review
    router.go('/review/history');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/review');

    // /analysis/result -> /
    container.read(currentQuestionProvider.notifier).state = question;
    router.go('/analysis/result');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(router.routerDelegate.currentConfiguration.uri.path, '/');

    // /capture/split-confirmation -> /analysis/result
    container.read(currentQuestionSplitSessionProvider.notifier).state =
        QuestionSplitSession(
      source: question,
      strategy: QuestionSplitStrategy.fallback,
      drafts: const <QuestionSplitDraft>[
        QuestionSplitDraft(
          id: 'c1',
          originalOrder: 1,
          text: '第 1 题',
          selected: true,
        ),
      ],
    );
    router.go('/capture/split-confirmation');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/analysis/result',
    );

    // /analysis/text-correction?from=detail -> /notebook/question/:id
    router.go('/analysis/text-correction?from=detail');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/notebook/question/${question.id}',
    );

    // /exercise/practice -> returnRoute
    container.read(currentPracticeContextProvider.notifier).state =
        PracticeContext(
      source: PracticeContextSource.notebook,
      returnRoute: '/notebook/question/${question.id}',
    );
    router.go('/exercise/practice');
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      '/notebook/question/${question.id}',
    );

    expect(exitCount, 0);
  });

  testWidgets(
      'HomeScreen pins 拍照录题 button in bottom thumb zone even when scrolled',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final questionRepo = InMemoryQuestionRepository();
    for (var i = 0; i < 6; i++) {
      await questionRepo.saveDraft(_sampleQuestion(id: 'q-scroll-$i'));
    }

    await tester.pumpWidget(
      ProviderScope(
        overrides: <Override>[
          settingsRepositoryProvider
              .overrideWithValue(_FakeSettingsRepository()),
          questionRepositoryProvider.overrideWithValue(questionRepo),
        ],
        child: const MaterialApp(home: Scaffold(body: HomeScreen())),
      ),
    );
    await tester.pumpAndSettle();

    final ctaFinder = find.byKey(const Key('home-capture-cta'));
    expect(ctaFinder, findsOneWidget);
    final beforeRect = tester.getRect(ctaFinder);
    // Must sit in the bottom thumb zone (below 80% of screen height).
    expect(beforeRect.top, greaterThan(844 * 0.8));

    // Scroll list down and verify CTA remains fixed at the exact same position.
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final afterRect = tester.getRect(ctaFinder);
    expect(afterRect, equals(beforeRect));
  });
}
