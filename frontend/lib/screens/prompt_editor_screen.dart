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

  _TargetItem({
    String gameName = "",
    String keywords = "",
  }) : gameNameController = TextEditingController(text: gameName),
       keywordsController = TextEditingController(text: keywords);

  void dispose() {
    gameNameController.dispose();
    keywordsController.dispose();
  }
}

class _PromptEditorScreenState extends State<PromptEditorScreen> {
  final _controller = TextEditingController();
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
          if (data.containsKey('promptTemplate')) {
            _controller.text = data['promptTemplate'] as String;
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
            },
          )
          .toList();

      await FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('settings').doc('config').set({
        'promptTemplate': _controller.text,
        'targets': targets,
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
      _controller.text = '';
      await _saveData();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    for (var item in _targetItems) {
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
            tooltip: 'Copy',
            onPressed: () async {
              final scaffoldMessenger = ScaffoldMessenger.of(context);
              await Clipboard.setData(ClipboardData(text: _controller.text));
              if (mounted) {
                scaffoldMessenger.showSnackBar(
                  const SnackBar(content: Text('Copied to clipboard')),
                );
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            tooltip: 'Delete/Clear',
            onPressed: _clearPrompt,
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
                    TextField(
                      controller: _controller,
                      minLines: 10,
                      maxLines: null,
                      textAlignVertical: TextAlignVertical.top,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'Enter your prompt template here...',
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
                                          TextField(
                                            controller: _targetItems[index]
                                                .gameNameController,
                                            decoration: const InputDecoration(
                                              border: OutlineInputBorder(),
                                              hintText: 'Enter game name...',
                                              isDense: true,
                                            ),
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
                  ],
                ),
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _saveData,
        tooltip: 'Save',
        child: const Icon(Icons.save),
      ),
    );
  }
}
