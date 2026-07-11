import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:home_widget/home_widget.dart';

class WidgetSyncService {
  static Future<void> syncTop5Events() async {
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
      Set<String> checkedEvents = checkedEventsRaw
          .map((e) => e.toString())
          .toSet();

      // Fetch all events
      final QuerySnapshot eventsSnapshot = await db
          .collectionGroup('events')
          .get();

      final now = DateTime.now();

      List<Map<String, dynamic>> parsedEvents = [];

      for (var doc in eventsSnapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;

        if (data['isDeleted'] == true) {
          continue;
        }

        if (checkedEvents.contains(doc.id)) {
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
          final parsed = DateTime.tryParse(endDateData);
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

      // Sort by endDate ascending
      parsedEvents.sort(
        (a, b) =>
            (a['endDate'] as DateTime).compareTo(b['endDate'] as DateTime),
      );

      // Take top 5
      final top5Events = parsedEvents.take(5).toList();

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
      await HomeWidget.updateWidget(name: 'MediumListWidgetProvider');

      debugPrint(
        'WidgetSyncService: Synced ${widgetDataList.length} events to widget.',
      );
    } catch (e, stacktrace) {
      debugPrint('WidgetSyncService error: $e\n$stacktrace');
    }
  }
}
