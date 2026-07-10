import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final text =
                          r'''以下の【インプット情報】（ゲームのイベントや更新コンテンツ情報）を解析し、指定の【出力フォーマット】に従ってインポート用のテキストを生成してください。複数のイベントが含まれている場合は、イベントごとに分けて出力してください。

【出力フォーマット】
（※コピー時のフォーマット欠落を防ぐため、1つのイベントにつき1つのコードブロック ```text 〜 ``` で個別に囲んで出力してください。複数ある場合はコードブロックも複数に分けてください）

```text
ゲーム名: （インプット情報から推測して記載）
タイトル: （イベントやコンテンツの名称）
サイクル: （デイリー / ウィークリー / 隔週 / マンスリー のいずれかを判定）
曜日: （ウィークリーの場合のみ必須。月〜日のいずれか）
起点日: （隔週の場合のみ必須。YYYY-MM-DD形式。不明な場合は今日の日付）
日付: （マンスリーの場合のみ必須。1〜31の数字）
時刻: （リセット時刻をHH:mm形式で記載。不明な場合は04:00など一般的な時間を推測して設定）
タスク:
- （タスク内容1）
- （タスク内容2）
```

【判定・出力の注意点】
- タスクの行頭は、必ず半角ハイフンと半角スペース「- 」を使用してください。（アプリのデータ取り込みで必須となります）
- 毎日更新・リセットされるものは「デイリー」
- 毎週決まった曜日に更新されるものは「ウィークリー」
- 14日周期や半月に1回更新されるもの（螺旋、深塔など）は「隔週」
- 月に1回（1日など）更新されるものは「マンスリー」
- ※重要※ リセット時刻が不明で04:00などの推測値に設定した場合は、各コードブロックの外側（末尾）に「※〇〇の時刻が不明だったため〇〇:〇〇に推測して設定しました」と報告文を必ず添えてください。

【インプット情報】
（ここに攻略サイト等の情報をペーストしてください）''';
                      await Clipboard.setData(ClipboardData(text: text));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('プロンプトをクリップボードにコピーしました'),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('Gemini作成依頼プロンプトをコピー'),
                  ),
                ),
                const SizedBox(height: 12),
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
