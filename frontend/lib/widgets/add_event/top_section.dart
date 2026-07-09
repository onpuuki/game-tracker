import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'add_event_providers.dart';

class TopSection extends HookConsumerWidget {
  const TopSection({super.key});

  Future<void> _showImportDialog(
    BuildContext context,
    AddEventNotifier notifier,
  ) async {
    final controller = TextEditingController();
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('テキストインポート'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'フォーマットに従って入力してください。',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  maxLines: 15,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    hintText: 'ゲーム名: ...',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
            ElevatedButton(
              onPressed: () {
                final success = notifier.importFromText(
                  controller.text,
                  context,
                );
                if (success) Navigator.pop(context);
              },
              child: const Text('インポート'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only watch specific fields to avoid full rebuilds on every typing
    final mainTag = ref.watch(addEventProvider.select((s) => s.mainTag));
    final subTag = ref.watch(addEventProvider.select((s) => s.subTag));

    // We only read state once for initial text to avoid cursor jumping
    final initialState = ref.read(addEventProvider);
    final notifier = ref.read(addEventProvider.notifier);

    final gameNameController = useTextEditingController(
      text: initialState.gameName,
    );
    final titleController = useTextEditingController(text: initialState.title);
    final codeController = useTextEditingController(text: initialState.code);

    // Sync state changes back to controllers if state is modified externally (e.g., cleared after submit)
    ref.listen(addEventProvider.select((s) => s.gameName), (_, next) {
      if (gameNameController.text != next) gameNameController.text = next;
    });
    ref.listen(addEventProvider.select((s) => s.title), (_, next) {
      if (titleController.text != next) titleController.text = next;
    });
    ref.listen(addEventProvider.select((s) => s.code), (_, next) {
      if (codeController.text != next) codeController.text = next;
    });

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: ElevatedButton.icon(
              onPressed: () => _showImportDialog(context, notifier),
              icon: const Icon(Icons.file_download),
              label: const Text('テキストからインポート'),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: gameNameController,
            decoration: const InputDecoration(labelText: 'ゲーム名'),
            onChanged: notifier.updateGameName,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: titleController,
            decoration: const InputDecoration(labelText: 'タイトル'),
            onChanged: notifier.updateTitle,
          ),
          const SizedBox(height: 16),
          const Text('メインタグ'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ゲーム内', label: Text('ゲーム内')),
              ButtonSegment(value: 'ゲーム外', label: Text('ゲーム外')),
              ButtonSegment(value: 'コード', label: Text('コード')),
            ],
            selected: {mainTag},
            onSelectionChanged: (Set<String> newSelection) {
              notifier.updateMainTag(newSelection.first);
            },
          ),
          const SizedBox(height: 16),
          const Text('サブタグ'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ガチャ', label: Text('ガチャ')),
              ButtonSegment(value: '期間限定', label: Text('期間限定')),
              ButtonSegment(value: '常設', label: Text('常設')),
            ],
            selected: {subTag},
            onSelectionChanged: (Set<String> newSelection) {
              notifier.updateSubTag(newSelection.first);
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: codeController,
            decoration: const InputDecoration(labelText: 'コード (任意)'),
            onChanged: notifier.updateCode,
          ),
        ],
      ),
    );
  }
}
