import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import '../widgets/add_event/add_tab.dart';
import '../widgets/add_event/edit_tab.dart';

class AddEventScreen extends HookConsumerWidget {
  const AddEventScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        body: const TabBarView(
          children: [
            AddTab(),
            EditTab(),
          ],
        ),
      ),
    );
  }
}
