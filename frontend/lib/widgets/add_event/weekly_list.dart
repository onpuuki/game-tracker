import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'add_event_providers.dart';

class WeeklyList extends HookConsumerWidget {
  const WeeklyList({super.key});

  Future<void> _selectTime(BuildContext context, Function(TimeOfDay?) onSelected, TimeOfDay? initialTime) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: initialTime ?? TimeOfDay.now(),
    );
    if (picked != null) {
      onSelected(picked);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final weeklyDayOfWeek = ref.watch(addEventProvider.select((s) => s.weeklyDayOfWeek));
    final weeklyTime = ref.watch(addEventProvider.select((s) => s.weeklyTime));
    final weeklyTasks = ref.watch(addEventProvider.select((s) => s.weeklyTasks));
    final notifier = ref.read(addEventProvider.notifier);

    final daysOfWeek = ['月', '火', '水', '木', '金', '土', '日'];

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              const Text('曜日:', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 16),
              DropdownButton<String>(
                value: weeklyDayOfWeek,
                hint: const Text('選択'),
                items: daysOfWeek.map((String day) {
                  return DropdownMenuItem<String>(
                    value: day,
                    child: Text(day),
                  );
                }).toList(),
                onChanged: notifier.updateWeeklyDayOfWeek,
              ),
              const SizedBox(width: 32),
              const Text('実行時刻:', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => _selectTime(context, notifier.updateWeeklyTime, weeklyTime),
                child: Text(weeklyTime?.format(context) ?? '時間選択'),
              ),
            ],
          ),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: weeklyTasks.length,
          itemBuilder: (context, index) {
            final task = weeklyTasks[index];
            return Padding(
              key: ValueKey(task.id),
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Row(
                children: [
                  Expanded(
                    child: _TaskTextField(
                      initialText: task.text,
                      onChanged: (val) => notifier.updateWeeklyTask(index, val),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => notifier.removeWeeklyTask(index),
                  ),
                ],
              ),
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('タスクを追加'),
            onPressed: notifier.addWeeklyTask,
          ),
        ),
      ],
    );
  }
}

class _TaskTextField extends HookWidget {
  final String initialText;
  final ValueChanged<String> onChanged;

  const _TaskTextField({required this.initialText, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final controller = useTextEditingController(text: initialText);

    return TextFormField(
      controller: controller,
      decoration: const InputDecoration(
        labelText: 'タスク名',
        border: OutlineInputBorder(),
      ),
      onChanged: onChanged,
    );
  }
}
