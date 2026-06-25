import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/debug_log_manager.dart';
import 'debug_log_screen.dart';
import 'url_manager_screen.dart';
import 'prompt_editor_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isClearingEvents = false;

  Future<void> _triggerSync() async {
    final traceId = const Uuid().v4();
    final logManager = DebugLogManager();

    await logManager.addLog('Starting sync request via Firestore', traceId: traceId);

    try {
      await FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'default')
          .collection('sync_requests')
          .add({
        'status': 'pending',
        'traceId': traceId,
        'createdAt': FieldValue.serverTimestamp(),
      });

      await logManager.addLog('sync request added successfully.', traceId: traceId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync request created successfully')),
        );
      }
    } catch (e) {
      await logManager.addLog('sync request failed (Exception): $e', traceId: traceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create sync request: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Game Tracker'),
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(
                color: Colors.deepPurple,
              ),
              child: Text(
                'Game Tracker Admin',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('URL Manager'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const UrlManagerScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_document),
              title: const Text('Prompt Editor'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const PromptEditorScreen()),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.bug_report),
              title: const Text('Debug Logs'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const DebugLogScreen()),
                );
              },
            ),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'default')
                  .collection('sync_requests')
                  .orderBy('createdAt', descending: true)
                  .limit(1)
                  .snapshots(),
              builder: (context, snapshot) {
                bool isLoading = false;
                if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
                  final data = snapshot.data!.docs.first.data() as Map<String, dynamic>;
                  final status = data['status'] as String?;
                  isLoading = status == 'pending' || status == 'processing';
                }

                return ListTile(
                  leading: const Icon(Icons.sync),
                  title: isLoading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Run Sync'),
                  onTap: isLoading
                      ? null
                      : () {
                          Navigator.pop(context); // Close drawer
                          _triggerSync();
                        },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete),
              title: _isClearingEvents
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Clear All Events'),
              onTap: _isClearingEvents ? null : () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Confirmation'),
                    content: const Text('本当に削除しますか？'),
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
                  setState(() {
                    _isClearingEvents = true;
                  });

                  try {
                    final callable = FirebaseFunctions.instance.httpsCallable('clearAllEvents', options: HttpsCallableOptions(timeout: const Duration(minutes: 5)));
                    await callable.call();

                    if (!context.mounted) return;
                    Navigator.pop(context); // Close drawer
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Events cleared successfully')),
                    );
                  } catch (e) {
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to clear events: $e')),
                    );
                  } finally {
                    if (mounted) {
                      setState(() {
                        _isClearingEvents = false;
                      });
                    }
                  }
                }
              },
            ),
          ],
        ),
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'default')
            .collection('settings')
            .doc('config')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data?.data() as Map<String, dynamic>?;
          final targets = (data?['targets'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];

          if (targets.isEmpty) {
            return const Center(child: Text('No targets found. Add targets in URL Manager.'));
          }

          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'default')
                .collectionGroup('events')
                .snapshots(),
            builder: (context, eventSnapshot) {
              if (eventSnapshot.hasError) {
                return Center(child: Text('Error loading events: ${eventSnapshot.error}'));
              }
              if (eventSnapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final events = eventSnapshot.data?.docs ?? [];

              if (events.isEmpty) {
                return const Center(child: Text('No events found.'));
              }

              return ListView.builder(
                itemCount: events.length,
                itemBuilder: (context, index) {
                  final eventData = events[index].data() as Map<String, dynamic>;
                  final eventGameName = eventData['gameName'] as String? ?? 'Unknown Game';
                  final title = eventData['title'] as String? ?? 'No Title';
                  final period = eventData['period'] as String? ?? 'Unknown Period';
                  final summary = eventData['summary'] as String? ?? '';
                  final imageUrl = eventData['imageUrl'] as String?;
                  final endDateStr = eventData['endDate'] as String?;
                  final eventUrl = eventData['eventUrl'] as String?;

                  int? remainingDays;
                  if (endDateStr != null) {
                    final endDate = DateTime.tryParse(endDateStr);
                    if (endDate != null) {
                      final now = DateTime.now();
                      final end = DateTime(endDate.year, endDate.month, endDate.day);
                      final today = DateTime(now.year, now.month, now.day);
                      remainingDays = end.difference(today).inDays;
                    }
                  }

                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                    child: InkWell(
                      onTap: () async {
                        String? targetUrl = eventUrl;
                        if (targetUrl == null || targetUrl.isEmpty) {
                          // Fallback to settings config url for the game
                          final targetConfig = targets.firstWhere(
                            (t) => t['gameName'] == eventGameName,
                            orElse: () => <String, dynamic>{},
                          );
                          targetUrl = targetConfig['url'] as String?;
                        }

                        if (targetUrl != null && targetUrl.isNotEmpty) {
                          final uri = Uri.parse(targetUrl);
                          if (await canLaunchUrl(uri)) {
                            await launchUrl(uri, mode: LaunchMode.externalApplication);
                          } else {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Could not launch URL')),
                              );
                            }
                          }
                        } else {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('No URL available')),
                            );
                          }
                        }
                      },
                      child: ListTile(
                        leading: imageUrl != null && imageUrl.isNotEmpty
                            ? SizedBox(
                                width: 50,
                                height: 50,
                                child: Image.network(
                                  imageUrl,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) =>
                                      const Icon(Icons.image_not_supported),
                                ),
                              )
                            : null,
                        title: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              eventGameName,
                              style: TextStyle(
                                fontSize: 10,
                                color: Theme.of(context).primaryColor,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(period, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.blueGrey)),
                            if (summary.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                summary,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ],
                        ),
                        trailing: remainingDays != null && remainingDays >= 0
                            ? Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.red.withAlpha(26),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: Colors.red),
                                ),
                                child: Text(
                                  '残り$remainingDays日',
                                  style: const TextStyle(
                                    color: Colors.red,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}
