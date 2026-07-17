import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:uuid/uuid.dart';
import '../utils/debug_log_manager.dart';

class ExportSettingsScreen extends StatefulWidget {
  const ExportSettingsScreen({super.key});

  @override
  State<ExportSettingsScreen> createState() => _ExportSettingsScreenState();
}

class _ExportSettingsScreenState extends State<ExportSettingsScreen> {
  final TextEditingController _folderIdController = TextEditingController();
  List<TimeOfDay> _selectedTimes = [];
  bool _isLoading = false;
  bool _initialized = false;
  bool _isExporting = false;
  String _exportStatusMessage = '';
  double? _exportProgress;

  late Stream<DocumentSnapshot> _configStream;

  @override
  void initState() {
    super.initState();
    _configStream = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: 'default',
    ).collection('settings').doc('export_config').snapshots();
  }

  @override
  void dispose() {
    _folderIdController.dispose();
    super.dispose();
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
        if (!mounted) return;
        scaffoldMessenger.showSnackBar(
          const SnackBar(content: Text('この時刻は既に追加されています')),
        );
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
        if (!mounted) return;
        scaffoldMessenger.showSnackBar(
          const SnackBar(content: Text('この時刻は既に存在します')),
        );
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

  Future<void> _saveSettings() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final docRef = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('settings').doc('export_config');

      final exportTimesStrings = _selectedTimes.map((t) {
        return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      }).toList();

      await docRef.set({
        'folder_id': _folderIdController.text,
        'export_times': exportTimesStrings,
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('設定を保存しました')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存に失敗しました: $e')));
    }
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _runManualExport() async {
    setState(() {
      _isExporting = true;
      _exportProgress = null; // ローディングアニメーション開始
      _exportStatusMessage = 'エクスポートを開始します...';
    });

    final traceId = const Uuid().v4();
    final logManager = DebugLogManager();

    try {
      await logManager.addLog(
        'Manual export started',
        traceId: traceId,
        detail: 'Target Folder ID: ${_folderIdController.text}',
      );

      setState(() {
        _exportStatusMessage = 'エクスポート処理を実行中...';
        _exportProgress = 0.5;
      });
      await logManager.addLog(
        'Calling exportToDrive Cloud Function...',
        traceId: traceId,
      );

      final result =
          await FirebaseFunctions.instanceFor(region: 'asia-northeast1')
              .httpsCallable('exportToDrive')
              .call({'folderId': _folderIdController.text});

      final data = result.data as Map<String, dynamic>;

      setState(() {
        _exportStatusMessage = 'エクスポート完了';
        _exportProgress = 1.0;
      });
      await logManager.addLog(
        'Manual export completed successfully',
        traceId: traceId,
        detail: 'Result: $data',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エクスポートが完了しました (${data['exportedCount']}件)')),
      );
    } catch (e, stack) {
      setState(() {
        _exportStatusMessage = 'エラーが発生しました';
        _exportProgress = 0.0;
      });
      await logManager.addLog(
        'Manual export failed',
        traceId: traceId,
        detail: 'Error: $e\nStack: $stack',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エラー: $e')));
    }

    if (!mounted) return;
    setState(() {
      _isExporting = false;
      _exportStatusMessage = '';
      _exportProgress = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('エクスポート設定')),
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
              _folderIdController.text = data['folder_id'] as String? ?? '';

              if (data['export_times'] != null) {
                final exportTimes = List<String>.from(data['export_times']);
                _selectedTimes = [];
                for (final timeStr in exportTimes) {
                  final parts = timeStr.split(':');
                  if (parts.length == 2) {
                    try {
                      final hour = int.parse(parts[0]);
                      final minute = int.parse(parts[1]);
                      _selectedTimes.add(TimeOfDay(hour: hour, minute: minute));
                    } catch (_) {}
                  }
                }
              }
              _initialized = true;

              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                setState(() {});
              });
            }
          } else if (!_initialized) {
            _initialized = true;
          }

          return Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Manual Export Section
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _isExporting ? null : _runManualExport,
                        style: FilledButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primaryContainer,
                          foregroundColor: Theme.of(
                            context,
                          ).colorScheme.onPrimaryContainer,
                        ),
                        child: const Text(
                          '手動エクスポート',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    if (_isExporting) ...[
                      const SizedBox(height: 16),
                      LinearProgressIndicator(value: _exportProgress),
                      const SizedBox(height: 8),
                      Text(
                        _exportStatusMessage,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ],
                    const SizedBox(height: 24),
                    const Divider(),
                    const SizedBox(height: 16),

                    // Folder ID Section
                    const Text(
                      '出力先設定 (Google Drive)',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _folderIdController,
                      decoration: const InputDecoration(
                        labelText: '共有フォルダID',
                        hintText: 'DriveのフォルダIDを入力',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Export Times Section
                    const Text(
                      '自動エクスポート時刻',
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
                        onPressed: _isLoading ? null : _saveSettings,
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
