import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class UrlManagerScreen extends StatefulWidget {
  const UrlManagerScreen({super.key});

  @override
  State<UrlManagerScreen> createState() => _UrlManagerScreenState();
}

class _UrlManagerScreenState extends State<UrlManagerScreen> {
  final _gameNameController = TextEditingController();
  final _urlController = TextEditingController();

  Future<void> _addTarget() async {
    final gameName = _gameNameController.text.trim();
    final url = _urlController.text.trim();

    if (gameName.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill both game name and URL')),
      );
      return;
    }

    try {
      final docRef = FirebaseFirestore.instance.collection('settings').doc('config');
      await docRef.set({
        'targets': FieldValue.arrayUnion([
          {'gameName': gameName, 'url': url}
        ])
      }, SetOptions(merge: true));

      _gameNameController.clear();
      _urlController.clear();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Target added successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error adding target: $e')),
        );
      }
    }
  }

  Future<void> _deleteTarget(Map<String, dynamic> target) async {
    try {
      final docRef = FirebaseFirestore.instance.collection('settings').doc('config');
      await docRef.update({
        'targets': FieldValue.arrayRemove([target])
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Target deleted successfully')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error deleting target: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('URL Manager'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _gameNameController,
                  decoration: const InputDecoration(labelText: 'Game Name (e.g., Genshin Impact)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _urlController,
                  decoration: const InputDecoration(labelText: 'Target URL'),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _addTarget,
                  child: const Text('Add Target'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: StreamBuilder<DocumentSnapshot>(
              stream: FirebaseFirestore.instance.collection('settings').doc('config').snapshots(),
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
                  return const Center(child: Text('No targets found.'));
                }

                return ListView.builder(
                  itemCount: targets.length,
                  itemBuilder: (context, index) {
                    final target = targets[index];
                    return ListTile(
                      title: Text(target['gameName'] ?? 'Unknown'),
                      subtitle: Text(target['url'] ?? ''),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete, color: Colors.red),
                        onPressed: () => _deleteTarget(target),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _gameNameController.dispose();
    _urlController.dispose();
    super.dispose();
  }
}
