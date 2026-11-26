import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:smart_wrong_notebook/src/app/providers.dart';
import 'package:smart_wrong_notebook/src/common/widgets/app_back_scope.dart';

class PromptSettingsScreen extends ConsumerStatefulWidget {
  const PromptSettingsScreen({super.key});

  @override
  ConsumerState<PromptSettingsScreen> createState() =>
      _PromptSettingsScreenState();
}

class _PromptSettingsScreenState extends ConsumerState<PromptSettingsScreen> {
  late TextEditingController _systemPromptController;
  bool _loading = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _systemPromptController = TextEditingController();
    Future<void>.microtask(_load);
  }

  @override
  void dispose() {
    _systemPromptController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loaded) return;
    final prompt =
        await ref.read(settingsRepositoryProvider).getString('system_prompt');
    if (mounted) {
      _systemPromptController.text = prompt ?? '';
      setState(() => _loaded = true);
    }
  }

  Future<void> _save() async {
    setState(() => _loading = true);
    await ref
        .read(settingsRepositoryProvider)
        .setString('system_prompt', _systemPromptController.text.trim());
    if (mounted) {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('提示词已保存')));
    }
  }

  Future<void> _resetDefault() async {
    setState(() => _loading = true);
    await ref.read(settingsRepositoryProvider).setString('system_prompt', '');
    _systemPromptController.clear();
    if (mounted) {
      setState(() => _loading = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已恢复默认提示词')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AppBackScope(
      onBack: () => context.go('/settings'),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('提示词设置'),
          leading: IconButton(
            icon: const Icon(CupertinoIcons.chevron_left),
            onPressed: () => context.go('/settings'),
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: ListView(
            children: <Widget>[
              Text('自定义系统提示词',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '可填写年级水平、讲解详略、语气风格等教学偏好；内容会安全追加在默认指令之后，不会破坏 JSON 解析结构。留空则使用默认提示词。',
                style: TextStyle(
                  fontSize: 12,
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _systemPromptController,
                maxLines: 10,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '例如：面向初二学生，步骤尽量细致，重点指出易错陷阱与语气鼓励...',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _loading ? null : _save,
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('保存提示词'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('prompt-reset-default'),
                onPressed: _loading ? null : _resetDefault,
                icon: const Icon(CupertinoIcons.arrow_counterclockwise, size: 18),
                label: const Text('恢复默认'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
