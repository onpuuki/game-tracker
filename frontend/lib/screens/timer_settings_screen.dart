import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

class TimerSettingsScreen extends StatefulWidget {
  const TimerSettingsScreen({super.key});

  @override
  State<TimerSettingsScreen> createState() => _TimerSettingsScreenState();
}

class _TimerSettingsScreenState extends State<TimerSettingsScreen> {
  List<TimeOfDay> _selectedTimes = [];
  bool _isPaused = false;
  bool _isLoading = false;
  bool _initialized = false;

  late Stream<DocumentSnapshot> _configStream;

  @override
  void initState() {
    super.initState();
    _configStream = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: 'default',
    ).collection('settings').doc('notification_config').snapshots();
  }

  Future<void> _addTime(BuildContext context) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked != null) {
      if (_selectedTimes.any(
        (t) => t.hour == picked.hour && t.minute == picked.minute,
      )) {
        if (mounted) {
          scaffoldMessenger.showSnackBar(
            const SnackBar(content: Text('この時刻は既に追加されています')),
          );
        }
        return;
      }
      setState(() {
        _selectedTimes.add(picked);
        _selectedTimes.sort((a, b) {
          if (a.hour != b.hour) return a.hour.compareTo(b.hour);
          return a.minute.compareTo(b.minute);
        });
      });
    }
  }

  Future<void> _editTime(BuildContext context, int index) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _selectedTimes[index],
    );
    if (picked != null) {
      if (_selectedTimes.asMap().entries.any(
        (entry) =>
            entry.key != index &&
            entry.value.hour == picked.hour &&
            entry.value.minute == picked.minute,
      )) {
        if (mounted) {
          scaffoldMessenger.showSnackBar(
            const SnackBar(content: Text('この時刻は既に存在します')),
          );
        }
        return;
      }
      setState(() {
        _selectedTimes[index] = picked;
        _selectedTimes.sort((a, b) {
          if (a.hour != b.hour) return a.hour.compareTo(b.hour);
          return a.minute.compareTo(b.minute);
        });
      });
    }
  }

  Future<void> _saveSchedule() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final docRef = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('settings').doc('notification_config');

      final scanTimesStrings = _selectedTimes.map((t) {
        return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      }).toList();

      await docRef.set({
        'scan_times': scanTimesStrings,
        'is_paused': _isPaused,
        'cron_schedule': FieldValue.delete(),
      }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('設定を保存しました')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('通知時刻設定')),
      body: StreamBuilder<DocumentSnapshot>(
        stream: _configStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('エラーが発生しました: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting &&
              !_initialized) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasData && snapshot.data!.exists && !_initialized) {
            final data = snapshot.data!.data() as Map<String, dynamic>?;
            if (data != null) {
              _isPaused = data['is_paused'] as bool? ?? false;
              if (data['scan_times'] != null) {
                final scanTimes = List<String>.from(data['scan_times']);
                _selectedTimes = [];
                for (final timeStr in scanTimes) {
                  final parts = timeStr.split(':');
                  if (parts.length == 2) {
                    try {
                      final hour = int.parse(parts[0]);
                      final minute = int.parse(parts[1]);
                      _selectedTimes.add(TimeOfDay(hour: hour, minute: minute));
                    } catch (_) {}
                  }
                }
              } else if (data['cron_schedule'] != null) {
                final cronStr = data['cron_schedule'] as String;
                final parts = cronStr.split(' ');
                if (parts.length >= 2) {
                  try {
                    final minute = int.parse(parts[0]);
                    final hour = int.parse(parts[1]);
                    _selectedTimes = [TimeOfDay(hour: hour, minute: minute)];
                  } catch (_) {}
                }
              }
              _initialized = true;

              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() {});
              });
            }
          }

          return Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      title: const Text(
                        '通知を停止する',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: const Text('ONにするとスケジュールされたスキャンが実行されなくなります'),
                      value: _isPaused,
                      onChanged: (bool value) {
                        setState(() {
                          _isPaused = value;
                        });
                      },
                      contentPadding: EdgeInsets.zero,
                      activeThumbColor: Colors.redAccent,
                    ),
                    const Divider(),
                    const SizedBox(height: 8),
                    const Text(
                      '実行時刻',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: _selectedTimes.isEmpty
                          ? const Center(
                              child: Text(
                                '時刻が設定されていません。\n下のボタンから追加してください。',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _selectedTimes.length,
                              itemBuilder: (context, index) {
                                final time = _selectedTimes[index];
                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  elevation: 2,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    title: Text(
                                      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(
                                            Icons.edit,
                                            color: Colors.blue,
                                          ),
                                          onPressed: () =>
                                              _editTime(context, index),
                                          tooltip: '編集',
                                        ),
                                        IconButton(
                                          icon: const Icon(
                                            Icons.delete,
                                            color: Colors.red,
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              _selectedTimes.removeAt(index);
                                            });
                                          },
                                          tooltip: '削除',
                                        ),
                                      ],
                                    ),
                                    onTap: () => _editTime(context, index),
                                  ),
                                );
                              },
                            ),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isLoading ? null : _saveSchedule,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: _isLoading
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(
                                '設定を保存',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                bottom: 90.0,
                right: 16.0,
                child: FloatingActionButton.extended(
                  onPressed: () => _addTime(context),
                  label: const Text('時間を追加'),
                  icon: const Icon(Icons.add),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
