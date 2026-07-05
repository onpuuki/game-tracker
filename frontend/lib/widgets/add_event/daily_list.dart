import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'add_event_providers.dart';

class DailyList extends HookConsumerWidget {
  const DailyList({super.key});

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
    final dailyTime = ref.watch(addEventProvider.select((s) => s.dailyTime));
    final dailyTasks = ref.watch(addEventProvider.select((s) => s.dailyTasks));
    final notifier = ref.read(addEventProvider.notifier);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              const Text('実行時刻:', style: TextStyle(fontSize: 16)),
              const SizedBox(width: 16),
              ElevatedButton(
                onPressed: () => _selectTime(context, notifier.updateDailyTime, dailyTime),
                child: Text(dailyTime?.format(context) ?? '時間選択'),
              ),
            ],
          ),
        ),
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: dailyTasks.length,
          itemBuilder: (context, index) {
            final task = dailyTasks[index];
            return Padding(
              key: ValueKey(task.id), // Use the unique ID as the key to prevent cursor jumping when items are removed
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
              child: Row(
                children: [
                  Expanded(
                    child: _TaskTextField(
                      initialText: task.text,
                      onChanged: (val) => notifier.updateDailyTask(index, val),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red),
                    onPressed: () => notifier.removeDailyTask(index),
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
            onPressed: notifier.addDailyTask,
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
