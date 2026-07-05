import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:intl/intl.dart';
import 'add_event_providers.dart';

class BiweeklyList extends HookConsumerWidget {
  const BiweeklyList({super.key});

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
    final biweeklyStartDate = ref.watch(addEventProvider.select((s) => s.biweeklyStartDate));
    final biweeklyTime = ref.watch(addEventProvider.select((s) => s.biweeklyTime));
    final biweeklyTasks = ref.watch(addEventProvider.select((s) => s.biweeklyTasks));
    final notifier = ref.read(addEventProvider.notifier);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: [
              Row(
                children: [
                  const Text('起点日:', style: TextStyle(fontSize: 16)),
                  const SizedBox(width: 16),
                  ElevatedButton(
                    onPressed: () => _selectDate(context, notifier.updateBiweeklyStartDate, biweeklyStartDate),
                    child: Text(biweeklyStartDate != null
                        ? DateFormat('yyyy-MM-dd').format(biweeklyStartDate)
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
                    onPressed: () => _selectTime(context, notifier.updateBiweeklyTime, biweeklyTime),
                    child: Text(biweeklyTime?.format(context) ?? '時間選択'),
                  ),
                ],
              ),
            ],
          ),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: biweeklyTasks.length,
          itemBuilder: (context, index) {
            final task = biweeklyTasks[index];
            return Padding(
              key: ValueKey(task.id),
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Row(
                children: [
                  Expanded(
                    child: _TaskTextField(
                      initialText: task.text,
                      onChanged: (val) => notifier.updateBiweeklyTask(index, val),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => notifier.removeBiweeklyTask(index),
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
            onPressed: notifier.addBiweeklyTask,
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
