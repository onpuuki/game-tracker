import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'add_event_providers.dart';
import 'top_section.dart';
import 'daily_list.dart';
import 'weekly_list.dart';
import 'biweekly_list.dart';
import 'monthly_list.dart';

class AddTab extends HookConsumerWidget {
  const AddTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only watch cycleType to conditionally render lists
    final cycleType = ref.watch(addEventProvider.select((s) => s.cycleType));
    final notifier = ref.read(addEventProvider.notifier);

    return SingleChildScrollView(
      child: Column(
        children: [
          const TopSection(),
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
            selected: {cycleType},
            onSelectionChanged: (Set<String> newSelection) {
              notifier.updateCycleType(newSelection.first);
            },
          ),
          const SizedBox(height: 16),
          if (cycleType == 'daily') const DailyList(),
          if (cycleType == 'weekly') const WeeklyList(),
          if (cycleType == 'biweekly') const BiweeklyList(),
          if (cycleType == 'monthly') const MonthlyList(),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16.0),
              ),
              onPressed: () {
                notifier.submitData(context);
              },
              child: const Text('登録', style: TextStyle(fontSize: 18)),
            ),
          ),
        ],
      ),
    );
  }
}
