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

  void updateDailyTime(TimeOfDay? val) =>
      state = state.copyWith(dailyTime: val);
  void addDailyTask() => state = state.copyWith(
    dailyTasks: [
      ...state.dailyTasks,
      TaskItem(id: _uuid(), text: ''),
    ],
  );
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

  void updateWeeklyDayOfWeek(String? val) =>
      state = state.copyWith(weeklyDayOfWeek: val);
  void updateWeeklyTime(TimeOfDay? val) =>
      state = state.copyWith(weeklyTime: val);
  void addWeeklyTask() => state = state.copyWith(
    weeklyTasks: [
      ...state.weeklyTasks,
      TaskItem(id: _uuid(), text: ''),
    ],
  );
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

  void updateBiweeklyStartDate(DateTime? val) =>
      state = state.copyWith(biweeklyStartDate: val);
  void updateBiweeklyTime(TimeOfDay? val) =>
      state = state.copyWith(biweeklyTime: val);
  void addBiweeklyTask() => state = state.copyWith(
    biweeklyTasks: [
      ...state.biweeklyTasks,
      TaskItem(id: _uuid(), text: ''),
    ],
  );
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

  void updateMonthlyStartDate(DateTime? val) =>
      state = state.copyWith(monthlyStartDate: val);
  void updateMonthlyTime(TimeOfDay? val) =>
      state = state.copyWith(monthlyTime: val);
  void addMonthlyTask() => state = state.copyWith(
    monthlyTasks: [
      ...state.monthlyTasks,
      TaskItem(id: _uuid(), text: ''),
    ],
  );
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

  bool importFromText(String text, BuildContext context) {
    try {
      final lines = text.split('\n');
      String? gameName;
      String? title;
      String? cycle;
      String? dayOfWeek;
      String? startDateStr;
      String? dayOfMonthStr;
      String? timeStr;
      List<String> tasks = [];

      bool isParsingTasks = false;

      for (var line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;

        if (isParsingTasks) {
          if (trimmed.startsWith('- ')) {
            tasks.add(trimmed.substring(2).trim());
          } else if (trimmed.startsWith('-')) {
            tasks.add(trimmed.substring(1).trim());
          }
          continue;
        }

        if (trimmed.startsWith('ゲーム名:')) {
          gameName = trimmed.substring(5).trim();
        } else if (trimmed.startsWith('タイトル:')) {
          title = trimmed.substring(5).trim();
        } else if (trimmed.startsWith('サイクル:')) {
          cycle = trimmed.substring(5).trim();
        } else if (trimmed.startsWith('曜日:')) {
          dayOfWeek = trimmed.substring(3).trim();
        } else if (trimmed.startsWith('起点日:')) {
          startDateStr = trimmed.substring(4).trim();
        } else if (trimmed.startsWith('日付:')) {
          dayOfMonthStr = trimmed.substring(3).trim();
        } else if (trimmed.startsWith('時刻:')) {
          timeStr = trimmed.substring(3).trim();
        } else if (trimmed.startsWith('タスク:')) {
          isParsingTasks = true;
        }
      }

      if (gameName == null || gameName.isEmpty) {
        throw Exception('ゲーム名が見つかりません');
      }
      if (title == null || title.isEmpty) {
        throw Exception('タイトルが見つかりません');
      }
      if (cycle == null || cycle.isEmpty) {
        throw Exception('サイクルが見つかりません');
      }
      if (timeStr == null || timeStr.isEmpty) {
        throw Exception('時刻が見つかりません');
      }

      final timeParts = timeStr.split(':');
      if (timeParts.length != 2) {
        throw Exception('時刻のフォーマットが不正です (HH:mm)');
      }
      final hour = int.tryParse(timeParts[0]);
      final minute = int.tryParse(timeParts[1]);
      if (hour == null || minute == null) {
        throw Exception('時刻のフォーマットが不正です (HH:mm)');
      }
      final timeOfDay = TimeOfDay(hour: hour, minute: minute);

      String cycleType;
      List<TaskItem> taskItems = tasks.asMap().entries.map((e) => TaskItem(id: '${_uuid()}_${e.key}', text: e.value)).toList();

      var newState = state.copyWith(
        gameName: gameName,
        title: title,
      );

      if (cycle == 'デイリー') {
        cycleType = 'daily';
        newState = newState.copyWith(
          cycleType: cycleType,
          dailyTime: timeOfDay,
          dailyTasks: taskItems,
        );
      } else if (cycle == 'ウィークリー') {
        cycleType = 'weekly';
        if (dayOfWeek == null || dayOfWeek.isEmpty) {
          throw Exception('ウィークリーの場合は曜日が必須です');
        }
        newState = newState.copyWith(
          cycleType: cycleType,
          weeklyDayOfWeek: dayOfWeek,
          weeklyTime: timeOfDay,
          weeklyTasks: taskItems,
        );
      } else if (cycle == '隔週') {
        cycleType = 'biweekly';
        if (startDateStr == null || startDateStr.isEmpty) {
          throw Exception('隔週の場合は起点日が必須です');
        }
        final startDate = DateTime.tryParse(startDateStr.replaceAll('/', '-'));
        if (startDate == null) {
          throw Exception('起点日のフォーマットが不正です (YYYY-MM-DD)');
        }
        newState = newState.copyWith(
          cycleType: cycleType,
          biweeklyStartDate: startDate,
          biweeklyTime: timeOfDay,
          biweeklyTasks: taskItems,
        );
      } else if (cycle == 'マンスリー') {
        cycleType = 'monthly';
        if (dayOfMonthStr == null || dayOfMonthStr.isEmpty) {
          throw Exception('マンスリーの場合は日付が必須です');
        }
        final dayOfMonth = int.tryParse(dayOfMonthStr);
        if (dayOfMonth == null || dayOfMonth < 1 || dayOfMonth > 31) {
          throw Exception('日付のフォーマットが不正です (1〜31)');
        }
        var monthlyStartDate = DateTime(2000, 1, dayOfMonth);

        newState = newState.copyWith(
          cycleType: cycleType,
          monthlyStartDate: monthlyStartDate,
          monthlyTime: timeOfDay,
          monthlyTasks: taskItems,
        );
      } else {
        throw Exception('不明なサイクルです: $cycle');
      }

      state = newState;
      return true;
    } catch (e) {
      if (!context.mounted) return false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('インポートエラー: ${e.toString().replaceAll('Exception: ', '')}')),
      );
      return false;
    }
  }

  Future<void> submitData(BuildContext context) async {
    final s = state;
    final gameName = s.gameName.trim();
    final title = s.title.trim();

    if (gameName.isEmpty || title.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('ゲーム名とタイトルを入力してください')));
      return;
    }

    DateTime now = DateTime.now();
    DateTime endDate = now;
    Map<String, dynamic> cycleSettings = {};
    List<Map<String, dynamic>> tasks = [];
    String tag = '';

    if (s.cycleType == 'daily') {
      if (s.dailyTime == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('時刻を選択してください')));
        return;
      }
      endDate = DateTime(
        now.year,
        now.month,
        now.day,
        s.dailyTime!.hour,
        s.dailyTime!.minute,
      );
      if (endDate.isBefore(now)) {
        endDate = endDate.add(const Duration(days: 1));
      }
      cycleSettings = {
        'hour': s.dailyTime!.hour,
        'minute': s.dailyTime!.minute,
      };
      tasks = s.dailyTasks
          .map((c) => {'name': c.text, 'isCompleted': false})
          .toList();
      tag = 'デイリー';
    } else if (s.cycleType == 'weekly') {
      if (s.weeklyDayOfWeek == null || s.weeklyTime == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('曜日と時刻を選択してください')));
        return;
      }
      final daysOfWeek = ['月', '火', '水', '木', '金', '土', '日'];
      final targetWeekday = daysOfWeek.indexOf(s.weeklyDayOfWeek!) + 1;
      endDate = DateTime(
        now.year,
        now.month,
        now.day,
        s.weeklyTime!.hour,
        s.weeklyTime!.minute,
      );
      while (endDate.weekday != targetWeekday || endDate.isBefore(now)) {
        endDate = endDate.add(const Duration(days: 1));
      }
      cycleSettings = {
        'dayOfWeek': targetWeekday,
        'hour': s.weeklyTime!.hour,
        'minute': s.weeklyTime!.minute,
      };
      tasks = s.weeklyTasks
          .map((c) => {'name': c.text, 'isCompleted': false})
          .toList();
      tag = 'ウィークリー';
    } else if (s.cycleType == 'biweekly') {
      if (s.biweeklyStartDate == null || s.biweeklyTime == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('起点日時を選択してください')));
        return;
      }
      endDate = DateTime(
        s.biweeklyStartDate!.year,
        s.biweeklyStartDate!.month,
        s.biweeklyStartDate!.day,
        s.biweeklyTime!.hour,
        s.biweeklyTime!.minute,
      );
      while (endDate.isBefore(now)) {
        endDate = endDate.add(const Duration(days: 14));
      }
      cycleSettings = {
        'startDate': Timestamp.fromDate(s.biweeklyStartDate!),
        'hour': s.biweeklyTime!.hour,
        'minute': s.biweeklyTime!.minute,
      };
      tasks = s.biweeklyTasks
          .map((c) => {'name': c.text, 'isCompleted': false})
          .toList();
      tag = '隔週';
    } else if (s.cycleType == 'monthly') {
      if (s.monthlyStartDate == null || s.monthlyTime == null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('起点日時を選択してください')));
        return;
      }
      int dayOfMonth = s.monthlyStartDate!.day;
      int year = now.year;
      int month = now.month;

      int maxDaysInCurrentMonth = DateTime(year, month + 1, 0).day;
      int currentMonthDay = dayOfMonth > maxDaysInCurrentMonth ? maxDaysInCurrentMonth : dayOfMonth;

      endDate = DateTime(
        year,
        month,
        currentMonthDay,
        s.monthlyTime!.hour,
        s.monthlyTime!.minute,
      );

      if (endDate.isBefore(now)) {
        int nextMonth = month + 1;
        int nextYear = year;
        if (nextMonth > 12) {
            nextMonth = 1;
            nextYear += 1;
        }
        int maxDaysInNextMonth = DateTime(nextYear, nextMonth + 1, 0).day;
        int nextMonthDay = dayOfMonth > maxDaysInNextMonth ? maxDaysInNextMonth : dayOfMonth;

        endDate = DateTime(
          nextYear,
          nextMonth,
          nextMonthDay,
          s.monthlyTime!.hour,
          s.monthlyTime!.minute,
        );
      }
      cycleSettings = {
        'dayOfMonth': s.monthlyStartDate!.day,
        'hour': s.monthlyTime!.hour,
        'minute': s.monthlyTime!.minute,
      };
      tasks = s.monthlyTasks
          .map((c) => {'name': c.text, 'isCompleted': false})
          .toList();
      tag = 'マンスリー';
    }

    DateTime calculatedStartDate = now;
    if (s.cycleType == 'daily') {
      calculatedStartDate = DateTime(
        endDate.year,
        endDate.month,
        endDate.day - 1,
        endDate.hour,
        endDate.minute,
      );
    } else if (s.cycleType == 'weekly') {
      calculatedStartDate = DateTime(
        endDate.year,
        endDate.month,
        endDate.day - 7,
        endDate.hour,
        endDate.minute,
      );
    } else if (s.cycleType == 'biweekly') {
      calculatedStartDate = DateTime(
        endDate.year,
        endDate.month,
        endDate.day - 14,
        endDate.hour,
        endDate.minute,
      );
    } else if (s.cycleType == 'monthly') {
      int prevMonth = endDate.month - 1;
      int prevYear = endDate.year;
      if (prevMonth < 1) {
        prevMonth = 12;
        prevYear -= 1;
      }
      int maxDaysInPrevMonth = DateTime(prevYear, prevMonth + 1, 0).day;
      int dayOfMonth = s.monthlyStartDate?.day ?? 1;
      int prevMonthDay = dayOfMonth > maxDaysInPrevMonth ? maxDaysInPrevMonth : dayOfMonth;

      calculatedStartDate = DateTime(
        prevYear,
        prevMonth,
        prevMonthDay,
        endDate.hour,
        endDate.minute,
      );
    }

    final String timeStr = DateFormat('yyyy-MM-dd HH:mm:ss').format(now);

    final data = {
      'gameName': gameName,
      'title': title,
      'tag': tag,
      'subTag': s.subTag,
      'redeemCode': s.code,
      'startDate': Timestamp.fromDate(calculatedStartDate),
      'endDate': Timestamp.fromDate(endDate),
      'isStandard': true,
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$tag イベントを追加しました')));

      state = state.copyWith(title: '', code: '');
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('追加に失敗しました: $e')));
    }
  }
}

final addEventProvider =
    NotifierProvider.autoDispose<AddEventNotifier, AddEventState>(() {
      return AddEventNotifier();
    });
