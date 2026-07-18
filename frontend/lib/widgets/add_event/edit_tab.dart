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
      final dt = DateTime.tryParse(val.replaceAll('/', '-'));
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


    String? cycleType = data['cycleType']?.toString();
    Map<String, dynamic> cycleSettings = data['cycleSettings'] != null
        ? Map<String, dynamic>.from(data['cycleSettings'])
        : {};

    TimeOfDay? time;
    if (cycleSettings['hour'] != null && cycleSettings['minute'] != null) {
      time = TimeOfDay(
        hour: cycleSettings['hour'] as int,
        minute: cycleSettings['minute'] as int,
      );
    }

    String? weeklyDayOfWeek;
    if (cycleSettings['dayOfWeek'] != null) {
      final days = ['月', '火', '水', '木', '金', '土', '日'];
      final idx = (cycleSettings['dayOfWeek'] as int) - 1;
      if (idx >= 0 && idx < days.length) {
        weeklyDayOfWeek = days[idx];
      }
    }

    DateTime? startDate;
    if (cycleSettings['startDate'] != null) {
      startDate = _parseTimestamp(cycleSettings['startDate'])?.toDate();
    }

    int? dayOfMonth = cycleSettings['dayOfMonth'] as int?;

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
                    if (cycleType == 'daily')
                      Row(
                        children: [
                          const Text('実行時刻: '),
                          TextButton(
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: time ?? TimeOfDay.now(),
                              );
                              if (picked != null) {
                                setDialogState(() {
                                  time = picked;
                                });
                              }
                            },
                            child: Text(time?.format(context) ?? '選択してください'),
                          ),
                        ],
                      ),
                    if (cycleType == 'weekly')
                      Row(
                        children: [
                          const Text('実行曜日: '),
                          DropdownButton<String>(
                            value: weeklyDayOfWeek,
                            items: ['月', '火', '水', '木', '金', '土', '日']
                                .map((day) => DropdownMenuItem(
                                      value: day,
                                      child: Text(day),
                                    ))
                                .toList(),
                            onChanged: (val) {
                              setDialogState(() {
                                weeklyDayOfWeek = val;
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: time ?? TimeOfDay.now(),
                              );
                              if (picked != null) {
                                setDialogState(() {
                                  time = picked;
                                });
                              }
                            },
                            child: Text(time?.format(context) ?? '時刻選択'),
                          ),
                        ],
                      ),
                    if (cycleType == 'biweekly')
                      Row(
                        children: [
                          const Text('起点日: '),
                          TextButton(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: startDate ?? DateTime.now(),
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100),
                              );
                              if (picked != null) {
                                setDialogState(() {
                                  startDate = picked;
                                });
                              }
                            },
                            child: Text(startDate != null
                                ? "${startDate!.year}-${startDate!.month.toString().padLeft(2, '0')}-${startDate!.day.toString().padLeft(2, '0')}"
                                : '日付選択'),
                          ),
                          TextButton(
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: time ?? TimeOfDay.now(),
                              );
                              if (picked != null) {
                                setDialogState(() {
                                  time = picked;
                                });
                              }
                            },
                            child: Text(time?.format(context) ?? '時刻選択'),
                          ),
                        ],
                      ),
                    if (cycleType == 'monthly')
                      Row(
                        children: [
                          const Text('日付: '),
                          DropdownButton<int>(
                            value: dayOfMonth,
                            items: List.generate(31, (i) => i + 1)
                                .map((day) => DropdownMenuItem(
                                      value: day,
                                      child: Text('$day日'),
                                    ))
                                .toList(),
                            onChanged: (val) {
                              setDialogState(() {
                                dayOfMonth = val;
                              });
                            },
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            onPressed: () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: time ?? TimeOfDay.now(),
                              );
                              if (picked != null) {
                                setDialogState(() {
                                  time = picked;
                                });
                              }
                            },
                            child: Text(time?.format(context) ?? '時刻選択'),
                          ),
                        ],
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
                    DateTime now = DateTime.now();
                    DateTime newEndDate = now;
                    bool scheduleUpdated = false;

                    if (time != null && cycleType != null) {
                      if (cycleType == 'daily') {
                        newEndDate = DateTime(now.year, now.month, now.day, time!.hour, time!.minute);
                        if (newEndDate.isBefore(now)) {
                          newEndDate = DateTime(now.year, now.month, now.day + 1, time!.hour, time!.minute);
                        }
                        cycleSettings['hour'] = time!.hour;
                        cycleSettings['minute'] = time!.minute;
                        scheduleUpdated = true;
                      } else if (cycleType == 'weekly' && weeklyDayOfWeek != null) {
                        final daysOfWeek = ['月', '火', '水', '木', '金', '土', '日'];
                        final targetWeekday = daysOfWeek.indexOf(weeklyDayOfWeek!) + 1;
                        newEndDate = DateTime(now.year, now.month, now.day, time!.hour, time!.minute);
                        while (newEndDate.weekday != targetWeekday || newEndDate.isBefore(now)) {
                          newEndDate = DateTime(newEndDate.year, newEndDate.month, newEndDate.day + 1, time!.hour, time!.minute);
                        }
                        cycleSettings['dayOfWeek'] = targetWeekday;
                        cycleSettings['hour'] = time!.hour;
                        cycleSettings['minute'] = time!.minute;
                        scheduleUpdated = true;
                      } else if (cycleType == 'biweekly' && startDate != null) {
                        newEndDate = DateTime(startDate!.year, startDate!.month, startDate!.day, time!.hour, time!.minute);
                        while (newEndDate.isBefore(now)) {
                          newEndDate = DateTime(newEndDate.year, newEndDate.month, newEndDate.day + 14, time!.hour, time!.minute);
                        }
                        cycleSettings['startDate'] = Timestamp.fromDate(startDate!);
                        cycleSettings['hour'] = time!.hour;
                        cycleSettings['minute'] = time!.minute;
                        scheduleUpdated = true;
                      } else if (cycleType == 'monthly' && dayOfMonth != null) {
                        int maxDaysInCurrentMonth = DateTime(now.year, now.month + 1, 0).day;
                        int currentMonthDay = dayOfMonth! > maxDaysInCurrentMonth ? maxDaysInCurrentMonth : dayOfMonth!;
                        newEndDate = DateTime(now.year, now.month, currentMonthDay, time!.hour, time!.minute);
                        if (newEndDate.isBefore(now)) {
                          int nextMonth = now.month + 1;
                          int nextYear = now.year;
                          if (nextMonth > 12) {
                            nextMonth = 1;
                            nextYear += 1;
                          }
                          int maxDaysInNextMonth = DateTime(nextYear, nextMonth + 1, 0).day;
                          int nextMonthDay = dayOfMonth! > maxDaysInNextMonth ? maxDaysInNextMonth : dayOfMonth!;
                          newEndDate = DateTime(nextYear, nextMonth, nextMonthDay, time!.hour, time!.minute);
                        }
                        cycleSettings['dayOfMonth'] = dayOfMonth;
                        cycleSettings['hour'] = time!.hour;
                        cycleSettings['minute'] = time!.minute;
                        scheduleUpdated = true;
                      }
                    }

                    final updateData = <String, dynamic>{
                      'title': titleCtrl.text.trim(),
                      'redeemCode': codeCtrl.text.trim(),
                      'summary': summaryCtrl.text.trim(),
                      'tasks': tasks,
                      'updatedAt': FieldValue.serverTimestamp(),
                    };

                    if (scheduleUpdated) {
                      updateData['endDate'] = Timestamp.fromDate(newEndDate);
                      updateData['cycleSettings'] = cycleSettings;
                    }

                    await doc.reference.update(updateData);
                    if (!context.mounted) return;
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('イベントとタスクを更新しました')),
                    );
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
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        final docs = snapshot.data!.docs;
        if (docs.isEmpty) {
          return const Center(child: Text('登録されたサイクルイベントがありません'));
        }

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
