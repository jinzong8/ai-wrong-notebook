import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

/// Intercepts Android system back gestures / hardware back button on
/// top-level [GoRouter] routes that are opened via `context.go(...)`.
///
/// Without this scope, `Navigator.canPop()` is false on flat top-level routes,
/// causing Android to close the entire app on a swipe-back gesture.
class AppBackScope extends StatelessWidget {
  const AppBackScope({
    super.key,
    required this.onBack,
    required this.child,
    this.enabled = true,
    this.preferCustomBack = false,
  });

  final VoidCallback onBack;
  final Widget child;

  /// When false (e.g. while saving/submitting), the back gesture is absorbed
  /// without exiting the app or leaving mid-operation.
  final bool enabled;

  /// When true, always runs [onBack] before checking `Navigator.canPop()`.
  /// Useful for multi-stage screens such as post-capture crop -> retake.
  final bool preferCustomBack;

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop || !enabled) return;
        if (preferCustomBack) {
          onBack();
          return;
        }
        final navigator = Navigator.of(context);
        if (navigator.canPop()) {
          navigator.pop();
          return;
        }
        onBack();
      },
      child: child,
    );
  }
}

/// Intercepts system back gestures on the bottom-navigation shell:
/// - On non-home tabs (错题本 / 复习 / 设置), switches back to the Home tab.
/// - On the Home tab, requires a second back gesture within [doubleBackWindow]
///   before exiting the app, preventing accidental closure.
class TabShellBackScope extends StatefulWidget {
  const TabShellBackScope({
    super.key,
    required this.navigationShell,
    required this.child,
    this.onExitApp,
    this.doubleBackWindow = const Duration(seconds: 2),
  });

  final StatefulNavigationShell navigationShell;
  final Widget child;
  final VoidCallback? onExitApp;
  final Duration doubleBackWindow;

  @override
  State<TabShellBackScope> createState() => _TabShellBackScopeState();
}

class _TabShellBackScopeState extends State<TabShellBackScope> {
  DateTime? _lastBackPressedAt;

  void _handleBack() {
    if (widget.navigationShell.currentIndex != 0) {
      _lastBackPressedAt = null;
      widget.navigationShell.goBranch(0);
      return;
    }

    final now = DateTime.now();
    if (_lastBackPressedAt != null &&
        now.difference(_lastBackPressedAt!) <= widget.doubleBackWindow) {
      _lastBackPressedAt = null;
      final exitApp = widget.onExitApp;
      if (exitApp != null) {
        exitApp();
      } else {
        SystemNavigator.pop();
      }
      return;
    }

    _lastBackPressedAt = now;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      SnackBar(
        content: const Text('再返回一次退出应用'),
        duration: widget.doubleBackWindow,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? _) {
        if (didPop) return;
        _handleBack();
      },
      child: widget.child,
    );
  }
}
