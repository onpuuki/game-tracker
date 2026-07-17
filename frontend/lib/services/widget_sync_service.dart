import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:home_widget/home_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

class WidgetSyncService {
  static Timer? _debounceTimer;
  static final List<Completer<void>> _completers = [];

  static Future<void> syncTop5Events({
    List<String> excludedIds = const [],
    bool throwError = false,
  }) async {
    final completer = Completer<void>();
    _completers.add(completer);

    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(seconds: 2), () async {
      try {
        await _executeSync(excludedIds: excludedIds);
        for (var c in _completers) {
          if (!c.isCompleted) c.complete();
        }
      } catch (e) {
        for (var c in _completers) {
          if (!c.isCompleted) {
            if (throwError) {
              c.completeError(e);
            } else {
              c.complete();
            }
          }
        }
      } finally {
        _completers.clear();
      }
    });

    return completer.future;
  }

  static Future<void> _executeSync({
    List<String> excludedIds = const [],
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        debugPrint('User not logged in, cannot sync widget.');
        return;
      }

      final db = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      );

      // Fetch user's checked events
      final userDoc = await db.collection('users').doc(user.uid).get();
      List<dynamic> checkedEventsRaw = userDoc.data()?['checkedEvents'] ?? [];
      List<dynamic> customGamesRaw = userDoc.data()?['customGames'] ?? [];
      List<String> customGames = customGamesRaw
          .map((e) => e.toString())
          .toList();
      Set<String> checkedEvents = checkedEventsRaw
          .map((e) => e.toString())
          .toSet();

      final ignoreIds = checkedEvents.union(excludedIds.toSet());

      // Fetch selected games from SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final List<String> selectedGames =
          prefs.getStringList('selectedGames') ?? [];

      // Fetch all events
      final QuerySnapshot eventsSnapshot = await db
          .collectionGroup('events')
          .where(
            'endDate',
            isGreaterThanOrEqualTo: Timestamp.fromDate(
              DateTime.now().subtract(const Duration(days: 1)),
            ),
          )
          .orderBy('endDate', descending: false)
          .limit(50)
          .get();

      final now = DateTime.now();

      List<Map<String, dynamic>> parsedEvents = [];

      for (var doc in eventsSnapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;

        if (ignoreIds.contains(doc.id)) {
          continue;
        }

        if (selectedGames.isNotEmpty &&
            !selectedGames.contains(data['gameName'])) {
          continue;
        }

        if (data['isCustomGame'] == true &&
            !customGames.contains(data['gameName'])) {
          continue;
        }

        if (data['isCompleted'] == true) {
          continue;
        }

        if (data['isDeleted'] == true) {
          continue;
        }

        final endDateData = data['endDate'];
        if (endDateData == null) {
          continue;
        }

        DateTime endDate;
        if (endDateData is Timestamp) {
          endDate = endDateData.toDate();
        } else if (endDateData is String) {
          final parsed = DateTime.tryParse(endDateData.replaceAll('/', '-'));
          if (parsed != null) {
            endDate = parsed;
          } else {
            continue;
          }
        } else {
          continue;
        }

        if (endDate.isBefore(now)) {
          continue;
        }

        final String title = data['title'] as String? ?? '無題';
        final displayTitle =
            title; // To avoid long text, game name is removed in 3x3 widget

        parsedEvents.add({
          'id': doc.id,
          'title': displayTitle,
          'endDate': endDate,
        });
      }

      // Take top 20
      final top5Events = parsedEvents.take(20).toList();

      List<Map<String, String>> widgetDataList = [];
      for (var event in top5Events) {
        final endDate = event['endDate'] as DateTime;
        final diff = endDate.difference(now);
        final inDays = diff.inDays;
        final inHours = diff.inHours % 24;

        String deadlineStr;
        if (inDays > 0) {
          deadlineStr = 'あと$inDays日$inHours時間';
        } else {
          deadlineStr = 'あと$inHours時間';
        }

        widgetDataList.add({
          'title': event['title'] as String,
          'deadline': deadlineStr,
        });
      }

      final jsonString = jsonEncode(widgetDataList);

      await HomeWidget.saveWidgetData<String>('widget_top5_events', jsonString);
      await HomeWidget.updateWidget(
        name: 'CompactWidgetProvider',
        qualifiedAndroidName: 'com.example.frontend.CompactWidgetProvider',
      );
      await HomeWidget.updateWidget(
        name: 'VerticalWidgetProvider',
        qualifiedAndroidName: 'com.example.frontend.VerticalWidgetProvider',
      );

      debugPrint(
        'WidgetSyncService: Synced ${widgetDataList.length} events to widget.',
      );

      await FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('debug_logs').add({
        'message':
            'WidgetSync Success. target: ${widgetDataList.length} events, excludedIds: $excludedIds',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } catch (e, stacktrace) {
      debugPrint('WidgetSync Error: $e');
      debugPrint('WidgetSyncService error: $e\n$stacktrace');

      try {
        await FirebaseFirestore.instanceFor(
          app: Firebase.app(),
          databaseId: 'default',
        ).collection('debug_logs').add({
          'message': 'WidgetSync Error: $e',
          'createdAt': FieldValue.serverTimestamp(),
        });
      } catch (logError) {
        debugPrint('Failed to write error log to Firestore: $logError');
      }
      rethrow;
    }
  }
}
