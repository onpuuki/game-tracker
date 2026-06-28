import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

class DebugLogManager {
  static final DebugLogManager _instance = DebugLogManager._internal();

  factory DebugLogManager() {
    return _instance;
  }

  DebugLogManager._internal();

  FirebaseFirestore get _db =>
      FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'default');

  Future<void> addLog(String message, {String? traceId, String? detail}) async {
    try {
      final Map<String, dynamic> data = {
        'timestamp': FieldValue.serverTimestamp(),
        'message': message,
      };
      if (traceId != null) {
        data['traceId'] = traceId;
      }
      if (detail != null) {
        data['detail'] = detail;
      }
      await _db.collection('debug_logs').add(data);
    } catch (e) {
      debugPrint('Failed to add log to Firestore: $e');
    }
  }

  Future<void> clearLogs() async {
    try {
      final snapshot = await _db.collection('debug_logs').get();
      if (snapshot.docs.isEmpty) return;

      var batch = _db.batch();
      var count = 0;

      for (var doc in snapshot.docs) {
        batch.delete(doc.reference);
        count++;

        if (count >= 450) {
          await batch.commit();
          batch = _db.batch();
          count = 0;
        }
      }

      if (count > 0) {
        await batch.commit();
      }
    } catch (e) {
      debugPrint('Failed to clear logs from Firestore: $e');
    }
  }
}
