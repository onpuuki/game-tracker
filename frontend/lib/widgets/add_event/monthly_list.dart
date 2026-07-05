import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:intl/intl.dart';
import 'add_event_providers.dart';

class MonthlyList extends HookConsumerWidget {
  const MonthlyList({super.key});

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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final monthlyStartDate = ref.watch(addEventProvider.select((s) => s.monthlyStartDate));
    final monthlyTime = ref.watch(addEventProvider.select((s) => s.monthlyTime));
    final monthlyTasks = ref.watch(addEventProvider.select((s) => s.monthlyTasks));
    final notifier = ref.read(addEventProvider.notifier);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Row(
                children: [
                  const Text('毎月の実行日 (起算用):', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: () => _selectDate(context, notifier.updateMonthlyStartDate, monthlyStartDate),
                    child: Text(monthlyStartDate != null
                        ? DateFormat('dd').format(monthlyStartDate)
                        : '日付選択'),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Text('実行時刻:', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: () => _selectTime(context, notifier.updateMonthlyTime, monthlyTime),
                    child: Text(monthlyTime?.format(context) ?? '時間選択'),
                  ),
                ],
              ),
            ],
          ),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: monthlyTasks.length,
          itemBuilder: (context, index) {
            final task = monthlyTasks[index];
            return Padding(
              key: ValueKey(task.id),
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Row(
                children: [
                  Expanded(
                    child: _TaskTextField(
                      initialText: task.text,
                      onChanged: (val) => notifier.updateMonthlyTask(index, val),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => notifier.removeMonthlyTask(index),
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
            onPressed: notifier.addMonthlyTask,
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
