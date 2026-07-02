import 'package:flutter/material.dart';

class DailyTask {
  TimeOfDay? time;
  final TextEditingController nameController = TextEditingController();

  void dispose() {
    nameController.dispose();
  }
}

class WeeklyTask {
  String? dayOfWeek;
  TimeOfDay? time;
  final TextEditingController nameController = TextEditingController();

  void dispose() {
    nameController.dispose();
  }
}

class BiweeklyTask {
  DateTime? startDate;
  TimeOfDay? time;
  final TextEditingController nameController = TextEditingController();

  void dispose() {
    nameController.dispose();
  }
}

class MonthlyTask {
  DateTime? startDate;
  TimeOfDay? time;
  final TextEditingController nameController = TextEditingController();

  void dispose() {
    nameController.dispose();
  }
}

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

  final List<DailyTask> _dailyTasks = [];
  final List<WeeklyTask> _weeklyTasks = [];
  final List<BiweeklyTask> _biweeklyTasks = [];
  final List<MonthlyTask> _monthlyTasks = [];

  final List<String> _daysOfWeek = ['月', '火', '水', '木', '金', '土', '日'];

  @override
  void dispose() {
    _gameNameController.dispose();
    _titleController.dispose();
    _codeController.dispose();
    for (var task in _dailyTasks) { task.dispose(); }
    for (var task in _weeklyTasks) { task.dispose(); }
    for (var task in _biweeklyTasks) { task.dispose(); }
    for (var task in _monthlyTasks) { task.dispose(); }
    super.dispose();
  }

  void _submitData() {
    debugPrint('=== Submitted Data ===');
    debugPrint('Game Name: ${_gameNameController.text}');
    debugPrint('Title: ${_titleController.text}');
    debugPrint('Main Tag: $_mainTag');
    debugPrint('Sub Tag: $_subTag');
    debugPrint('Code: ${_codeController.text}');

    debugPrint('--- Daily Tasks ---');
    for (var task in _dailyTasks) {
      debugPrint('Time: ${task.time?.format(context)}, Name: ${task.nameController.text}');
    }

    debugPrint('--- Weekly Tasks ---');
    for (var task in _weeklyTasks) {
      debugPrint('Day: ${task.dayOfWeek}, Time: ${task.time?.format(context)}, Name: ${task.nameController.text}');
    }

    debugPrint('--- Biweekly Tasks ---');
    for (var task in _biweeklyTasks) {
      debugPrint('StartDate: ${task.startDate?.toIso8601String().split('T')[0]}, Time: ${task.time?.format(context)}, Name: ${task.nameController.text}');
    }

    debugPrint('--- Monthly Tasks ---');
    for (var task in _monthlyTasks) {
      debugPrint('StartDate: ${task.startDate?.toIso8601String().split('T')[0]}, Time: ${task.time?.format(context)}, Name: ${task.nameController.text}');
    }
    debugPrint('======================');

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('登録内容をコンソールに出力しました')),
    );
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
        Expanded(
          child: ListView.builder(
            itemCount: _dailyTasks.length,
            itemBuilder: (context, index) {
              final task = _dailyTasks[index];
              return ListTile(
                leading: TextButton(
                  onPressed: () => _selectTime(context, (time) => setState(() => task.time = time), task.time),
                  child: Text(task.time?.format(context) ?? '時間選択'),
                ),
                title: TextField(
                  controller: task.nameController,
                  decoration: const InputDecoration(hintText: 'タスク名'),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => setState(() {
                    task.dispose();
                    _dailyTasks.removeAt(index);
                  }),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: IconButton(
            icon: const Icon(Icons.add_circle, size: 40),
            onPressed: () => setState(() {
              _dailyTasks.add(DailyTask());
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildWeeklyList() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: _weeklyTasks.length,
            itemBuilder: (context, index) {
              final task = _weeklyTasks[index];
              return ListTile(
                leading: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<String>(
                      value: task.dayOfWeek,
                      hint: const Text('曜日'),
                      items: _daysOfWeek.map((String day) {
                        return DropdownMenuItem<String>(
                          value: day,
                          child: Text(day),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          task.dayOfWeek = newValue;
                        });
                      },
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () => _selectTime(context, (time) => setState(() => task.time = time), task.time),
                      child: Text(task.time?.format(context) ?? '時間選択'),
                    ),
                  ],
                ),
                title: TextField(
                  controller: task.nameController,
                  decoration: const InputDecoration(hintText: 'タスク名'),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => setState(() {
                    task.dispose();
                    _weeklyTasks.removeAt(index);
                  }),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: IconButton(
            icon: const Icon(Icons.add_circle, size: 40),
            onPressed: () => setState(() {
              _weeklyTasks.add(WeeklyTask());
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildBiweeklyList() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: _biweeklyTasks.length,
            itemBuilder: (context, index) {
              final task = _biweeklyTasks[index];
              return ListTile(
                leading: TextButton(
                  onPressed: () async {
                    await _selectDate(context, (date) => setState(() => task.startDate = date), task.startDate);
                    if (!context.mounted) return;
                    await _selectTime(context, (time) => setState(() => task.time = time), task.time);
                  },
                  child: Text(
                    task.startDate != null
                        ? '${task.startDate!.month}/${task.startDate!.day} ${task.time?.format(context) ?? ''}'
                        : '日時選択',
                  ),
                ),
                title: TextField(
                  controller: task.nameController,
                  decoration: const InputDecoration(hintText: 'タスク名'),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => setState(() {
                    task.dispose();
                    _biweeklyTasks.removeAt(index);
                  }),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: IconButton(
            icon: const Icon(Icons.add_circle, size: 40),
            onPressed: () => setState(() {
              _biweeklyTasks.add(BiweeklyTask());
            }),
          ),
        ),
      ],
    );
  }

  Widget _buildMonthlyList() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            itemCount: _monthlyTasks.length,
            itemBuilder: (context, index) {
              final task = _monthlyTasks[index];
              return ListTile(
                leading: TextButton(
                  onPressed: () async {
                    await _selectDate(context, (date) => setState(() => task.startDate = date), task.startDate);
                    if (!context.mounted) return;
                    await _selectTime(context, (time) => setState(() => task.time = time), task.time);
                  },
                  child: Text(
                    task.startDate != null
                        ? '${task.startDate!.month}/${task.startDate!.day} ${task.time?.format(context) ?? ''}'
                        : '日時選択',
                  ),
                ),
                title: TextField(
                  controller: task.nameController,
                  decoration: const InputDecoration(hintText: 'タスク名'),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () => setState(() {
                    task.dispose();
                    _monthlyTasks.removeAt(index);
                  }),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: IconButton(
            icon: const Icon(Icons.add_circle, size: 40),
            onPressed: () => setState(() {
              _monthlyTasks.add(MonthlyTask());
            }),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('イベント追加'),
        ),
        body: Column(
          children: [
            _buildTopSection(),
            const TabBar(
              tabs: [
                Tab(text: 'デイリー'),
                Tab(text: 'ウィークリー'),
                Tab(text: '隔週'),
                Tab(text: 'マンスリー'),
              ],
            ),
            Expanded(
              child: TabBarView(
                children: [
                  _buildDailyList(),
                  _buildWeeklyList(),
                  _buildBiweeklyList(),
                  _buildMonthlyList(),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16.0),
                ),
                onPressed: _submitData,
                child: const Text('登録', style: TextStyle(fontSize: 18)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
