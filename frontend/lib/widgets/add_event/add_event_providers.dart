import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:intl/intl.dart';

class TaskItem {
  final String id;
  final String text;

  TaskItem({required this.id, required this.text});

  TaskItem copyWith({String? text}) {
    return TaskItem(id: id, text: text ?? this.text);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is TaskItem && other.id == id && other.text == text;
  }

  @override
  int get hashCode => id.hashCode ^ text.hashCode;
}

class AddEventState {
  final String gameName;
  final String title;
  final String code;
  final String mainTag;
  final String subTag;

  final String cycleType;

  final TimeOfDay? dailyTime;
  final List<TaskItem> dailyTasks;

  final String? weeklyDayOfWeek;
  final TimeOfDay? weeklyTime;
  final List<TaskItem> weeklyTasks;

  final DateTime? biweeklyStartDate;
  final TimeOfDay? biweeklyTime;
  final List<TaskItem> biweeklyTasks;

  final DateTime? monthlyStartDate;
  final TimeOfDay? monthlyTime;
  final List<TaskItem> monthlyTasks;

  AddEventState({
    this.gameName = '',
    this.title = '',
    this.code = '',
    this.mainTag = 'ゲーム内',
    this.subTag = '常設',
    this.cycleType = 'daily',
    this.dailyTime,
    this.dailyTasks = const [],
    this.weeklyDayOfWeek,
    this.weeklyTime,
    this.weeklyTasks = const [],
    this.biweeklyStartDate,
    this.biweeklyTime,
    this.biweeklyTasks = const [],
    this.monthlyStartDate,
    this.monthlyTime,
    this.monthlyTasks = const [],
  });

  AddEventState copyWith({
    String? gameName,
    String? title,
    String? code,
    String? mainTag,
    String? subTag,
    String? cycleType,
    TimeOfDay? dailyTime,
    List<TaskItem>? dailyTasks,
    String? weeklyDayOfWeek,
    TimeOfDay? weeklyTime,
    List<TaskItem>? weeklyTasks,
    DateTime? biweeklyStartDate,
    TimeOfDay? biweeklyTime,
    List<TaskItem>? biweeklyTasks,
    DateTime? monthlyStartDate,
    TimeOfDay? monthlyTime,
    List<TaskItem>? monthlyTasks,
  }) {
    return AddEventState(
      gameName: gameName ?? this.gameName,
      title: title ?? this.title,
      code: code ?? this.code,
      mainTag: mainTag ?? this.mainTag,
      subTag: subTag ?? this.subTag,
      cycleType: cycleType ?? this.cycleType,
      dailyTime: dailyTime ?? this.dailyTime,
      dailyTasks: dailyTasks ?? this.dailyTasks,
      weeklyDayOfWeek: weeklyDayOfWeek ?? this.weeklyDayOfWeek,
      weeklyTime: weeklyTime ?? this.weeklyTime,
      weeklyTasks: weeklyTasks ?? this.weeklyTasks,
      biweeklyStartDate: biweeklyStartDate ?? this.biweeklyStartDate,
      biweeklyTime: biweeklyTime ?? this.biweeklyTime,
      biweeklyTasks: biweeklyTasks ?? this.biweeklyTasks,
      monthlyStartDate: monthlyStartDate ?? this.monthlyStartDate,
      monthlyTime: monthlyTime ?? this.monthlyTime,
      monthlyTasks: monthlyTasks ?? this.monthlyTasks,
    );
  }
}

class AddEventNotifier extends Notifier<AddEventState> {
  @override
  AddEventState build() {
    return AddEventState();
  }

  void updateGameName(String val) => state = state.copyWith(gameName: val);
  void updateTitle(String val) => state = state.copyWith(title: val);
  void updateCode(String val) => state = state.copyWith(code: val);
  void updateMainTag(String val) => state = state.copyWith(mainTag: val);
  void updateSubTag(String val) => state = state.copyWith(subTag: val);
  void updateCycleType(String val) => state = state.copyWith(cycleType: val);

  String _uuid() => DateTime.now().microsecondsSinceEpoch.toString();

  void updateDailyTime(TimeOfDay? val) => state = state.copyWith(dailyTime: val);
  void addDailyTask() => state = state.copyWith(dailyTasks: [...state.dailyTasks, TaskItem(id: _uuid(), text: '')]);
  void updateDailyTask(int index, String val) {
    final tasks = List<TaskItem>.from(state.dailyTasks);
    tasks[index] = tasks[index].copyWith(text: val);
    state = state.copyWith(dailyTasks: tasks);
  }
  void removeDailyTask(int index) {
    final tasks = List<TaskItem>.from(state.dailyTasks);
    tasks.removeAt(index);
    state = state.copyWith(dailyTasks: tasks);
  }

  void updateWeeklyDayOfWeek(String? val) => state = state.copyWith(weeklyDayOfWeek: val);
  void updateWeeklyTime(TimeOfDay? val) => state = state.copyWith(weeklyTime: val);
  void addWeeklyTask() => state = state.copyWith(weeklyTasks: [...state.weeklyTasks, TaskItem(id: _uuid(), text: '')]);
  void updateWeeklyTask(int index, String val) {
    final tasks = List<TaskItem>.from(state.weeklyTasks);
    tasks[index] = tasks[index].copyWith(text: val);
    state = state.copyWith(weeklyTasks: tasks);
  }
  void removeWeeklyTask(int index) {
    final tasks = List<TaskItem>.from(state.weeklyTasks);
    tasks.removeAt(index);
    state = state.copyWith(weeklyTasks: tasks);
  }

  void updateBiweeklyStartDate(DateTime? val) => state = state.copyWith(biweeklyStartDate: val);
  void updateBiweeklyTime(TimeOfDay? val) => state = state.copyWith(biweeklyTime: val);
  void addBiweeklyTask() => state = state.copyWith(biweeklyTasks: [...state.biweeklyTasks, TaskItem(id: _uuid(), text: '')]);
  void updateBiweeklyTask(int index, String val) {
    final tasks = List<TaskItem>.from(state.biweeklyTasks);
    tasks[index] = tasks[index].copyWith(text: val);
    state = state.copyWith(biweeklyTasks: tasks);
  }
  void removeBiweeklyTask(int index) {
    final tasks = List<TaskItem>.from(state.biweeklyTasks);
    tasks.removeAt(index);
    state = state.copyWith(biweeklyTasks: tasks);
  }

  void updateMonthlyStartDate(DateTime? val) => state = state.copyWith(monthlyStartDate: val);
  void updateMonthlyTime(TimeOfDay? val) => state = state.copyWith(monthlyTime: val);
  void addMonthlyTask() => state = state.copyWith(monthlyTasks: [...state.monthlyTasks, TaskItem(id: _uuid(), text: '')]);
  void updateMonthlyTask(int index, String val) {
    final tasks = List<TaskItem>.from(state.monthlyTasks);
    tasks[index] = tasks[index].copyWith(text: val);
    state = state.copyWith(monthlyTasks: tasks);
  }
  void removeMonthlyTask(int index) {
    final tasks = List<TaskItem>.from(state.monthlyTasks);
    tasks.removeAt(index);
    state = state.copyWith(monthlyTasks: tasks);
  }

  void resetForm() {
    state = AddEventState();
  }

  Future<void> submitData(BuildContext context, {required bool mounted}) async {
    final s = state;
    final gameName = s.gameName.trim();
    final title = s.title.trim();

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

    if (s.cycleType == 'daily') {
      if (s.dailyTime == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('時刻を選択してください')));
        return;
      }
      endDate = DateTime(now.year, now.month, now.day, s.dailyTime!.hour, s.dailyTime!.minute);
      if (endDate.isBefore(now)) {
        endDate = endDate.add(const Duration(days: 1));
      }
      cycleSettings = {'hour': s.dailyTime!.hour, 'minute': s.dailyTime!.minute};
      tasks = s.dailyTasks.map((c) => {'name': c.text, 'isCompleted': false}).toList();
      tag = 'デイリー';
    } else if (s.cycleType == 'weekly') {
      if (s.weeklyDayOfWeek == null || s.weeklyTime == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('曜日と時刻を選択してください')));
        return;
      }
      final daysOfWeek = ['月', '火', '水', '木', '金', '土', '日'];
      final targetWeekday = daysOfWeek.indexOf(s.weeklyDayOfWeek!) + 1;
      endDate = DateTime(now.year, now.month, now.day, s.weeklyTime!.hour, s.weeklyTime!.minute);
      while (endDate.weekday != targetWeekday || endDate.isBefore(now)) {
        endDate = endDate.add(const Duration(days: 1));
      }
      cycleSettings = {'dayOfWeek': targetWeekday, 'hour': s.weeklyTime!.hour, 'minute': s.weeklyTime!.minute};
      tasks = s.weeklyTasks.map((c) => {'name': c.text, 'isCompleted': false}).toList();
      tag = 'ウィークリー';
    } else if (s.cycleType == 'biweekly') {
      if (s.biweeklyStartDate == null || s.biweeklyTime == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('起点日時を選択してください')));
        return;
      }
      endDate = DateTime(s.biweeklyStartDate!.year, s.biweeklyStartDate!.month, s.biweeklyStartDate!.day, s.biweeklyTime!.hour, s.biweeklyTime!.minute);
      while (endDate.isBefore(now)) {
        endDate = endDate.add(const Duration(days: 14));
      }
      cycleSettings = {'startDate': Timestamp.fromDate(s.biweeklyStartDate!), 'hour': s.biweeklyTime!.hour, 'minute': s.biweeklyTime!.minute};
      tasks = s.biweeklyTasks.map((c) => {'name': c.text, 'isCompleted': false}).toList();
      tag = '隔週';
    } else if (s.cycleType == 'monthly') {
      if (s.monthlyStartDate == null || s.monthlyTime == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('起点日時を選択してください')));
        return;
      }
      endDate = DateTime(now.year, now.month, s.monthlyStartDate!.day, s.monthlyTime!.hour, s.monthlyTime!.minute);
      if (endDate.isBefore(now)) {
        endDate = DateTime(now.year, now.month + 1, s.monthlyStartDate!.day, s.monthlyTime!.hour, s.monthlyTime!.minute);
      }
      cycleSettings = {'dayOfMonth': s.monthlyStartDate!.day, 'hour': s.monthlyTime!.hour, 'minute': s.monthlyTime!.minute};
      tasks = s.monthlyTasks.map((c) => {'name': c.text, 'isCompleted': false}).toList();
      tag = 'マンスリー';
    }

    final String timeStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(now);

    final data = {
      'gameName': gameName,
      'title': title,
      'tag': tag,
      'subTag': s.subTag,
      'redeemCode': s.code,
      'startDate': Timestamp.fromDate(now),
      'endDate': Timestamp.fromDate(endDate),
      'isCycleEvent': true,
      'cycleType': s.cycleType,
      'cycleSettings': cycleSettings,
      'tasks': tasks,
      'isCompleted': false,
      'isLocked': false,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'updateHistory': ['[$timeStr] 新規作成 (手動)'],
    };

    try {
      await FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('games').doc(gameName).collection('events').add(data);

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$tag イベントを追加しました')),
      );

      state = state.copyWith(title: '', code: '');
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('追加に失敗しました: $e')),
      );
    }
  }
}

final addEventProvider = NotifierProvider.autoDispose<AddEventNotifier, AddEventState>(() {
  return AddEventNotifier();
});
