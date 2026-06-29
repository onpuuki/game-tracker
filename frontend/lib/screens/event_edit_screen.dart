import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

class _EventEditItem {
  final DocumentSnapshot doc;
  final Map<String, dynamic> originalData;
  bool isSelected = false;

  final TextEditingController gameNameCtrl;
  final TextEditingController titleCtrl;
  final TextEditingController summaryCtrl;
  final TextEditingController startDateCtrl;
  final TextEditingController endDateCtrl;
  final TextEditingController tagCtrl;
  final TextEditingController subTagCtrl;
  final TextEditingController redeemCodeCtrl;

  _EventEditItem({
    required this.doc,
    required this.originalData,
  })  : gameNameCtrl = TextEditingController(text: originalData['gameName']?.toString() ?? ''),
        titleCtrl = TextEditingController(text: originalData['title']?.toString() ?? ''),
        summaryCtrl = TextEditingController(text: originalData['summary']?.toString() ?? ''),
        startDateCtrl = TextEditingController(text: originalData['startDate']?.toString() ?? ''),
        endDateCtrl = TextEditingController(text: originalData['endDate']?.toString() ?? ''),
        tagCtrl = TextEditingController(text: originalData['tag']?.toString() ?? ''),
        subTagCtrl = TextEditingController(text: originalData['subTag']?.toString() ?? ''),
        redeemCodeCtrl = TextEditingController(text: originalData['redeemCode']?.toString() ?? '');

  void dispose() {
    gameNameCtrl.dispose();
    titleCtrl.dispose();
    summaryCtrl.dispose();
    startDateCtrl.dispose();
    endDateCtrl.dispose();
    tagCtrl.dispose();
    subTagCtrl.dispose();
    redeemCodeCtrl.dispose();
  }
}

class EventEditScreen extends StatefulWidget {
  const EventEditScreen({super.key});

  @override
  State<EventEditScreen> createState() => _EventEditScreenState();
}

class _EventEditScreenState extends State<EventEditScreen> {
  bool _isLoading = true;
  List<_EventEditItem> _items = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  @override
  void dispose() {
    for (var item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
    });

    for (var item in _items) {
      item.dispose();
    }

    try {
      final db = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      );
      final querySnapshot = await db.collectionGroup('events').get();

      final items = querySnapshot.docs.map((doc) {
        return _EventEditItem(
          doc: doc,
          originalData: doc.data(),
        );
      }).toList();

      setState(() {
        _items = items;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('読み込みエラー: $e')),
        );
      }
    }
  }

  Future<void> _deleteSelected() async {
    final selectedItems = _items.where((item) => item.isSelected).toList();
    if (selectedItems.isEmpty) return;

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除の確認'),
        content: Text('${selectedItems.length}件のイベントを削除しますか？'),
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

    if (confirm != true) return;

    setState(() {
      _isLoading = true;
    });

    final db = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: 'default',
    );

    try {
      // Chunk batches of 500
      for (int i = 0; i < selectedItems.length; i += 500) {
        final batch = db.batch();
        final chunk = selectedItems.skip(i).take(500);
        for (var item in chunk) {
          batch.delete(item.doc.reference);
        }
        await batch.commit();
      }

      await _loadData(); // reload list

      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('削除しました')),
      );
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('削除エラー: $e')),
      );
    }
  }

  Future<void> _saveChanges() async {
    setState(() {
      _isLoading = true;
    });

    final scaffoldMessenger = ScaffoldMessenger.of(context);
    final db = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: 'default',
    );

    try {
      List<_EventEditItem> changedItems = [];
      List<Map<String, dynamic>> updates = [];

      for (var item in _items) {
        final Map<String, dynamic> updateData = {};

        void checkAndAdd(String key, String newValue) {
          final originalValue = item.originalData[key]?.toString() ?? '';
          if (newValue != originalValue) {
            updateData[key] = newValue;
          }
        }

        checkAndAdd('gameName', item.gameNameCtrl.text);
        checkAndAdd('title', item.titleCtrl.text);
        checkAndAdd('summary', item.summaryCtrl.text);
        checkAndAdd('startDate', item.startDateCtrl.text);
        checkAndAdd('endDate', item.endDateCtrl.text);
        checkAndAdd('tag', item.tagCtrl.text);
        checkAndAdd('subTag', item.subTagCtrl.text);
        checkAndAdd('redeemCode', item.redeemCodeCtrl.text);

        if (updateData.isNotEmpty) {
          changedItems.add(item);
          updates.add(updateData);
        }
      }

      if (changedItems.isEmpty) {
        setState(() {
          _isLoading = false;
        });
        scaffoldMessenger.showSnackBar(
          const SnackBar(content: Text('変更はありません')),
        );
        return;
      }

      for (int i = 0; i < changedItems.length; i += 500) {
        final batch = db.batch();
        final chunkItems = changedItems.skip(i).take(500).toList();
        final chunkUpdates = updates.skip(i).take(500).toList();

        for (int j = 0; j < chunkItems.length; j++) {
          // It's possible that the update logic needs to handle empty values. For now, simple update.
          batch.update(chunkItems[j].doc.reference, chunkUpdates[j]);
        }
        await batch.commit();
      }

      await _loadData();

      scaffoldMessenger.showSnackBar(
        const SnackBar(content: Text('保存しました')),
      );
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text('保存エラー: $e')),
      );
    }
  }

  Widget _buildTextField(String label, TextEditingController controller, {bool multiLine = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: TextFormField(
        controller: controller,
        maxLines: multiLine ? null : 1,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('イベント編集'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: _isLoading ? null : _deleteSelected,
            tooltip: '選択したイベントを削除',
          ),
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _isLoading ? null : _saveChanges,
            tooltip: '変更を保存',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              itemCount: _items.length,
              itemBuilder: (context, index) {
                final item = _items[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Checkbox(
                          value: item.isSelected,
                          onChanged: (val) {
                            if (val != null) {
                              setState(() {
                                item.isSelected = val;
                              });
                            }
                          },
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildTextField('Game Name', item.gameNameCtrl),
                              _buildTextField('Title', item.titleCtrl),
                              _buildTextField('Summary', item.summaryCtrl, multiLine: true),
                              _buildTextField('Start Date', item.startDateCtrl),
                              _buildTextField('End Date', item.endDateCtrl),
                              _buildTextField('Tag', item.tagCtrl),
                              _buildTextField('Sub Tag', item.subTagCtrl),
                              _buildTextField('Redeem Code', item.redeemCodeCtrl),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
