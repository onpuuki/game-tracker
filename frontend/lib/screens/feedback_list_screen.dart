import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:intl/intl.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../utils/debug_log_manager.dart';

class FeedbackListScreen extends StatefulWidget {
  const FeedbackListScreen({super.key});

  @override
  State<FeedbackListScreen> createState() => _FeedbackListScreenState();
}

class _FeedbackListScreenState extends State<FeedbackListScreen> {
  final Set<String> _selectedFeedbackIds = {};
  String _sortCriteria = 'date_desc'; // 'date_desc', 'date_asc', 'tag'
  String _filterKeyword = '';
  String? _filterTag;
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;

  void _toggleSelection(String docId) {
    setState(() {
      if (_selectedFeedbackIds.contains(docId)) {
        _selectedFeedbackIds.remove(docId);
      } else {
        _selectedFeedbackIds.add(docId);
      }
    });
  }

  Future<void> _showSortDialog() async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) {
        return SimpleDialog(
          title: const Text('並び替え'),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'date_desc'),
              child: const Text('日時順（降順）'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'date_asc'),
              child: const Text('日時順（昇順）'),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, 'tag'),
              child: const Text('タグ順'),
            ),
          ],
        );
      },
    );

    if (result != null) {
      setState(() {
        _sortCriteria = result;
      });
    }
  }

  Future<void> _showFilterDialog() async {
    String keyword = _filterKeyword;
    String? tag = _filterTag;
    DateTime? startDate = _filterStartDate;
    DateTime? endDate = _filterEndDate;

    await showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('絞り込み'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      decoration: const InputDecoration(labelText: 'キーワード'),
                      controller: TextEditingController(text: keyword),
                      onChanged: (val) => keyword = val,
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String?>(
                      decoration: const InputDecoration(labelText: 'タグ'),
                      initialValue: tag,
                      items: [
                        const DropdownMenuItem(value: null, child: Text('すべて')),
                        const DropdownMenuItem(
                          value: '不具合',
                          child: Text('不具合'),
                        ),
                        const DropdownMenuItem(value: '要望', child: Text('要望')),
                        const DropdownMenuItem(
                          value: 'その他',
                          child: Text('その他'),
                        ),
                      ],
                      onChanged: (val) {
                        setDialogState(() {
                          tag = val;
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextButton(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: startDate ?? DateTime.now(),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2030),
                              );
                              if (picked != null) {
                                setDialogState(() {
                                  startDate = picked;
                                });
                              }
                            },
                            child: Text(
                              startDate != null
                                  ? DateFormat('yyyy-MM-dd').format(startDate!)
                                  : '開始日を選択',
                            ),
                          ),
                        ),
                        Expanded(
                          child: TextButton(
                            onPressed: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: endDate ?? DateTime.now(),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2030),
                              );
                              if (picked != null) {
                                setDialogState(() {
                                  endDate = DateTime(
                                    picked.year,
                                    picked.month,
                                    picked.day,
                                    23,
                                    59,
                                    59,
                                  );
                                });
                              }
                            },
                            child: Text(
                              endDate != null
                                  ? DateFormat('yyyy-MM-dd').format(endDate!)
                                  : '終了日を選択',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() {
                      _filterKeyword = '';
                      _filterTag = null;
                      _filterStartDate = null;
                      _filterEndDate = null;
                    });
                    Navigator.pop(context);
                  },
                  child: const Text('クリア'),
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _filterKeyword = keyword;
                      _filterTag = tag;
                      _filterStartDate = startDate;
                      _filterEndDate = endDate;
                    });
                    Navigator.pop(context);
                  },
                  child: const Text('適用'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _deleteFeedbacks(List<String> targetIds) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除の確認'),
        content: Text('${targetIds.length}件のフィードバックを削除しますか？\nこの操作は取り消せません。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    if (!mounted) return;

    try {
      var batch = FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).batch();
      int count = 0;

      for (final id in targetIds) {
        batch.delete(
          FirebaseFirestore.instanceFor(
            app: Firebase.app(),
            databaseId: 'default',
          ).collection('feedbacks').doc(id),
        );
        count++;
        // WriteBatch limit is 500
        if (count >= 450) {
          await batch.commit();
          batch = FirebaseFirestore.instanceFor(
            app: Firebase.app(),
            databaseId: 'default',
          ).batch(); // Re-initialize the batch for next items
          count = 0;
        }
      }

      if (count > 0) {
        await batch.commit();
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${targetIds.length}件のフィードバックを削除しました')),
      );

      setState(() {
        _selectedFeedbackIds.clear();
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('削除中にエラーが発生しました: $e')));
    }
  }

  Future<void> _exportFeedbacks(List<String> targetIds) async {
    try {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('エクスポートを開始しました...')));

      final result =
          await FirebaseFunctions.instanceFor(region: 'asia-northeast1')
              .httpsCallable('exportFeedbacksToDrive')
              .call({'targetIds': targetIds.isNotEmpty ? targetIds : null});

      if (!mounted) return;

      if (result.data['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('エクスポートが完了しました。(${result.data['exportedCount']}件)'),
          ),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('エクスポートに失敗しました。')));
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      final errorMsg =
          'Functionsエラー: [${e.code}] ${e.message}\n詳細: ${e.details}';
      DebugLogManager().addLog(errorMsg);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMsg)));
    } catch (e) {
      if (!mounted) return;
      DebugLogManager().addLog('エクスポート中にエラーが発生しました: $e');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('エクスポート中にエラーが発生しました: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot>(
      stream:
          FirebaseFirestore.instanceFor(
                app: Firebase.app(),
                databaseId: 'default',
              )
              .collection('feedbacks')
              .orderBy('createdAt', descending: true)
              .limit(200)
              .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            appBar: AppBar(title: const Text('エラー')),
            body: Center(child: Text('エラーが発生しました: ${snapshot.error}')),
          );
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return Scaffold(
            appBar: AppBar(title: const Text('読み込み中')),
            body: const Center(child: CircularProgressIndicator()),
          );
        }

        List<QueryDocumentSnapshot> docs = snapshot.data?.docs ?? [];

        // Client-side filtering
        docs = docs.where((doc) {
          final data = doc.data() as Map<String, dynamic>;
          final title = data['title']?.toString() ?? '';
          final body = data['body']?.toString() ?? '';
          final tag = data['tag']?.toString();

          DateTime? createdAt;
          final createdAtData = data['createdAt'];
          if (createdAtData is Timestamp) {
            createdAt = createdAtData.toDate();
          } else if (createdAtData is String) {
            createdAt = DateTime.tryParse(createdAtData.toString().replaceAll('/', '-'));
          }

          // Keyword filter
          if (_filterKeyword.isNotEmpty) {
            if (!title.contains(_filterKeyword) &&
                !body.contains(_filterKeyword)) {
              return false;
            }
          }

          // Tag filter
          if (_filterTag != null && tag != _filterTag) {
            return false;
          }

          // Date filter
          if (createdAt != null) {
            if (_filterStartDate != null &&
                createdAt.isBefore(_filterStartDate!)) {
              return false;
            }
            if (_filterEndDate != null && createdAt.isAfter(_filterEndDate!)) {
              return false;
            }
          } else if (_filterStartDate != null || _filterEndDate != null) {
            // If there's a date filter and no createdAt, we probably filter it out
            return false;
          }

          return true;
        }).toList();

        // Client-side sorting
        docs.sort((a, b) {
          final dataA = a.data() as Map<String, dynamic>;
          final dataB = b.data() as Map<String, dynamic>;

          if (_sortCriteria == 'tag') {
            final tagA = dataA['tag']?.toString() ?? '';
            final tagB = dataB['tag']?.toString() ?? '';
            return tagA.compareTo(tagB);
          } else {
            DateTime? dateA;
            if (dataA['createdAt'] is Timestamp) {
              dateA = (dataA['createdAt'] as Timestamp).toDate();
            }
            DateTime? dateB;
            if (dataB['createdAt'] is Timestamp) {
              dateB = (dataB['createdAt'] as Timestamp).toDate();
            }

            if (dateA == null && dateB == null) return 0;
            if (dateA == null) return 1;
            if (dateB == null) return -1;

            return _sortCriteria == 'date_asc'
                ? dateA.compareTo(dateB)
                : dateB.compareTo(dateA);
          }
        });

        final hasSelection = _selectedFeedbackIds.isNotEmpty;
        final List<String> currentFilteredIds = docs.map((d) => d.id).toList();

        return Scaffold(
          appBar: AppBar(
            title: Text(
              hasSelection ? '${_selectedFeedbackIds.length}件選択中' : 'フィードバック一覧',
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.sort),
                onPressed: _showSortDialog,
              ),
              IconButton(
                icon: const Icon(Icons.filter_list),
                onPressed: _showFilterDialog,
              ),
              IconButton(
                icon: const Icon(Icons.delete),
                onPressed: docs.isEmpty
                    ? null
                    : () {
                        final targets = hasSelection
                            ? _selectedFeedbackIds.toList()
                            : currentFilteredIds;
                        _deleteFeedbacks(targets);
                      },
              ),
              IconButton(
                icon: const Icon(Icons.file_download),
                onPressed: docs.isEmpty
                    ? null
                    : () {
                        final targets = hasSelection
                            ? _selectedFeedbackIds.toList()
                            : currentFilteredIds;
                        _exportFeedbacks(targets);
                      },
              ),
            ],
          ),
          body: docs.isEmpty
              ? const Center(child: Text('フィードバックはありません。'))
              : ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;

                    final title = data['title']?.toString() ?? 'タイトルなし';
                    final tag = data['tag']?.toString() ?? 'タグなし';
                    final body = data['body']?.toString() ?? '本文なし';

                    // Handle Timestamp properly
                    final createdAtData = data['createdAt'];
                    DateTime? createdDateTime;
                    if (createdAtData is Timestamp) {
                      createdDateTime = createdAtData.toDate();
                    } else if (createdAtData is String) {
                      createdDateTime = DateTime.tryParse(createdAtData.toString().replaceAll('/', '-'));
                    }
                    final displayTime = createdDateTime ?? DateTime.now();

                    final isSelected = _selectedFeedbackIds.contains(doc.id);

                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      color: isSelected
                          ? Theme.of(
                              context,
                            ).primaryColor.withValues(alpha: 0.2)
                          : null,
                      child: InkWell(
                        onLongPress: () => _toggleSelection(doc.id),
                        onTap: () {
                          if (_selectedFeedbackIds.isNotEmpty) {
                            _toggleSelection(doc.id);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Row 1: Tag and Date
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).primaryColor.withValues(alpha: 0.1),
                                      border: Border.all(
                                        color: Theme.of(context).primaryColor,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      tag,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(context).primaryColor,
                                      ),
                                    ),
                                  ),
                                  Text(
                                    DateFormat(
                                      'yyyy-MM-dd HH:mm',
                                    ).format(displayTime),
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // Row 2: Title
                              Text(
                                title.isEmpty ? '(タイトルなし)' : title,
                                style: const TextStyle(
                                  fontSize: 14, // Same as body
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              // Row 3: Body
                              Text(
                                body,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }
}
