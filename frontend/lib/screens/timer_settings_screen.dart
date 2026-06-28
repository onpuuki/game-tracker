import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

class TimerSettingsScreen extends StatefulWidget {
  const TimerSettingsScreen({super.key});

  @override
  State<TimerSettingsScreen> createState() => _TimerSettingsScreenState();
}

class _TimerSettingsScreenState extends State<TimerSettingsScreen> {
  TimeOfDay? _selectedTime;
  bool _isLoading = false;

  late Stream<DocumentSnapshot> _configStream;

  @override
  void initState() {
    super.initState();
    _configStream = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: 'default',
    ).collection('settings').doc('sync_config').snapshots();
  }

  Future<void> _selectTime(BuildContext context) async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime ?? TimeOfDay.now(),
    );
    if (picked != null && picked != _selectedTime) {
      setState(() {
        _selectedTime = picked;
      });
    }
  }

  Future<void> _saveSchedule() async {
    if (_selectedTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('時刻を選択してください')),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final hour = _selectedTime!.hour;
      final minute = _selectedTime!.minute;
      // Convert to cron expression (e.g. "minute hour * * *")
      // Since Cloud Scheduler runs in asia-northeast1 context (set in index.ts),
      // we store the cron schedule. The timezone for Scheduler is defined during job creation.
      final cronSchedule = '$minute $hour * * *';

      final docRef = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('settings').doc('sync_config');

      await docRef.set({
        'cron_schedule': cronSchedule,
      }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('スケジュールを保存しました')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存に失敗しました: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  TimeOfDay? _parseCron(String? cronStr) {
    if (cronStr == null || cronStr.isEmpty) return null;
    try {
      final parts = cronStr.split(' ');
      if (parts.length >= 2) {
        final minute = int.parse(parts[0]);
        final hour = int.parse(parts[1]);
        return TimeOfDay(hour: hour, minute: minute);
      }
    } catch (e) {
      // Ignore parsing errors
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('自動スキャン時刻'),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _configStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('エラーが発生しました: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          String? currentCron;
          if (snapshot.hasData && snapshot.data!.exists) {
            final data = snapshot.data!.data() as Map<String, dynamic>?;
            currentCron = data?['cron_schedule'] as String?;
          }

          final currentTime = _selectedTime ?? _parseCron(currentCron);

          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '毎日以下の時刻にバックグラウンドで自動スキャンを実行します。',
                  style: TextStyle(fontSize: 16),
                ),
                const SizedBox(height: 24),
                ListTile(
                  title: const Text('実行時刻', style: TextStyle(fontWeight: FontWeight.bold)),
                  trailing: Text(
                    currentTime != null
                        ? '${currentTime.hour.toString().padLeft(2, '0')}:${currentTime.minute.toString().padLeft(2, '0')}'
                        : '未設定',
                    style: const TextStyle(fontSize: 20),
                  ),
                  onTap: () => _selectTime(context),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _saveSchedule,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('設定を保存'),
                  ),
                ),
                const SizedBox(height: 16),
                if (currentCron != null)
                  Center(
                    child: Text(
                      '現在の設定 (Cron): $currentCron',
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  )
              ],
            ),
          );
        },
      ),
    );
  }
}
