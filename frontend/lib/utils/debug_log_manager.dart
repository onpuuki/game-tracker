import 'package:flutter/foundation.dart';

class DebugLogManager {
  static final DebugLogManager _instance = DebugLogManager._internal();

  factory DebugLogManager() {
    return _instance;
  }

  DebugLogManager._internal();

  final ValueNotifier<List<String>> logsNotifier = ValueNotifier<List<String>>([]);

  void addLog(String message, {String? traceId}) {
    final now = DateTime.now().toIso8601String();
    final traceStr = traceId != null ? ' [$traceId]' : '';
    final logEntry = '[$now]$traceStr $message';

    // Create a new list to trigger the ValueNotifier update
    final updatedLogs = List<String>.from(logsNotifier.value)..add(logEntry);
    logsNotifier.value = updatedLogs;
  }

  void clearLogs() {
    logsNotifier.value = [];
  }
}
