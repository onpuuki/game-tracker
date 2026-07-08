import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';

class PromptEditorScreen extends StatefulWidget {
  const PromptEditorScreen({super.key});

  @override
  State<PromptEditorScreen> createState() => _PromptEditorScreenState();
}

class _TargetItem {
  final TextEditingController gameNameController;
  final TextEditingController keywordsController;
  final TextEditingController abbreviationController;

  _TargetItem({
    String gameName = "",
    String keywords = "",
    String abbreviation = "",
  }) : gameNameController = TextEditingController(text: gameName),
       keywordsController = TextEditingController(text: keywords),
       abbreviationController = TextEditingController(text: abbreviation);

  void dispose() {
    gameNameController.dispose();
    keywordsController.dispose();
    abbreviationController.dispose();
  }
}

class _CodeUrlItem {
  final TextEditingController gameNameController;
  final TextEditingController urlController;

  _CodeUrlItem({String gameName = "", String url = ""})
    : gameNameController = TextEditingController(text: gameName),
      urlController = TextEditingController(text: url);

  void dispose() {
    gameNameController.dispose();
    urlController.dispose();
  }
}

class _PromptEditorScreenState extends State<PromptEditorScreen> {
  final _scraperController = TextEditingController();
  final _auditorController = TextEditingController();
  final List<_TargetItem> _targetItems = [];
  final List<_CodeUrlItem> _codeUrlItems = [];
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
          if (data.containsKey('scraperPrompt')) {
            _scraperController.text = data['scraperPrompt'] as String;
          }
          if (data.containsKey('auditorPrompt')) {
            _auditorController.text = data['auditorPrompt'] as String;
          }
          if (data.containsKey('targets')) {
            final targets = data['targets'] as List<dynamic>;
            for (var target in targets) {
              if (target is Map<String, dynamic> &&
                  target.containsKey('gameName')) {
                _targetItems.add(
                  _TargetItem(
                    gameName: target['gameName'] as String,
                    keywords: (target['keywords'] as String?) ?? '',
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
                _codeUrlItems.add(
                  _CodeUrlItem(
                    gameName: item['gameName'] as String,
                    url: (item['url'] as String?) ?? '',
                  ),
                );
              }
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load data: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _saveData() async {
    try {
      final targets = _targetItems
          .where((item) => item.gameNameController.text.trim().isNotEmpty)
          .map(
            (item) => {
              'gameName': item.gameNameController.text.trim(),
              'keywords': item.keywordsController.text.trim(),
              'abbreviation': item.abbreviationController.text.trim(),
            },
          )
          .toList();

      final codeUrls = _codeUrlItems
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
        'scraperPrompt': _scraperController.text,
        'auditorPrompt': _auditorController.text,
        'targets': targets,
        'codeUrls': codeUrls,
      }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Saved')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to save data: $e')));
      }
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

  void _addCodeUrl() {
    setState(() {
      _codeUrlItems.add(_CodeUrlItem());
    });
  }

  void _removeCodeUrl(int index) {
    setState(() {
      _codeUrlItems[index].dispose();
      _codeUrlItems.removeAt(index);
    });
  }

  Future<void> _clearPrompt() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirmation'),
        content: const Text(
          'Are you sure you want to delete the prompt completely?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      _scraperController.text = '';
      _auditorController.text = '';
      await _saveData();
    }
  }

  @override
  void dispose() {
    _scraperController.dispose();
    _auditorController.dispose();
    for (var item in _targetItems) {
      item.dispose();
    }
    for (var item in _codeUrlItems) {
      item.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prompt Editor'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy Prompts',
            onPressed: () async {
              final scaffoldMessenger = ScaffoldMessenger.of(context);
              final combinedText =
                  '--- スクレイパー用プロンプト ---\n${_scraperController.text}\n\n--- オーディター用プロンプト ---\n${_auditorController.text}';
              await Clipboard.setData(ClipboardData(text: combinedText));
              if (mounted) {
                scaffoldMessenger.showSnackBar(
                  const SnackBar(
                    content: Text('Copied both prompts to clipboard'),
                  ),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete/Clear',
            onPressed: _clearPrompt,
          ),
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
                    const Text(
                      'スクレイパー用プロンプト',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _scraperController,
                      minLines: 3,
                      maxLines: 5,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Enter scraper prompt here...',
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'オーディター用プロンプト',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _auditorController,
                      minLines: 3,
                      maxLines: 5,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Enter auditor prompt here...',
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Target Games',
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
                                padding: const EdgeInsets.only(bottom: 8.0),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: TextField(
                                                  controller:
                                                      _targetItems[index]
                                                          .gameNameController,
                                                  decoration:
                                                      const InputDecoration(
                                                        border:
                                                            OutlineInputBorder(),
                                                        hintText:
                                                            'Enter game name...',
                                                        isDense: true,
                                                      ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: TextField(
                                                  controller: _targetItems[index]
                                                      .abbreviationController,
                                                  decoration: const InputDecoration(
                                                    border:
                                                        OutlineInputBorder(),
                                                    hintText:
                                                        'Enter abbreviation...',
                                                    isDense: true,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 8),
                                          TextField(
                                            controller: _targetItems[index]
                                                .keywordsController,
                                            decoration: const InputDecoration(
                                              border: OutlineInputBorder(),
                                              hintText:
                                                  'Enter keywords (comma separated)...',
                                              isDense: true,
                                            ),
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
                    const SizedBox(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Code Redemption Pages',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add),
                          onPressed: _addCodeUrl,
                          tooltip: 'Add Code URL',
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _codeUrlItems.isEmpty
                        ? const Center(child: Text('No code URLs added.'))
                        : ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _codeUrlItems.length,
                            itemBuilder: (context, index) {
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 8.0),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        children: [
                                          TextField(
                                            controller: _codeUrlItems[index]
                                                .gameNameController,
                                            decoration: const InputDecoration(
                                              border: OutlineInputBorder(),
                                              hintText: 'Enter game name...',
                                              isDense: true,
                                            ),
                                          ),
                                          const SizedBox(height: 8),
                                          TextField(
                                            controller: _codeUrlItems[index]
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
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.remove_circle_outline,
                                      ),
                                      color: Colors.red,
                                      onPressed: () => _removeCodeUrl(index),
                                      tooltip: 'Remove Code URL',
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
