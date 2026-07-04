import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import '../utils/debug_log_manager.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  late final Stream<QuerySnapshot> _logsStream;

  @override
  void initState() {
    super.initState();
    _logsStream = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: 'default',
    )
        .collection('debug_logs')
        .orderBy('timestamp', descending: true)
        .limit(100)
        .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () async {
              try {
                final snapshot =
                    await FirebaseFirestore.instanceFor(
                          app: Firebase.app(),
                          databaseId: 'default',
                        )
                        .collection('debug_logs')
                        .orderBy('timestamp', descending: true)
                        .limit(100)
                        .get();

                final StringBuffer buffer = StringBuffer();
                for (var doc in snapshot.docs) {
                  final data = doc.data();
                  final timestamp = data['timestamp'] as Timestamp?;
                  final timeStr =
                      timestamp?.toDate().toIso8601String() ?? 'Unknown Time';
                  final traceId = data['traceId'] as String?;
                  final traceStr = traceId != null ? ' [$traceId]' : '';
                  final message = data['message'] as String? ?? 'No Message';
                  final detail = data['detail'] as String?;

                  buffer.writeln('[$timeStr]$traceStr $message');
                  if (detail != null && detail.isNotEmpty) {
                    buffer.writeln('Detail:\n$detail');
                  }
                }

                await Clipboard.setData(ClipboardData(text: buffer.toString()));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Logs copied to clipboard')),
                  );
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed to copy logs: $e')),
                  );
                }
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Confirmation'),
                  content: const Text('本当にすべてのログを削除しますか？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('キャンセル'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('はい'),
                    ),
                  ],
                ),
              );

              if (confirm == true) {
                await DebugLogManager().clearLogs();
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('Logs cleared')));
                }
              }
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: _logsStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final logs = snapshot.data?.docs ?? [];

          if (logs.isEmpty) {
            return const Center(child: Text('No logs available.'));
          }

          return ListView.builder(
            itemCount: logs.length,
            itemBuilder: (context, index) {
              final logData = logs[index].data() as Map<String, dynamic>;
              final timestamp = logData['timestamp'] as Timestamp?;
              final timeStr =
                  timestamp?.toDate().toLocal().toString() ?? 'Pending...';
              final traceId = logData['traceId'] as String?;
              final traceStr = traceId != null ? '[$traceId]' : '';
              final message = logData['message'] as String? ?? 'No Message';
              final detail = logData['detail'] as String?;

              return Card(
                margin: const EdgeInsets.symmetric(
                  horizontal: 8.0,
                  vertical: 4.0,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '[$timeStr] $traceStr',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy, size: 16),
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: () async {
                              final buffer = StringBuffer();
                              buffer.writeln('Time: $timeStr$traceStr');
                              buffer.writeln('Message: $message');
                              buffer.writeln('Detail:');
                              if (detail != null && detail.isNotEmpty) {
                                buffer.writeln(detail);
                              }

                              await Clipboard.setData(
                                ClipboardData(text: buffer.toString()),
                              );
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Copied to clipboard'),
                                  ),
                                );
                              }
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        message,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      if (detail != null && detail.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.all(8.0),
                          decoration: BoxDecoration(
                            color: Colors.grey[200],
                            borderRadius: BorderRadius.circular(4.0),
                          ),
                          child: Text(
                            detail,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
