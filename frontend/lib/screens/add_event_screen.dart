import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

class AddEventScreen extends StatefulWidget {
  const AddEventScreen({super.key});

  @override
  State<AddEventScreen> createState() => _AddEventScreenState();
}

class _AddEventScreenState extends State<AddEventScreen> {
  final TextEditingController _gameNameController = TextEditingController();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();

  String _mainTag = 'ゲーム内';
  String _subTag = '常設';

  String _cycleType = 'daily';

  TimeOfDay? _dailyTime;
  final List<TextEditingController> _dailyTaskControllers = [];

  String? _weeklyDayOfWeek;
  TimeOfDay? _weeklyTime;
  final List<TextEditingController> _weeklyTaskControllers = [];

  DateTime? _biweeklyStartDate;
  TimeOfDay? _biweeklyTime;
  final List<TextEditingController> _biweeklyTaskControllers = [];

  DateTime? _monthlyStartDate;
  TimeOfDay? _monthlyTime;
  final List<TextEditingController> _monthlyTaskControllers = [];

  final List<String> _daysOfWeek = ['月', '火', '水', '木', '金', '土', '日'];

  @override
  void dispose() {
    _gameNameController.dispose();
    _titleController.dispose();
    _codeController.dispose();
    for (var controller in _dailyTaskControllers) { controller.dispose(); }
    for (var controller in _weeklyTaskControllers) { controller.dispose(); }
    for (var controller in _biweeklyTaskControllers) { controller.dispose(); }
    for (var controller in _monthlyTaskControllers) { controller.dispose(); }
    super.dispose();
  }

  Future<void> _submitData(String cycleType) async {
    final gameName = _gameNameController.text.trim();
    final title = _titleController.text.trim();

    if (gameName.isEmpty || title.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ゲーム名とタイトルを入力してください')),
      );
      return;
    }

    DateTime now = DateTime.now();
    DateTime endDate = now;
    Map<String, dynamic> cycleSettings = {};
    List<Map<String, dynamic>> tasks = [];
    String tag = '';

    if (cycleType == 'daily') {
      if (_dailyTime == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('時刻を選択してください')));
        return;
      }
      endDate = DateTime(now.year, now.month, now.day, _dailyTime!.hour, _dailyTime!.minute);
      if (endDate.isBefore(now)) {
        endDate = endDate.add(const Duration(days: 1));
      }
      cycleSettings = {'hour': _dailyTime!.hour, 'minute': _dailyTime!.minute};
      tasks = _dailyTaskControllers.map((c) => {'name': c.text, 'isCompleted': false}).toList();
      tag = 'デイリー';
    } else if (cycleType == 'weekly') {
      if (_weeklyDayOfWeek == null || _weeklyTime == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('曜日と時刻を選択してください')));
        return;
      }
      final targetWeekday = _daysOfWeek.indexOf(_weeklyDayOfWeek!) + 1; // 1:Mon, ..., 7:Sun
      endDate = DateTime(now.year, now.month, now.day, _weeklyTime!.hour, _weeklyTime!.minute);
      while (endDate.weekday != targetWeekday || endDate.isBefore(now)) {
        endDate = endDate.add(const Duration(days: 1));
      }
      cycleSettings = {'dayOfWeek': targetWeekday, 'hour': _weeklyTime!.hour, 'minute': _weeklyTime!.minute};
      tasks = _weeklyTaskControllers.map((c) => {'name': c.text, 'isCompleted': false}).toList();
      tag = 'ウィークリー';
    } else if (cycleType == 'biweekly') {
      if (_biweeklyStartDate == null || _biweeklyTime == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('起点日時を選択してください')));
        return;
      }
      endDate = DateTime(_biweeklyStartDate!.year, _biweeklyStartDate!.month, _biweeklyStartDate!.day, _biweeklyTime!.hour, _biweeklyTime!.minute);
      while (endDate.isBefore(now)) {
        endDate = endDate.add(const Duration(days: 14));
      }
      cycleSettings = {'startDate': _biweeklyStartDate!.toIso8601String(), 'hour': _biweeklyTime!.hour, 'minute': _biweeklyTime!.minute};
      tasks = _biweeklyTaskControllers.map((c) => {'name': c.text, 'isCompleted': false}).toList();
      tag = '隔週';
    } else if (cycleType == 'monthly') {
      if (_monthlyStartDate == null || _monthlyTime == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('起点日時を選択してください')));
        return;
      }
      endDate = DateTime(now.year, now.month, _monthlyStartDate!.day, _monthlyTime!.hour, _monthlyTime!.minute);
      if (endDate.isBefore(now)) {
        endDate = DateTime(now.year, now.month + 1, _monthlyStartDate!.day, _monthlyTime!.hour, _monthlyTime!.minute);
      }
      cycleSettings = {'dayOfMonth': _monthlyStartDate!.day, 'hour': _monthlyTime!.hour, 'minute': _monthlyTime!.minute};
      tasks = _monthlyTaskControllers.map((c) => {'name': c.text, 'isCompleted': false}).toList();
      tag = 'マンスリー';
    }

    final data = {
      'gameName': gameName,
      'title': title,
      'tag': tag,
      'subTag': _subTag,
      'redeemCode': _codeController.text,
      'startDate': Timestamp.fromDate(now),
      'endDate': Timestamp.fromDate(endDate),
      'isCycleEvent': true,
      'cycleType': cycleType,
      'cycleSettings': cycleSettings,
      'tasks': tasks,
      'isCompleted': false,
      'isLocked': false,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };

    try {
      await FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('games').doc(gameName).collection('events').add(data);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$tag イベントを追加しました')),
      );
      _titleController.clear();
      _codeController.clear();
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('追加に失敗しました: $e')),
      );
    }
  }

  Future<void> _selectTime(BuildContext context, Function(TimeOfDay?) onSelected, TimeOfDay? initialTime) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: initialTime ?? TimeOfDay.now(),
    );
    if (picked != null) {
      onSelected(picked);
    }
  }

  Future<void> _selectDate(BuildContext context, Function(DateTime?) onSelected, DateTime? initialDate) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initialDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2101),
    );
    if (picked != null) {
      onSelected(picked);
    }
  }

  Widget _buildTopSection() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _gameNameController,
            decoration: const InputDecoration(labelText: 'ゲーム名'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(labelText: 'タイトル'),
          ),
          const SizedBox(height: 16),
          const Text('メインタグ'),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'ゲーム内', label: Text('ゲーム内')),
              ButtonSegment(value: 'ゲーム外', label: Text('ゲーム外')),
              ButtonSegment(value: 'コード', label: Text('コード')),
            ],
            selected: {_mainTag},
            onSelectionChanged: (Set<String> newSelection) {
              setState(() {
                _mainTag = newSelection.first;
              });
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
            selected: {_subTag},
            onSelectionChanged: (Set<String> newSelection) {
              setState(() {
                _subTag = newSelection.first;
              });
            },
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _codeController,
            decoration: const InputDecoration(labelText: 'コード (任意)'),
          ),
        ],
      ),
    );
  }

  Widget _buildDailyList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              const Text('実行時刻:', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => _selectTime(context, (time) => setState(() => _dailyTime = time), _dailyTime),
                child: Text(_dailyTime?.format(context) ?? '時間選択'),
              ),
            ],
          ),
        ),
        const Divider(),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _dailyTaskControllers.length,
          itemBuilder: (context, index) {
            return ListTile(
              title: TextField(
                controller: _dailyTaskControllers[index],
                decoration: const InputDecoration(hintText: 'タスク名'),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => setState(() {
                  _dailyTaskControllers[index].dispose();
                  _dailyTaskControllers.removeAt(index);
                }),
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('タスクを追加'),
            onPressed: () => setState(() {
              _dailyTaskControllers.add(TextEditingController());
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildWeeklyList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              const Text('実行曜日・時刻:', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 16),
              DropdownButton<String>(
                value: _weeklyDayOfWeek,
                hint: const Text('曜日'),
                items: _daysOfWeek.map((String day) {
                  return DropdownMenuItem<String>(
                    value: day,
                    child: Text(day),
                  );
                }).toList(),
                onChanged: (String? newValue) {
                  setState(() {
                    _weeklyDayOfWeek = newValue;
                  });
                },
              ),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => _selectTime(context, (time) => setState(() => _weeklyTime = time), _weeklyTime),
                child: Text(_weeklyTime?.format(context) ?? '時間選択'),
              ),
            ],
          ),
        ),
        const Divider(),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _weeklyTaskControllers.length,
          itemBuilder: (context, index) {
            return ListTile(
              title: TextField(
                controller: _weeklyTaskControllers[index],
                decoration: const InputDecoration(hintText: 'タスク名'),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => setState(() {
                  _weeklyTaskControllers[index].dispose();
                  _weeklyTaskControllers.removeAt(index);
                }),
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('タスクを追加'),
            onPressed: () => setState(() {
              _weeklyTaskControllers.add(TextEditingController());
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildBiweeklyList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              const Text('起点日時:', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () async {
                  await _selectDate(context, (date) => setState(() => _biweeklyStartDate = date), _biweeklyStartDate);
                  if (!mounted) return;
                  await _selectTime(context, (time) => setState(() => _biweeklyTime = time), _biweeklyTime);
                },
                child: Text(
                  _biweeklyStartDate != null
                      ? '${_biweeklyStartDate!.month}/${_biweeklyStartDate!.day} ${_biweeklyTime?.format(context) ?? ''}'
                      : '日時選択',
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _biweeklyTaskControllers.length,
          itemBuilder: (context, index) {
            return ListTile(
              title: TextField(
                controller: _biweeklyTaskControllers[index],
                decoration: const InputDecoration(hintText: 'タスク名'),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => setState(() {
                  _biweeklyTaskControllers[index].dispose();
                  _biweeklyTaskControllers.removeAt(index);
                }),
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('タスクを追加'),
            onPressed: () => setState(() {
              _biweeklyTaskControllers.add(TextEditingController());
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildMonthlyList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              const Text('起点日時:', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () async {
                  await _selectDate(context, (date) => setState(() => _monthlyStartDate = date), _monthlyStartDate);
                  if (!mounted) return;
                  await _selectTime(context, (time) => setState(() => _monthlyTime = time), _monthlyTime);
                },
                child: Text(
                  _monthlyStartDate != null
                      ? '${_monthlyStartDate!.month}/${_monthlyStartDate!.day} ${_monthlyTime?.format(context) ?? ''}'
                      : '日時選択',
                ),
              ),
            ],
          ),
        ),
        const Divider(),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _monthlyTaskControllers.length,
          itemBuilder: (context, index) {
            return ListTile(
              title: TextField(
                controller: _monthlyTaskControllers[index],
                decoration: const InputDecoration(hintText: 'タスク名'),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete),
                onPressed: () => setState(() {
                  _monthlyTaskControllers[index].dispose();
                  _monthlyTaskControllers.removeAt(index);
                }),
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('タスクを追加'),
            onPressed: () => setState(() {
              _monthlyTaskControllers.add(TextEditingController());
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildAddTab() {
    return SingleChildScrollView(
      child: Column(
        children: [
          _buildTopSection(),
          const SizedBox(height: 16),
          const Text('サイクル', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'daily', label: Text('デイリー')),
              ButtonSegment(value: 'weekly', label: Text('ウィークリー')),
              ButtonSegment(value: 'biweekly', label: Text('隔週')),
              ButtonSegment(value: 'monthly', label: Text('マンスリー')),
            ],
            selected: {_cycleType},
            onSelectionChanged: (Set<String> newSelection) {
              setState(() {
                _cycleType = newSelection.first;
              });
            },
          ),
          const SizedBox(height: 16),
          if (_cycleType == 'daily') _buildDailyList(),
          if (_cycleType == 'weekly') _buildWeeklyList(),
          if (_cycleType == 'biweekly') _buildBiweeklyList(),
          if (_cycleType == 'monthly') _buildMonthlyList(),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16.0),
              ),
              onPressed: () {
                _submitData(_cycleType);
              },
              child: const Text('登録', style: TextStyle(fontSize: 18)),
            ),
          ),
        ],
      ),
    );
  }

  Timestamp? _parseTimestamp(dynamic val) {
    if (val == null) return null;
    if (val is Timestamp) return val;
    if (val is String) {
      final dt = DateTime.tryParse(val);
      if (dt != null) return Timestamp.fromDate(dt);
    }
    return null;
  }

  Widget _buildEditTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collectionGroup('events').where('isCycleEvent', isEqualTo: true).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('Error: ${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

        final docs = snapshot.data!.docs;
        if (docs.isEmpty) return const Center(child: Text('登録されたサイクルイベントがありません'));

        return ListView.builder(
          itemCount: docs.length,
          itemBuilder: (context, index) {
            final doc = docs[index];
            final data = Map<String, dynamic>.from(doc.data() as Map<String, dynamic>);

            data['createdAt'] = _parseTimestamp(data['createdAt']);
            data['updatedAt'] = _parseTimestamp(data['updatedAt']);
            data['startDate'] = _parseTimestamp(data['startDate']);
            data['endDate'] = _parseTimestamp(data['endDate']);

            final title = data['title'] ?? '';
            final gameName = data['gameName'] ?? '';
            final tag = data['tag'] ?? '';

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
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
                        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('削除')),
                      ],
                    ),
                  );
                  if (confirm == true) {
                    await doc.reference.delete();
                  }
                },
              ),
              onTap: () => _showEditDialog(doc, data),
            );
          },
        );
      },
    );
  }

  Future<void> _showEditDialog(DocumentSnapshot doc, Map<String, dynamic> data) async {
    final titleCtrl = TextEditingController(text: data['title'] ?? '');
    final codeCtrl = TextEditingController(text: data['redeemCode'] ?? '');
    final summaryCtrl = TextEditingController(text: data['summary'] ?? '');

    // We clone tasks so we can modify them locally before saving
    final List<Map<String, dynamic>> tasks = [];
    if (data['tasks'] != null) {
      for (var t in data['tasks']) {
        tasks.add(Map<String, dynamic>.from(t));
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
                    const Text('スケジュールの編集は現在のところサポートされていません。必要に応じて削除し、再作成してください。', style: TextStyle(color: Colors.red, fontSize: 12)),
                    const Divider(),
                    const Text('タスク', style: TextStyle(fontWeight: FontWeight.bold)),
                    ...tasks.asMap().entries.map((entry) {
                      final index = entry.key;
                      final task = entry.value;
                      return Row(
                        key: ObjectKey(task),
                        children: [
                          Expanded(
                            child: TextFormField(
                              initialValue: task['name'],
                              decoration: const InputDecoration(hintText: 'タスク名'),
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
                          )
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
                    )
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
          }
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('サイクルイベント管理'),
          bottom: const TabBar(
            tabs: [
              Tab(text: '追加'),
              Tab(text: '編集・削除'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildAddTab(),
            _buildEditTab(),
          ],
        ),
      ),
    );
  }
}
