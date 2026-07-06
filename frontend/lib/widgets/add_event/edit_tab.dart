import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class EditTab extends HookConsumerWidget {
  const EditTab({super.key});

  Timestamp? _parseTimestamp(dynamic val) {
    if (val == null) return null;
    if (val is Timestamp) return val;
    if (val is String) {
      final dt = DateTime.tryParse(val);
      if (dt != null) return Timestamp.fromDate(dt);
    }
    return null;
  }

  Future<void> _showEditDialog(
    BuildContext context,
    DocumentSnapshot doc,
    Map<String, dynamic> data,
  ) async {
    final titleCtrl = TextEditingController(
      text: data['title']?.toString() ?? '',
    );
    final codeCtrl = TextEditingController(
      text: data['redeemCode']?.toString() ?? '',
    );
    final summaryCtrl = TextEditingController(
      text: data['summary']?.toString() ?? '',
    );

    // We clone tasks so we can modify them locally before saving
    final List<Map<String, dynamic>> tasks = [];
    if (data['tasks'] is List) {
      for (var t in data['tasks']) {
        if (t is Map) {
          tasks.add(Map<String, dynamic>.from(t));
        }
      }
    }

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('サイクルイベントを編集'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleCtrl,
                      decoration: const InputDecoration(labelText: 'タイトル'),
                    ),
                    TextField(
                      controller: codeCtrl,
                      decoration: const InputDecoration(labelText: 'コード (任意)'),
                    ),
                    TextField(
                      controller: summaryCtrl,
                      decoration: const InputDecoration(labelText: 'サマリー (任意)'),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'スケジュールの編集は現在のところサポートされていません。必要に応じて削除し、再作成してください。',
                      style: TextStyle(color: Colors.red, fontSize: 12),
                    ),
                    const Divider(),
                    const Text(
                      'タスク',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    ...tasks.asMap().entries.map((entry) {
                      final index = entry.key;
                      final task = entry.value;
                      return Row(
                        key: ObjectKey(task),
                        children: [
                          Expanded(
                            child: TextFormField(
                              initialValue: task['name'],
                              decoration: const InputDecoration(
                                hintText: 'タスク名',
                              ),
                              onChanged: (val) {
                                task['name'] = val;
                              },
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.delete),
                            onPressed: () {
                              setDialogState(() {
                                tasks.removeAt(index);
                              });
                            },
                          ),
                        ],
                      );
                    }),
                    TextButton.icon(
                      onPressed: () {
                        setDialogState(() {
                          tasks.add({'name': '', 'isCompleted': false});
                        });
                      },
                      icon: const Icon(Icons.add),
                      label: const Text('タスクを追加'),
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
                  onPressed: () async {
                    await doc.reference.update({
                      'title': titleCtrl.text.trim(),
                      'redeemCode': codeCtrl.text.trim(),
                      'summary': summaryCtrl.text.trim(),
                      'tasks': tasks,
                      'updatedAt': FieldValue.serverTimestamp(),
                    });
                    if (context.mounted) {
                      Navigator.pop(context);
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('イベントとタスクを更新しました')),
                      );
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return StreamBuilder<QuerySnapshot>(
      stream:
          FirebaseFirestore.instanceFor(
                app: Firebase.app(),
                databaseId: 'default',
              )
              .collectionGroup('events')
              .where('isCycleEvent', isEqualTo: true)
              .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError)
          return Center(child: Text('Error: ${snapshot.error}'));
        if (!snapshot.hasData)
          return const Center(child: CircularProgressIndicator());

        final docs = snapshot.data!.docs;
        if (docs.isEmpty)
          return const Center(child: Text('登録されたサイクルイベントがありません'));

        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, index) {
            try {
              final doc = docs[index];
              final data = Map<String, dynamic>.from(
                doc.data() as Map<String, dynamic>,
              );

              data['createdAt'] = _parseTimestamp(data['createdAt']);
              data['updatedAt'] = _parseTimestamp(data['updatedAt']);
              data['startDate'] = _parseTimestamp(data['startDate']);
              data['endDate'] = _parseTimestamp(data['endDate']);

              final title = data['title']?.toString() ?? 'タイトルなし';
              final gameName = data['gameName']?.toString() ?? 'ゲーム名なし';
              final tag = data['tag']?.toString() ?? '';

              return ListTile(
                title: Text(title),
                subtitle: Text('$gameName - $tag'),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (c) => AlertDialog(
                        title: const Text('削除確認'),
                        content: const Text('このサイクルイベントを削除しますか？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(c, false),
                            child: const Text('キャンセル'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(c, true),
                            child: const Text('削除'),
                          ),
                        ],
                      ),
                    );
                    if (confirm == true) {
                      await doc.reference.delete();
                    }
                  },
                ),
                onTap: () => _showEditDialog(context, doc, data),
              );
            } catch (e) {
              return const ListTile(
                title: Text(
                  'データの読み込みに失敗しました',
                  style: TextStyle(color: Colors.red),
                ),
              );
            }
          },
        );
      },
    );
  }
}
