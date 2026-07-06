import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../utils/debug_log_manager.dart';

class SyncStatusScreen extends StatefulWidget {
  const SyncStatusScreen({super.key});

  @override
  State<SyncStatusScreen> createState() => _SyncStatusScreenState();
}

class _SyncStatusScreenState extends State<SyncStatusScreen> {
  late Stream<QuerySnapshot> _syncRequestsStream;
  bool _isCycleSyncRunning = false;

  @override
  void initState() {
    super.initState();
    _syncRequestsStream =
        FirebaseFirestore.instanceFor(
              app: Firebase.app(),
              databaseId: 'default',
            )
            .collection('sync_requests')
            .orderBy('createdAt', descending: true)
            .limit(100)
            .snapshots();
  }

  Future<void> _triggerCycleReset() async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _isCycleSyncRunning = true;
    });

    try {
      final callable = FirebaseFunctions.instanceFor(
        region: 'asia-northeast1',
      ).httpsCallable('manualResetCycleEvents');
      final result = await callable.call();

      if (!mounted) return;

      messenger.showSnackBar(
        SnackBar(content: Text(result.data['message'] ?? 'サイクルスキャンが完了しました')),
      );
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('サイクルスキャンエラー: ${e.message}')),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text('予期せぬエラー: $e')));
    } finally {
      if (mounted) {
        setState(() {
          _isCycleSyncRunning = false;
        });
      }
    }
  }

  Future<void> _triggerSync() async {
    final traceId = const Uuid().v4();
    final logManager = DebugLogManager();
    final messenger = ScaffoldMessenger.of(context);

    await logManager.addLog(
      'Starting sync request via Firestore',
      traceId: traceId,
    );

    try {
      await FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('sync_requests').add({
        'status': 'pending',
        'traceId': traceId,
        'createdAt': FieldValue.serverTimestamp(),
      });

      await logManager.addLog(
        'sync request added successfully.',
        traceId: traceId,
      );

      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Sync request created successfully')),
        );
      }
    } catch (e) {
      await logManager.addLog(
        'sync request failed (Exception): $e',
        traceId: traceId,
      );
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Failed to create sync request: $e')),
        );
      }
    }
  }

  String _formatTimestamp(Timestamp? timestamp) {
    if (timestamp == null) return 'N/A';
    final date = timestamp.toDate();
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(date);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Run Sync Status')),
      body: StreamBuilder<QuerySnapshot>(
        stream: _syncRequestsStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? [];

          bool isSyncRunning = false;
          bool isStaleState = false;
          if (docs.isNotEmpty) {
            final firstDocData = docs.first.data() as Map<String, dynamic>;
            final firstStatus = firstDocData['status'] as String?;
            if (firstStatus == 'pending' ||
                firstStatus == 'processing' ||
                firstStatus == 'dispatched') {
              isSyncRunning = true;
              final updatedAt = firstDocData['updatedAt'] as Timestamp?;
              final createdAt = firstDocData['createdAt'] as Timestamp?;
              final timestamp = updatedAt ?? createdAt;

              if (timestamp != null) {
                final diff = DateTime.now().difference(timestamp.toDate());
                if (diff.inMinutes >= 15) {
                  isStaleState = true;
                }
              }
            }
          }

          return Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16.0),
                width: double.infinity,
                child: Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: (isSyncRunning && !isStaleState)
                            ? null
                            : _triggerSync,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(double.infinity, 40),
                        ),
                        child: const Text('AIスキャン'),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: FilledButton(
                        onPressed: _isCycleSyncRunning
                            ? null
                            : _triggerCycleReset,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(double.infinity, 40),
                        ),
                        child: _isCycleSyncRunning
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('サイクルスキャン'),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    final status = data['status'] as String? ?? 'unknown';
                    final createdAt = data['createdAt'] as Timestamp?;
                    final updatedAt = data['updatedAt'] as Timestamp?;
                    final debugInfo = data['debugInfo'] as List<dynamic>?;
                    final totalTokens = data['totalTokens'] as int?;

                    bool currentItemStale = false;
                    if (index == 0) {
                      currentItemStale = isStaleState;
                    } else if (status == 'processing' ||
                        status == 'dispatched') {
                      final timeToUse = updatedAt ?? createdAt;
                      if (timeToUse != null) {
                        currentItemStale =
                            DateTime.now()
                                .difference(timeToUse.toDate())
                                .inMinutes >=
                            15;
                      }
                    }

                    IconData statusIcon;
                    Color statusColor;

                    switch (status) {
                      case 'completed':
                        statusIcon = Icons.check_circle;
                        statusColor = Colors.green;
                        break;
                      case 'error':
                        statusIcon = Icons.error;
                        statusColor = Colors.red;
                        break;
                      case 'processing':
                      case 'dispatched':
                        if (currentItemStale) {
                          statusIcon = Icons.error;
                          statusColor = Colors.red;
                        } else {
                          statusIcon = Icons.autorenew;
                          statusColor = Colors.orange;
                        }
                        break;
                      case 'pending':
                      default:
                        statusIcon = Icons.hourglass_empty;
                        statusColor = Colors.grey;
                    }

                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 8.0,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(statusIcon, color: statusColor),
                                const SizedBox(width: 8),
                                Text(
                                  status.toUpperCase(),
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: statusColor,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  'Start: ${_formatTimestamp(createdAt)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy, size: 16),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () async {
                                    final buffer = StringBuffer();
                                    buffer.writeln('Status: $status');
                                    buffer.writeln(
                                      'Start: ${_formatTimestamp(createdAt)}',
                                    );
                                    buffer.writeln(
                                      'End: ${_formatTimestamp(updatedAt)}',
                                    );
                                    buffer.writeln('Token: $totalTokens');
                                    if (data['error'] != null) {
                                      buffer.writeln('Error: ${data['error']}');
                                    }
                                    buffer.writeln('Details:');
                                    if (debugInfo != null) {
                                      buffer.writeln(
                                        const JsonEncoder.withIndent(
                                          '  ',
                                        ).convert(debugInfo),
                                      );
                                    }

                                    await Clipboard.setData(
                                      ClipboardData(text: buffer.toString()),
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Copied to clipboard'),
                                        ),
                                      );
                                    }
                                  },
                                ),
                              ],
                            ),
                            if (status == 'completed' || status == 'error') ...[
                              const SizedBox(height: 4),
                              Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  'End: ${_formatTimestamp(updatedAt)}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                            if (totalTokens != null) ...[
                              const SizedBox(height: 4),
                              Align(
                                alignment: Alignment.centerRight,
                                child: Text(
                                  'Token: $totalTokens',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey,
                                  ),
                                ),
                              ),
                            ],
                            if (status == 'error' && data['error'] != null) ...[
                              const SizedBox(height: 8),
                              Text(
                                'Error: ${data['error']}',
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                            if (status == 'processing' ||
                                status == 'dispatched') ...[
                              const SizedBox(height: 12),
                              if (currentItemStale) ...[
                                Row(
                                  children: const [
                                    Icon(
                                      Icons.error_outline,
                                      color: Colors.red,
                                      size: 16,
                                    ),
                                    SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        'バックエンド処理がタイムアウトしました。再実行してください',
                                        style: TextStyle(
                                          color: Colors.red,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ] else ...[
                                const LinearProgressIndicator(),
                              ],
                            ],
                            if (debugInfo != null && debugInfo.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              const Text(
                                'Details:',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              ListView.builder(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                itemCount: debugInfo.length,
                                itemBuilder: (context, idx) {
                                  final info =
                                      debugInfo[idx] as Map<String, dynamic>;
                                  final game =
                                      info['game'] as String? ?? 'Unknown Game';
                                  final stage = info['stage'];
                                  final isError = stage == 'Error';

                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 2.0),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Icon(
                                          isError ? Icons.close : Icons.check,
                                          size: 14,
                                          color: isError
                                              ? Colors.red
                                              : Colors.green,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: isError
                                              ? Text(
                                                  'Error parsing $game: ${info['error']}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                    color: Colors.red,
                                                  ),
                                                )
                                              : RichText(
                                                  text: TextSpan(
                                                    children: [
                                                      TextSpan(
                                                        text: 'Processed $game',
                                                        style: const TextStyle(
                                                          fontSize: 12,
                                                          color: Colors.black87,
                                                        ),
                                                      ),
                                                      if (info.containsKey(
                                                            'added',
                                                          ) &&
                                                          info.containsKey(
                                                            'updated',
                                                          ) &&
                                                          info.containsKey(
                                                            'deleted',
                                                          ))
                                                        TextSpan(
                                                          text:
                                                              ' [新規: ${info['added']}, 更新: ${info['updated']}, 削除: ${info['deleted']}]',
                                                          style:
                                                              const TextStyle(
                                                                fontSize: 11,
                                                                color:
                                                                    Colors.grey,
                                                              ),
                                                        ),
                                                    ],
                                                  ),
                                                ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
