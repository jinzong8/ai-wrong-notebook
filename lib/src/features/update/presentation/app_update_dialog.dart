import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/common/widgets/editorial_surface.dart';
import 'package:smart_wrong_notebook/src/features/update/domain/app_update_models.dart';

/// Passive startup listener mounted inside the main shell.
///
/// Only prompts when a complete, SHA-256-verified APK is ALREADY sitting on
/// local disk from a prior silent download; never shows network errors or
/// incomplete download progress automatically.
class AppUpdateStartupListener extends ConsumerStatefulWidget {
  const AppUpdateStartupListener({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  ConsumerState<AppUpdateStartupListener> createState() =>
      _AppUpdateStartupListenerState();
}

class _AppUpdateStartupListenerState
    extends ConsumerState<AppUpdateStartupListener> {
  bool _dialogShowing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(appUpdateControllerProvider.notifier).initializeOnStartup();
    });
  }

  void _maybeShowStartupDialog(AppUpdateState next) {
    if (_dialogShowing || !mounted || !next.shouldAutoPromptOnStartup) return;
    final update = next.readyUpdate;
    if (update == null) return;

    _dialogShowing = true;
    ref.read(appUpdateControllerProvider.notifier).markStartupPromptHandled();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _dialogShowing = false;
        return;
      }
      try {
        await showAppUpdateReadyDialog(context, ref, update);
      } finally {
        _dialogShowing = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<AppUpdateState>(
      appUpdateControllerProvider,
      (_, next) => _maybeShowStartupDialog(next),
    );
    return widget.child;
  }
}

/// Shows the zero-wait installation modal for an already-downloaded and
/// verified [StagedAppUpdate].
Future<void> showAppUpdateReadyDialog(
  BuildContext context,
  WidgetRef ref,
  StagedAppUpdate update,
) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => _AppUpdateReadyDialog(update: update),
  );
}

class _AppUpdateReadyDialog extends ConsumerStatefulWidget {
  const _AppUpdateReadyDialog({required this.update});

  final StagedAppUpdate update;

  @override
  ConsumerState<_AppUpdateReadyDialog> createState() =>
      _AppUpdateReadyDialogState();
}

class _AppUpdateReadyDialogState extends ConsumerState<_AppUpdateReadyDialog> {
  bool _installing = false;

  Future<void> _handleInstall() async {
    if (_installing) return;
    setState(() => _installing = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final result = await ref
          .read(appUpdateControllerProvider.notifier)
          .installReadyUpdate(widget.update);
      if (!mounted) return;
      Navigator.of(context).pop();
      if (result == 'permission_requested') {
        messenger?.showSnackBar(
          const SnackBar(
            content: Text('请先开启「允许安装未知应用」，返回后将自动继续安装'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      messenger?.showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = EditorialPalette.of(context);
    final sizeLabel = formatUpdateByteSize(widget.update.fileSize);
    final notes = widget.update.releaseNotes.trim();

    return Dialog(
      backgroundColor: p.card,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.hairline),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: p.cobaltTint,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      CupertinoIcons.arrow_down_circle_fill,
                      color: p.cobalt,
                      size: 21,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          '新版本 v${widget.update.version} 已准备就绪',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: p.inkPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          sizeLabel.isEmpty
                              ? '安装包已静默下载并校验完成'
                              : '$sizeLabel · 已静默下载并校验完成',
                          style: TextStyle(
                            fontSize: 12,
                            color: p.emerald,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (notes.isNotEmpty) ...<Widget>[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.subtle,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: p.hairline),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      notes,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.55,
                        color: p.inkPrimary,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Icon(
                    CupertinoIcons.checkmark_shield,
                    size: 14,
                    color: p.inkMuted,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '直接覆盖安装，本地错题、图片与 AI 配置完整保留',
                      style: TextStyle(
                        fontSize: 12,
                        color: p.inkSecondary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: <Widget>[
                  TextButton(
                    key: const Key('update-ignore-version'),
                    onPressed: _installing
                        ? null
                        : () async {
                            await ref
                                .read(appUpdateControllerProvider.notifier)
                                .ignoreStartupPromptFor(widget.update.version);
                            if (context.mounted) {
                              Navigator.of(context).pop();
                            }
                          },
                    style: TextButton.styleFrom(
                      foregroundColor: p.inkMuted,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: const Text('忽略此版', style: TextStyle(fontSize: 13)),
                  ),
                  const Spacer(),
                  OutlinedButton(
                    key: const Key('update-later'),
                    onPressed:
                        _installing ? null : () => Navigator.of(context).pop(),
                    child: const Text('稍后'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    key: const Key('update-install-now'),
                    onPressed: _installing ? null : _handleInstall,
                    icon: _installing
                        ? const SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(
                            CupertinoIcons.checkmark_circle_fill,
                            size: 16,
                          ),
                    label: const Text('立即安装'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
