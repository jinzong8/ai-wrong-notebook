import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/core/constants/app_strings.dart';
import 'package:smart_wrong_notebook/src/features/home/presentation/home_screen.dart';
import 'package:smart_wrong_notebook/src/features/notebook/presentation/notebook_screen.dart';
import 'package:smart_wrong_notebook/src/features/notebook/presentation/question_detail_screen.dart';
import 'package:smart_wrong_notebook/src/features/onboarding/presentation/onboarding_screen.dart';
import 'package:smart_wrong_notebook/src/features/review/presentation/review_history_screen.dart';
import 'package:smart_wrong_notebook/src/features/review/presentation/review_screen.dart';
import 'package:smart_wrong_notebook/src/features/settings/presentation/settings_screen.dart';
import 'package:smart_wrong_notebook/src/features/settings/presentation/provider_config_screen.dart';
import 'package:smart_wrong_notebook/src/features/settings/presentation/subject_management_screen.dart';
import 'package:smart_wrong_notebook/src/features/settings/presentation/prompt_settings_screen.dart';
import 'package:smart_wrong_notebook/src/features/settings/presentation/data_management_screen.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/camera_capture_crop_screen.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/image_crop_screen.dart';
import 'package:smart_wrong_notebook/src/features/capture/presentation/question_correction_screen.dart';
import 'package:smart_wrong_notebook/src/features/ocr/presentation/question_save_confirmation_screen.dart';
import 'package:smart_wrong_notebook/src/features/ocr/presentation/question_split_confirmation_screen.dart';
import 'package:smart_wrong_notebook/src/features/analysis/presentation/analysis_loading_screen.dart';
import 'package:smart_wrong_notebook/src/features/analysis/presentation/analysis_result_screen.dart';
import 'package:smart_wrong_notebook/src/features/analysis/presentation/question_text_correction_screen.dart';
import 'package:smart_wrong_notebook/src/features/analysis/presentation/exercise_practice_screen.dart';
import 'package:smart_wrong_notebook/src/common/widgets/app_back_scope.dart';
import 'package:smart_wrong_notebook/src/data/repositories/settings_repository.dart';

GoRouter buildRouter(
  SettingsRepository settingsRepo, {
  VoidCallback? onExitApp,
}) {
  return GoRouter(
    initialLocation: '/',
    routes: <RouteBase>[
      GoRoute(
          path: '/onboarding',
          pageBuilder: (_, __) => _buildPage(const OnboardingScreen())),
      StatefulShellRoute.indexedStack(
        builder: (BuildContext context, GoRouterState state,
            StatefulNavigationShell navigationShell) {
          return ScaffoldWithNavBar(
            navigationShell: navigationShell,
            onExitApp: onExitApp,
          );
        },
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(path: '/', builder: (_, __) => const HomeScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                  path: '/notebook',
                  builder: (_, __) => const NotebookScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                  path: '/review', builder: (_, __) => const ReviewScreen()),
            ],
          ),
          StatefulShellBranch(
            routes: <RouteBase>[
              GoRoute(
                path: '/settings',
                builder: (_, __) => const SettingsScreen(),
                routes: <RouteBase>[
                  GoRoute(
                      path: 'provider',
                      builder: (_, __) => const ProviderConfigScreen()),
                  GoRoute(
                      path: 'subjects',
                      builder: (_, __) => const SubjectManagementScreen()),
                  GoRoute(
                      path: 'prompts',
                      builder: (_, __) => const PromptSettingsScreen()),
                  GoRoute(
                      path: 'data',
                      builder: (_, __) => const DataManagementScreen()),
                ],
              ),
            ],
          ),
        ],
      ),
      GoRoute(
          path: '/capture/camera',
          pageBuilder: (_, __) => _buildPage(const CameraCaptureCropScreen())),
      GoRoute(
          path: '/capture/crop',
          pageBuilder: (_, __) => _buildPage(const ImageCropScreen())),
      GoRoute(
          path: '/capture/correction',
          pageBuilder: (_, __) => _buildPage(const QuestionCorrectionScreen())),
      GoRoute(
          path: '/capture/save-confirmation',
          pageBuilder: (_, __) =>
              _buildPage(const QuestionSaveConfirmationScreen())),
      GoRoute(
          path: '/capture/split-confirmation',
          pageBuilder: (_, __) =>
              _buildPage(const QuestionSplitConfirmationScreen())),
      GoRoute(
        path: '/analysis/loading',
        pageBuilder: (_, state) => _buildPage(
          AnalysisLoadingScreen(
            isReanalysis: state.uri.queryParameters['reanalysis'] == '1',
          ),
        ),
      ),
      GoRoute(
          path: '/analysis/result',
          pageBuilder: (_, __) => _buildPage(const AnalysisResultScreen())),
      GoRoute(
        path: '/analysis/text-correction',
        pageBuilder: (_, state) => _buildPage(
          QuestionTextCorrectionScreen(
            returnToDetail: state.uri.queryParameters['from'] == 'detail',
          ),
        ),
      ),
      GoRoute(
          path: '/exercise/practice',
          pageBuilder: (_, __) => _buildPage(const ExercisePracticeScreen())),
      GoRoute(
          path: '/notebook/question/:id',
          pageBuilder: (_, __) => _buildPage(const QuestionDetailScreen())),
      GoRoute(
          path: '/review/history',
          pageBuilder: (_, __) => _buildPage(const ReviewHistoryScreen())),
    ],
  );
}

CustomTransitionPage _buildPage(Widget child) {
  return CustomTransitionPage(
    child: child,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      );
    },
  );
}

class ScaffoldWithNavBar extends StatelessWidget {
  const ScaffoldWithNavBar({
    required this.navigationShell,
    this.onExitApp,
    super.key,
  });

  final StatefulNavigationShell navigationShell;
  final VoidCallback? onExitApp;

  @override
  Widget build(BuildContext context) {
    return TabShellBackScope(
      navigationShell: navigationShell,
      onExitApp: onExitApp,
      child: Scaffold(
        body: navigationShell,
        bottomNavigationBar: NavigationBar(
          selectedIndex: navigationShell.currentIndex,
          onDestinationSelected: (int index) => navigationShell.goBranch(index),
          destinations: const <NavigationDestination>[
            NavigationDestination(
                icon: Icon(CupertinoIcons.house), label: AppStrings.homeTab),
            NavigationDestination(
                icon: Icon(CupertinoIcons.book), label: AppStrings.notebookTab),
            NavigationDestination(
                icon: Icon(CupertinoIcons.arrow_2_circlepath),
                label: AppStrings.reviewTab),
            NavigationDestination(
                icon: Icon(CupertinoIcons.gear), label: AppStrings.settingsTab),
          ],
        ),
      ),
    );
  }
}
