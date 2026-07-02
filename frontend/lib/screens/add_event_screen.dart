import 'package:flutter/material.dart';

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

  void _submitData() {
    debugPrint('=== Submitted Data ===');
    debugPrint('Game Name: ${_gameNameController.text}');
    debugPrint('Title: ${_titleController.text}');
    debugPrint('Main Tag: $_mainTag');
    debugPrint('Sub Tag: $_subTag');
    debugPrint('Code: ${_codeController.text}');

    debugPrint('--- Daily Schedule ---');
    debugPrint('Time: ${_dailyTime?.format(context)}');
    debugPrint('Tasks:');
    for (var controller in _dailyTaskControllers) {
      debugPrint('  - ${controller.text}');
    }

    debugPrint('--- Weekly Schedule ---');
    debugPrint('Day: $_weeklyDayOfWeek, Time: ${_weeklyTime?.format(context)}');
    debugPrint('Tasks:');
    for (var controller in _weeklyTaskControllers) {
      debugPrint('  - ${controller.text}');
    }

    debugPrint('--- Biweekly Schedule ---');
    debugPrint('StartDate: ${_biweeklyStartDate?.toIso8601String().split('T')[0]}, Time: ${_biweeklyTime?.format(context)}');
    debugPrint('Tasks:');
    for (var controller in _biweeklyTaskControllers) {
      debugPrint('  - ${controller.text}');
    }

    debugPrint('--- Monthly Schedule ---');
    debugPrint('StartDate: ${_monthlyStartDate?.toIso8601String().split('T')[0]}, Time: ${_monthlyTime?.format(context)}');
    debugPrint('Tasks:');
    for (var controller in _monthlyTaskControllers) {
      debugPrint('  - ${controller.text}');
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
        Expanded(
          child: ListView.builder(
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
        Expanded(
          child: ListView.builder(
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
                  if (!context.mounted) return;
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
        Expanded(
          child: ListView.builder(
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
                  if (!context.mounted) return;
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
        Expanded(
          child: ListView.builder(
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
