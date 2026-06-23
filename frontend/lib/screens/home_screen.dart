import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:uuid/uuid.dart';
import '../utils/debug_log_manager.dart';
import 'debug_log_screen.dart';
import 'url_manager_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isLoading = false;

  Future<void> _triggerSync() async {
    setState(() {
      _isLoading = true;
    });

    final traceId = const Uuid().v4();
    final logManager = DebugLogManager();

    logManager.addLog('Starting syncEvents call', traceId: traceId);

    try {
      final callable = FirebaseFunctions.instance.httpsCallable('syncEvents', options: HttpsCallableOptions(timeout: const Duration(seconds: 300)));
      final result = await callable.call({'traceId': traceId});

      logManager.addLog('syncEvents call successful. Result: ${result.data}', traceId: traceId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sync triggered successfully')),
        );
      }
    } on FirebaseFunctionsException catch (e) {
      logManager.addLog('syncEvents call failed (FirebaseFunctionsException): [${e.code}] ${e.message}', traceId: traceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: ${e.message}')),
        );
      }
    } catch (e) {
      logManager.addLog('syncEvents call failed (Exception): $e', traceId: traceId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sync failed: $e')),
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
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              children: [
                const Text(
                  'Trigger Manual Scraping',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),
                ElevatedButton(
                  onPressed: _isLoading ? null : _triggerSync,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  ),
                  child: _isLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2)
                      )
                    : const Text('Run syncEvents', style: TextStyle(fontSize: 16)),
                ),
                const SizedBox(height: 10),
                if (_isLoading) const Text('Sync is running. Check Debug Logs for details.', style: TextStyle(fontSize: 12)),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: StreamBuilder<DocumentSnapshot>(
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

                return DefaultTabController(
                  length: targets.length,
                  child: Column(
                    children: [
                      TabBar(
                        isScrollable: true,
                        labelColor: Theme.of(context).primaryColor,
                        unselectedLabelColor: Colors.grey,
                        tabs: targets.map((target) {
                          return Tab(text: target['gameName'] ?? 'Unknown');
                        }).toList(),
                      ),
                      Expanded(
                        child: TabBarView(
                          children: targets.map((target) {
                            final gameName = target['gameName'] as String?;
                            if (gameName == null) {
                              return const Center(child: Text('Invalid target configuration'));
                            }
                            return _buildEventList(gameName);
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventList(String gameName) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'default')
          .collection('games')
          .doc(gameName)
          .collection('events')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('Error loading events: ${snapshot.error}'));
        }
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final events = snapshot.data?.docs ?? [];

        if (events.isEmpty) {
          return const Center(child: Text('No events found for this game.'));
        }

        return ListView.builder(
          itemCount: events.length,
          itemBuilder: (context, index) {
            final eventData = events[index].data() as Map<String, dynamic>;
            final title = eventData['title'] as String? ?? 'No Title';
            final period = eventData['period'] as String? ?? 'Unknown Period';

            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: ListTile(
                title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(period),
              ),
            );
          },
        );
      },
    );
  }
}
