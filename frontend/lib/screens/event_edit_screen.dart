import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:frontend/screens/game_selection_screen.dart';

class _EventEditItem {
  final DocumentSnapshot doc;
  final Map<String, dynamic> originalData;
  bool isSelected = false;
  bool isLocked = false;

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
  })  : isLocked = originalData['isLocked'] == true,
        gameNameCtrl = TextEditingController(text: originalData['gameName']?.toString() ?? ''),
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

  // Filter State
  String _filterKeyword = '';
  List<String> _selectedGames = [];
  List<String> _selectedTags = [];
  List<String> _selectedSubTags = [];
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;
  bool _excludeChecked = false;
  bool _ongoingOnly = false;
  List<String> _checkedEventIds = [];

  // Sort State
  String _primarySortField = 'gameName';
  String _primarySortOrder = 'asc';
  String _secondarySortField = 'startDate';
  String _secondarySortOrder = 'asc';

  @override
  void initState() {
    super.initState();
    _loadPreferences();
    _loadData();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _filterKeyword = prefs.getString('filterKeyword') ?? '';
      _selectedGames = prefs.getStringList('selectedGames') ?? [];
      _selectedTags = prefs.getStringList('selectedTags') ?? [];
      _selectedSubTags = prefs.getStringList('selectedSubTags') ?? [];

      final startDateStr = prefs.getString('filterStartDate');
      if (startDateStr != null) {
        _filterStartDate = DateTime.tryParse(startDateStr);
      }

      final endDateStr = prefs.getString('filterEndDate');
      if (endDateStr != null) {
        _filterEndDate = DateTime.tryParse(endDateStr);
      }

      _excludeChecked = prefs.getBool('excludeChecked') ?? false;
      _ongoingOnly = prefs.getBool('ongoingOnly') ?? false;
      _checkedEventIds = prefs.getStringList('checkedEventIds') ?? [];

      _primarySortField = prefs.getString('primarySortField') ?? 'gameName';
      _primarySortOrder = prefs.getString('primarySortOrder') ?? 'asc';
      _secondarySortField = prefs.getString('secondarySortField') ?? 'startDate';
      _secondarySortOrder = prefs.getString('secondarySortOrder') ?? 'asc';
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('filterKeyword', _filterKeyword);
    await prefs.setStringList('selectedGames', _selectedGames);
    await prefs.setStringList('selectedTags', _selectedTags);
    await prefs.setStringList('selectedSubTags', _selectedSubTags);

    if (_filterStartDate != null) {
      await prefs.setString('filterStartDate', _filterStartDate!.toIso8601String());
    } else {
      await prefs.remove('filterStartDate');
    }

    if (_filterEndDate != null) {
      await prefs.setString('filterEndDate', _filterEndDate!.toIso8601String());
    } else {
      await prefs.remove('filterEndDate');
    }

    await prefs.setBool('excludeChecked', _excludeChecked);
    await prefs.setBool('ongoingOnly', _ongoingOnly);
    await prefs.setStringList('checkedEventIds', _checkedEventIds);

    await prefs.setString('primarySortField', _primarySortField);
    await prefs.setString('primarySortOrder', _primarySortOrder);
    await prefs.setString('secondarySortField', _secondarySortField);
    await prefs.setString('secondarySortOrder', _secondarySortOrder);
  }

  DateTime? _parseEventDate(String? dateStr) {
    if (dateStr == null) return null;
    try {
      String formatted = dateStr.replaceAll('/', '-').trim();
      if (formatted.contains(' ')) {
        formatted = formatted.replaceAll(' ', 'T');
      }
      final parts = formatted.split('T');
      if (parts.length == 2 && parts[1].split(':').length == 2) {
        formatted = '$formatted:00';
      }
      return DateTime.tryParse(formatted);
    } catch (e) {
      return null;
    }
  }

  bool _matchesKeyword(String keyword, _EventEditItem item) {
    if (keyword.trim().isEmpty) return true;

    final title = item.originalData['title'] as String? ?? '';
    final summary = item.originalData['summary'] as String? ?? '';
    final gameName = item.originalData['gameName'] as String? ?? '';
    final redeemCode = item.originalData['redeemCode'] as String? ?? '';

    final targetText = '$title $summary $gameName $redeemCode'.toLowerCase();

    final orTerms = keyword.toLowerCase().split('|').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    if (orTerms.isEmpty) return true;

    for (final orTerm in orTerms) {
      final andTerms = orTerm.split(RegExp(r'[\s　]+')).where((s) => s.isNotEmpty).toList();
      bool allAndMatch = true;
      for (final andTerm in andTerms) {
        if (!targetText.contains(andTerm)) {
          allAndMatch = false;
          break;
        }
      }
      if (allAndMatch) return true; // 1つのOR条件（ANDの集合）を満たした
    }
    return false;
  }

  void _showFilterBottomSheet(List<String> allGameNames) {
    final keywordController = TextEditingController(text: _filterKeyword);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '絞り込み',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),

                    // Keyword
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: TextField(
                        controller: keywordController,
                        decoration: InputDecoration(
                          labelText: 'キーワード',
                          hintText: 'スペースでAND、| でOR指定可能',
                          hintStyle: const TextStyle(fontWeight: FontWeight.w300),
                          border: const OutlineInputBorder(),
                          suffixIcon: _filterKeyword.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear),
                                  onPressed: () {
                                    keywordController.clear();
                                    setModalState(() {
                                      _filterKeyword = '';
                                    });
                                    setState(() {});
                                    _savePreferences();
                                  },
                                )
                              : null,
                        ),
                        onChanged: (value) {
                          setModalState(() {
                            _filterKeyword = value;
                          });
                          setState(() {});
                          _savePreferences();
                        },
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Tags
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 8.0,
                      ),
                      child: Text(
                        'タグ',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Wrap(
                        spacing: 8.0,
                        children: ['ゲーム内', 'ゲーム外', 'コード'].map((tag) {
                          return FilterChip(
                            label: Text(tag),
                            selected: _selectedTags.contains(tag),
                            onSelected: (bool selected) {
                              setModalState(() {
                                if (selected) {
                                  _selectedTags.add(tag);
                                } else {
                                  _selectedTags.remove(tag);
                                }
                              });
                              setState(() {});
                              _savePreferences();
                            },
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16.0),
                      child: Text(
                        '子タグ',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Wrap(
                        spacing: 8.0,
                        children: ['ガチャ', '期間限定', '常設'].map((subTag) {
                          return FilterChip(
                            label: Text(subTag),
                            selected: _selectedSubTags.contains(subTag),
                            onSelected: (bool selected) {
                              setModalState(() {
                                if (selected) {
                                  _selectedSubTags.add(subTag);
                                } else {
                                  _selectedSubTags.remove(subTag);
                                }
                              });
                              setState(() {});
                              _savePreferences();
                            },
                          );
                        }).toList(),
                      ),
                    ),
                    const Divider(),

                    // Game Selection
                    ListTile(
                      title: const Text('ゲーム名'),
                      subtitle: Text(
                        _selectedGames.isEmpty
                            ? 'すべて表示'
                            : _selectedGames.join(', '),
                      ),
                      trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => GameSelectionScreen(
                              allGames: allGameNames,
                              selectedGames: _selectedGames,
                              onSelectionChanged: (List<String> newSelection) {
                                setModalState(() {
                                  _selectedGames = newSelection;
                                });
                                setState(() {});
                                _savePreferences();
                              },
                            ),
                          ),
                        );
                      },
                    ),
                    const Divider(),

                    // Date Range
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 8.0,
                      ),
                      child: Text(
                        '期間指定',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 16),
                        const Text('開始: '),
                        Expanded(
                          child: Text(
                            _filterStartDate != null
                                ? "${_filterStartDate!.year}/${_filterStartDate!.month.toString().padLeft(2, '0')}/${_filterStartDate!.day.toString().padLeft(2, '0')}"
                                : "未指定",
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.calendar_today),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _filterStartDate ?? DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2101),
                            );
                            if (picked != null) {
                              setModalState(() {
                                _filterStartDate = picked;
                              });
                              setState(() {});
                              _savePreferences();
                            }
                          },
                        ),
                        if (_filterStartDate != null)
                          IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              setModalState(() {
                                _filterStartDate = null;
                              });
                              setState(() {});
                              _savePreferences();
                            },
                          ),
                      ],
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 16),
                        const Text('終了: '),
                        Expanded(
                          child: Text(
                            _filterEndDate != null
                                ? "${_filterEndDate!.year}/${_filterEndDate!.month.toString().padLeft(2, '0')}/${_filterEndDate!.day.toString().padLeft(2, '0')}"
                                : "未指定",
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.calendar_today),
                          onPressed: () async {
                            final picked = await showDatePicker(
                              context: context,
                              initialDate: _filterEndDate ?? DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2101),
                            );
                            if (picked != null) {
                              setModalState(() {
                                _filterEndDate = picked;
                              });
                              setState(() {});
                              _savePreferences();
                            }
                          },
                        ),
                        if (_filterEndDate != null)
                          IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              setModalState(() {
                                _filterEndDate = null;
                              });
                              setState(() {});
                              _savePreferences();
                            },
                          ),
                      ],
                    ),
                    const Divider(),

                    // Toggles
                    SwitchListTile(
                      title: const Text('チェック済みを除外'),
                      value: _excludeChecked,
                      onChanged: (bool value) {
                        setModalState(() {
                          _excludeChecked = value;
                        });
                        setState(() {});
                        _savePreferences();
                      },
                    ),
                    SwitchListTile(
                      title: const Text('開催中のみ'),
                      value: _ongoingOnly,
                      onChanged: (bool value) {
                        setModalState(() {
                          _ongoingOnly = value;
                        });
                        setState(() {});
                        _savePreferences();
                      },
                    ),

                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pop(context);
                      },
                      child: const Text('閉じる'),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  void _showSortDialog() {
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('並び替え'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '第一優先',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            value: _primarySortField,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(
                                value: 'gameName',
                                child: Text('ゲーム名'),
                              ),
                              DropdownMenuItem(
                                value: 'startDate',
                                child: Text('開始日'),
                              ),
                              DropdownMenuItem(
                                value: 'endDate',
                                child: Text('終了日'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => _primarySortField = value);
                                setState(() {});
                                _savePreferences();
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButton<String>(
                            value: _primarySortOrder,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: 'asc', child: Text('昇順')),
                              DropdownMenuItem(
                                value: 'desc',
                                child: Text('降順'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(() => _primarySortOrder = value);
                                setState(() {});
                                _savePreferences();
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '第二優先',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButton<String>(
                            value: _secondarySortField,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(
                                value: 'gameName',
                                child: Text('ゲーム名'),
                              ),
                              DropdownMenuItem(
                                value: 'startDate',
                                child: Text('開始日'),
                              ),
                              DropdownMenuItem(
                                value: 'endDate',
                                child: Text('終了日'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(
                                  () => _secondarySortField = value,
                                );
                                setState(() {});
                                _savePreferences();
                              }
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: DropdownButton<String>(
                            value: _secondarySortOrder,
                            isExpanded: true,
                            items: const [
                              DropdownMenuItem(value: 'asc', child: Text('昇順')),
                              DropdownMenuItem(
                                value: 'desc',
                                child: Text('降順'),
                              ),
                            ],
                            onChanged: (value) {
                              if (value != null) {
                                setDialogState(
                                  () => _secondarySortOrder = value,
                                );
                                setState(() {});
                                _savePreferences();
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('閉じる'),
                ),
              ],
            );
          },
        );
      },
    );
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

        if (item.isLocked != (item.originalData['isLocked'] == true)) {
          updateData['isLocked'] = item.isLocked;
        }

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

  Widget _buildTextField(String label, TextEditingController controller, {bool multiLine = false, Widget? suffixIcon}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: TextFormField(
        controller: controller,
        maxLines: multiLine ? null : 1,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: suffixIcon,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredAndSortedItems = _items.where((item) {
      if (!_matchesKeyword(_filterKeyword, item)) return false;

      final gameName = item.originalData['gameName'] as String?;
      if (_selectedGames.isNotEmpty &&
          (gameName == null || !_selectedGames.contains(gameName))) {
        return false;
      }

      final tag = item.originalData['tag'] as String?;
      if (_selectedTags.isNotEmpty &&
          (tag == null || !_selectedTags.contains(tag))) {
        return false;
      }

      final subTag = item.originalData['subTag'] as String?;
      if (_selectedSubTags.isNotEmpty &&
          (subTag == null || !_selectedSubTags.contains(subTag))) {
        return false;
      }

      if (_excludeChecked) {
        if (_checkedEventIds.contains(item.doc.id)) {
          return false;
        }
      }

      final startDate = _parseEventDate(item.originalData['startDate'] as String?);
      final endDate = _parseEventDate(item.originalData['endDate'] as String?);

      if (_ongoingOnly) {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);

        if (startDate != null) {
          final start = DateTime(
            startDate.year,
            startDate.month,
            startDate.day,
          );
          if (start.isAfter(today)) return false;
        }

        if (endDate != null) {
          final end = DateTime(
            endDate.year,
            endDate.month,
            endDate.day,
          );
          if (end.isBefore(today)) return false;
        }
      }

      if (_filterStartDate != null || _filterEndDate != null) {
        final startTarget = _filterStartDate != null
            ? DateTime(
                _filterStartDate!.year,
                _filterStartDate!.month,
                _filterStartDate!.day,
              )
            : null;
        final endTarget = _filterEndDate != null
            ? DateTime(
                _filterEndDate!.year,
                _filterEndDate!.month,
                _filterEndDate!.day,
              )
            : null;

        final eventStart = startDate != null
            ? DateTime(startDate.year, startDate.month, startDate.day)
            : null;
        final eventEnd = endDate != null
            ? DateTime(endDate.year, endDate.month, endDate.day)
            : null;

        if (startTarget != null &&
            eventEnd != null &&
            eventEnd.isBefore(startTarget)) {
          return false;
        }
        if (endTarget != null &&
            eventStart != null &&
            eventStart.isAfter(endTarget)) {
          return false;
        }
      }

      return true;
    }).toList();

    filteredAndSortedItems.sort((a, b) {
      final distantFuture = DateTime(9999, 12, 31);

      dynamic getFieldValue(_EventEditItem item, String field) {
        switch (field) {
          case 'gameName':
            return item.originalData['gameName'] as String? ?? '';
          case 'startDate':
            return _parseEventDate(item.originalData['startDate'] as String?) ?? distantFuture;
          case 'endDate':
            return _parseEventDate(item.originalData['endDate'] as String?) ?? distantFuture;
          default:
            return '';
        }
      }

      int compare(dynamic valA, dynamic valB, String order) {
        int result = 0;
        if (valA is DateTime && valB is DateTime) {
          result = valA.compareTo(valB);
        } else if (valA is String && valB is String) {
          result = valA.compareTo(valB);
        }
        return order == 'asc' ? result : -result;
      }

      final primaryA = getFieldValue(a, _primarySortField);
      final primaryB = getFieldValue(b, _primarySortField);
      int result = compare(primaryA, primaryB, _primarySortOrder);

      if (result == 0) {
        final secondaryA = getFieldValue(a, _secondarySortField);
        final secondaryB = getFieldValue(b, _secondarySortField);
        result = compare(secondaryA, secondaryB, _secondarySortOrder);
      }

      return result;
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text(''),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: () {
              final allGameNames = _items
                  .map((e) => e.originalData['gameName'] as String?)
                  .where((name) => name != null && name.isNotEmpty)
                  .cast<String>()
                  .toSet()
                  .toList();
              allGameNames.sort();
              _showFilterBottomSheet(allGameNames);
            },
            tooltip: '絞り込み',
          ),
          IconButton(
            icon: const Icon(Icons.sort),
            onPressed: () {
              _showSortDialog();
            },
            tooltip: '並び替え',
          ),
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
          : filteredAndSortedItems.isEmpty
              ? const Center(child: Text('条件に一致するイベントがありません。'))
              : ListView.builder(
              itemCount: filteredAndSortedItems.length,
              itemBuilder: (context, index) {
                final item = filteredAndSortedItems[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  child: Padding(
                    padding: const EdgeInsets.all(8.0),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Column(
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
                            IconButton(
                              icon: Icon(
                                item.isLocked ? Icons.lock : Icons.lock_open_rounded,
                                color: item.isLocked ? Colors.red : Colors.grey,
                              ),
                              onPressed: () {
                                setState(() {
                                  item.isLocked = !item.isLocked;
                                });
                              },
                              tooltip: '更新ロック',
                            ),
                            Text(
                              item.isLocked ? 'ロック' : '更新可',
                              style: TextStyle(
                                fontSize: 10,
                                color: item.isLocked ? Colors.red : Colors.grey,
                              ),
                            ),
                          ],
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildTextField('Game Name', item.gameNameCtrl),
                              Builder(
                                builder: (context) {
                                  final originalData = item.originalData;
                                  final targetTimestamp = (originalData['updatedAt'] ?? originalData['createdAt']) as Timestamp?;
                                  if (targetTimestamp != null) {
                                    final d = targetTimestamp.toDate();
                                    final dateStr = '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
                                    return Padding(
                                      padding: const EdgeInsets.only(bottom: 4.0),
                                      child: Text(
                                        '更新日:$dateStr',
                                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                                      ),
                                    );
                                  }
                                  return const SizedBox.shrink();
                                },
                              ),
                              _buildTextField(
                                'Title',
                                item.titleCtrl,
                                suffixIcon: IconButton(
                                  icon: const Icon(Icons.search),
                                  onPressed: () async {
                                    final gameName = item.gameNameCtrl.text;
                                    final title = item.titleCtrl.text;
                                    final query = Uri.encodeComponent('$gameName $title');
                                    final url = Uri.parse('https://www.google.com/search?q=$query');
                                    if (await canLaunchUrl(url)) {
                                      await launchUrl(url, mode: LaunchMode.externalApplication);
                                    } else if (context.mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Could not launch Google Search')),
                                      );
                                    }
                                  },
                                ),
                              ),
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
