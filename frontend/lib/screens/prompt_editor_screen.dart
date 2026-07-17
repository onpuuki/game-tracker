import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

class PromptEditorScreen extends StatefulWidget {
  const PromptEditorScreen({super.key});

  @override
  State<PromptEditorScreen> createState() => _PromptEditorScreenState();
}

class _TargetItem {
  final TextEditingController gameNameController;
  final TextEditingController abbreviationController;
  final TextEditingController urlController;

  _TargetItem({String gameName = "", String abbreviation = "", String url = ""})
    : gameNameController = TextEditingController(text: gameName),
      abbreviationController = TextEditingController(text: abbreviation),
      urlController = TextEditingController(text: url);

  void dispose() {
    gameNameController.dispose();
    abbreviationController.dispose();
    urlController.dispose();
  }
}

class _PromptEditorScreenState extends State<PromptEditorScreen> {
  final List<_TargetItem> _targetItems = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final doc = await FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('settings').doc('config').get();

      if (doc.exists) {
        final data = doc.data();
        if (data != null) {
          if (data.containsKey('targets')) {
            final targets = data['targets'] as List<dynamic>;
            for (var target in targets) {
              if (target is Map<String, dynamic> &&
                  target.containsKey('gameName')) {
                _targetItems.add(
                  _TargetItem(
                    gameName: target['gameName'] as String,
                    abbreviation: (target['abbreviation'] as String?) ?? '',
                  ),
                );
              }
            }
          }
          if (data.containsKey('codeUrls')) {
            final codeUrls = data['codeUrls'] as List<dynamic>;
            for (var item in codeUrls) {
              if (item is Map<String, dynamic> &&
                  item.containsKey('gameName')) {
                final gameName = item['gameName'] as String;
                final url = (item['url'] as String?) ?? '';
                // 既存の targetItems に一致するゲーム名があれば URL を設定
                try {
                  final target = _targetItems.firstWhere(
                    (t) => t.gameNameController.text == gameName,
                  );
                  target.urlController.text = url;
                } catch (e) {
                  // もし codeUrls にあるが targets にない場合は新規追加する
                  _targetItems.add(_TargetItem(gameName: gameName, url: url));
                }
              }
            }
          }
        }
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load data: $e')));
    }
    if (!mounted) return;
    setState(() {
      _isLoading = false;
    });
  }

  Future<void> _saveData() async {
    try {
      final targets = _targetItems
          .where((item) => item.gameNameController.text.trim().isNotEmpty)
          .map(
            (item) => {
              'gameName': item.gameNameController.text.trim(),
              'abbreviation': item.abbreviationController.text.trim(),
            },
          )
          .toList();

      final codeUrls = _targetItems
          .where((item) => item.gameNameController.text.trim().isNotEmpty)
          .map(
            (item) => {
              'gameName': item.gameNameController.text.trim(),
              'url': item.urlController.text.trim(),
            },
          )
          .toList();

      await FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('settings').doc('config').set({
        'targets': targets,
        'codeUrls': codeUrls,
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Saved')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save data: $e')));
    }
  }

  void _addTarget() {
    setState(() {
      _targetItems.add(_TargetItem());
    });
  }

  void _removeTarget(int index) {
    setState(() {
      _targetItems[index].dispose();
      _targetItems.removeAt(index);
    });
  }

  @override
  void dispose() {
    for (var item in _targetItems) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('対象ゲーム設定'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save',
            onPressed: _saveData,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '対象ゲーム一覧',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: _addTarget,
                          tooltip: 'Add Target Game',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _targetItems.isEmpty
                        ? const Center(child: Text('No target games added.'))
                        : ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _targetItems.length,
                            itemBuilder: (context, index) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 16.0),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    const Text(
                                                      'ゲーム名',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                    TextField(
                                                      controller:
                                                          _targetItems[index]
                                                              .gameNameController,
                                                      decoration: const InputDecoration(
                                                        border:
                                                            OutlineInputBorder(),
                                                        hintText:
                                                            'Enter game name...',
                                                        isDense: true,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    const Text(
                                                      '略称',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                    TextField(
                                                      controller:
                                                          _targetItems[index]
                                                              .abbreviationController,
                                                      decoration: const InputDecoration(
                                                        border:
                                                            OutlineInputBorder(),
                                                        hintText:
                                                            'Enter abbreviation...',
                                                        isDense: true,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              const Text(
                                                'コード入力サイトURL (コードを埋め込む場所は(コード)と記載)',
                                                style: TextStyle(fontSize: 12),
                                              ),
                                              TextField(
                                                controller: _targetItems[index]
                                                    .urlController,
                                                decoration: const InputDecoration(
                                                  border: OutlineInputBorder(),
                                                  hintText:
                                                      'Enter URL format (use (コード) as placeholder)...',
                                                  isDense: true,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.remove_circle_outline,
                                      ),
                                      color: Colors.red,
                                      onPressed: () => _removeTarget(index),
                                      tooltip: 'Remove Target',
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                  ],
                ),
              ),
            ),
    );
  }
}
