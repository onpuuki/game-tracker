import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'debug_log_screen.dart';
import 'prompt_editor_screen.dart';
import 'sync_status_screen.dart';
import 'settings_screen.dart';
import 'timer_settings_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _ParsedEvent {
  final QueryDocumentSnapshot doc;
  final Map<String, dynamic> data;
  final String gameName;
  final DateTime? startDate;
  final DateTime? endDate;

  _ParsedEvent({
    required this.doc,
    required this.data,
    required this.gameName,
    this.startDate,
    this.endDate,
  });
}

class _HomeScreenState extends State<HomeScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool _isClearingEvents = false;
  List<String> _latestAllGameNames = [];

  // Filter State
  List<String> _selectedGames = [];
  List<String> _selectedTags = [];
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

  String _formatDateString(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '未定';
    try {
      String formatted = dateStr.replaceAll('/', '-').trim();
      if (formatted.contains(' ')) {
        formatted = formatted.replaceAll(' ', 'T');
      }

      final parts = formatted.split('T');
      if (parts.length == 2 && parts[1].split(':').length == 2) {
        formatted = '$formatted:00';
      }

      final dt = DateTime.parse(formatted);
      if (dt.hour == 0 &&
          dt.minute == 0 &&
          dt.second == 0 &&
          !dateStr.contains(':')) {
        return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";
      }
      return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
    } catch (e) {
      return dateStr;
    }
  }

  late Stream<DocumentSnapshot> _configStream;
  late Stream<QuerySnapshot> _eventsStream;

  @override
  void initState() {
    super.initState();
    _loadPreferences();

    _configStream = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: 'default',
    ).collection('settings').doc('config').snapshots();

    _eventsStream = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: 'default',
    ).collectionGroup('events').snapshots();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedGames = prefs.getStringList('selectedGames') ?? [];
      _selectedTags = prefs.getStringList('selectedTags') ?? [];

      final startDateStr = prefs.getString('filterStartDate');
      _filterStartDate = startDateStr != null
          ? DateTime.tryParse(startDateStr)
          : null;

      final endDateStr = prefs.getString('filterEndDate');
      _filterEndDate = endDateStr != null
          ? DateTime.tryParse(endDateStr)
          : null;

      _excludeChecked = prefs.getBool('excludeChecked') ?? false;
      _ongoingOnly = prefs.getBool('ongoingOnly') ?? false;
      _checkedEventIds = prefs.getStringList('checkedEventIds') ?? [];

      _primarySortField = prefs.getString('primarySortField') ?? 'gameName';
      _primarySortOrder = prefs.getString('primarySortOrder') ?? 'asc';
      _secondarySortField =
          prefs.getString('secondarySortField') ?? 'startDate';
      _secondarySortOrder = prefs.getString('secondarySortOrder') ?? 'asc';
    });
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('selectedGames', _selectedGames);
    await prefs.setStringList('selectedTags', _selectedTags);

    if (_filterStartDate != null) {
      await prefs.setString(
        'filterStartDate',
        _filterStartDate!.toIso8601String(),
      );
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

  void _showFilterBottomSheet(List<String> allGameNames) {
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
                      onTap: () async {
                        List<String> dialogTempSelected = List.from(
                          _selectedGames,
                        );
                        final result = await showDialog<List<String>>(
                          context: context,
                          builder: (context) {
                            return StatefulBuilder(
                              builder: (context, setDialogState) {
                                return AlertDialog(
                                  title: const Text('ゲームを選択'),
                                  content: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: allGameNames.map((game) {
                                        return CheckboxListTile(
                                          title: Text(game),
                                          value: dialogTempSelected.contains(
                                            game,
                                          ),
                                          onChanged: (bool? checked) {
                                            setDialogState(() {
                                              if (checked == true) {
                                                dialogTempSelected.add(game);
                                              } else {
                                                dialogTempSelected.remove(game);
                                              }
                                            });
                                          },
                                        );
                                      }).toList(),
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(context),
                                      child: const Text('キャンセル'),
                                    ),
                                    TextButton(
                                      onPressed: () => Navigator.pop(
                                        context,
                                        dialogTempSelected,
                                      ),
                                      child: const Text('OK'),
                                    ),
                                  ],
                                );
                              },
                            );
                          },
                        );
                        if (result != null) {
                          setModalState(() {
                            _selectedGames = result;
                          });
                          setState(() {});
                          _savePreferences();
                        }
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
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4.0),
            child: TextButton.icon(
              onPressed: () {
                _scaffoldKey.currentState?.openDrawer();
              },
              icon: const Icon(Icons.admin_panel_settings, size: 18),
              label: const Text('管理者メニュー'),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4.0),
            child: ElevatedButton.icon(
              onPressed: () {
                _showFilterBottomSheet(_latestAllGameNames);
              },
              icon: const Icon(Icons.filter_list, size: 18),
              label: const Text('絞り込み'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Theme.of(context).primaryColor,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 4.0),
            child: ElevatedButton.icon(
              onPressed: () {
                _showSortDialog();
              },
              icon: const Icon(Icons.sort, size: 18),
              label: const Text('並び替え'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Theme.of(context).primaryColor,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const SettingsScreen()),
              );
            },
          ),
          const SizedBox(width: 8.0),
        ],
      ),
      drawer: Drawer(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              decoration: BoxDecoration(color: Colors.deepPurple),
              child: Text(
                'Game Tracker Admin',
                style: TextStyle(color: Colors.white, fontSize: 24),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_document),
              title: const Text('Prompt Editor'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PromptEditorScreen(),
                  ),
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
                  MaterialPageRoute(
                    builder: (context) => const DebugLogScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.access_time),
              title: const Text('自動同期設定'),
              onTap: () {
                Navigator.pop(context); // Close drawer
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const TimerSettingsScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.sync),
              title: const Text('Run Sync'),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const SyncStatusScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete),
              title: _isClearingEvents
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Clear All Events'),
              onTap: _isClearingEvents
                  ? null
                  : () async {
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
                          final callable = FirebaseFunctions.instance
                              .httpsCallable(
                                'clearAllEvents',
                                options: HttpsCallableOptions(
                                  timeout: const Duration(minutes: 5),
                                ),
                              );
                          await callable.call();

                          if (!context.mounted) return;
                          Navigator.pop(context); // Close drawer
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Events cleared successfully'),
                            ),
                          );
                        } catch (e) {
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Failed to clear events: $e'),
                            ),
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
        stream: _configStream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          final data = snapshot.data?.data() as Map<String, dynamic>?;
          final targets =
              (data?['targets'] as List<dynamic>?)
                  ?.cast<Map<String, dynamic>>() ??
              [];

          final siteConfig = <String, Map<String, bool>>{};
          for (var target in targets) {
            final gameName = target['gameName'] as String?;
            if (gameName != null) {
              siteConfig[gameName] = {
                'GameWith': target['useGameWith'] as bool? ?? true,
                'Game8': target['useGame8'] as bool? ?? true,
                '神ゲー攻略': target['useKamigame'] as bool? ?? true,
              };
            }
          }

          if (targets.isEmpty) {
            return const Center(
              child: Text('No targets found. Add targets in URL Manager.'),
            );
          }

          return StreamBuilder<QuerySnapshot>(
            stream: _eventsStream,
            builder: (context, eventSnapshot) {
              if (eventSnapshot.hasError) {
                return Center(
                  child: Text('Error loading events: ${eventSnapshot.error}'),
                );
              }
              if (eventSnapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              final docs = eventSnapshot.data?.docs ?? [];

              if (docs.isEmpty) {
                return const Center(child: Text('No events found.'));
              }

              List<_ParsedEvent> parsedEvents = docs.map((doc) {
                final data = doc.data() as Map<String, dynamic>;
                final startDateStr = data['startDate'] as String?;
                final endDateStr = data['endDate'] as String?;

                DateTime? startDate = _parseEventDate(startDateStr);
                DateTime? endDate = _parseEventDate(endDateStr);

                return _ParsedEvent(
                  doc: doc,
                  data: data,
                  gameName: data['gameName'] as String? ?? 'Unknown Game',
                  startDate: startDate,
                  endDate: endDate,
                );
              }).toList();

              final Set<String> uniqueGamesSet = {};
              for (var event in parsedEvents) {
                uniqueGamesSet.add(event.gameName);
              }
              final List<String> allGameNames = uniqueGamesSet.toList()..sort();
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted &&
                    _latestAllGameNames.length != allGameNames.length) {
                  setState(() {
                    _latestAllGameNames = allGameNames;
                  });
                }
              });

              List<_ParsedEvent> events = parsedEvents.where((event) {
                // Tag Filter
                if (_selectedTags.isNotEmpty &&
                    !_selectedTags.contains(event.data['tag'])) {
                  return false;
                }

                // Game Filter
                if (_selectedGames.isNotEmpty &&
                    !_selectedGames.contains(event.gameName)) {
                  return false;
                }

                // Checked Filter
                if (_excludeChecked &&
                    _checkedEventIds.contains(event.doc.id)) {
                  return false;
                }

                final now = DateTime.now();
                final today = DateTime(now.year, now.month, now.day);

                // Ongoing Filter
                if (_ongoingOnly) {
                  if (event.startDate == null) return false;
                  final start = DateTime(
                    event.startDate!.year,
                    event.startDate!.month,
                    event.startDate!.day,
                  );
                  if (start.isAfter(today)) return false; // Not yet started

                  if (event.endDate != null) {
                    final end = DateTime(
                      event.endDate!.year,
                      event.endDate!.month,
                      event.endDate!.day,
                    );
                    if (end.isBefore(today)) return false; // Already ended
                  }
                  // If endDate is null, we assume it's ongoing once started
                }

                // Date Range Filter
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

                  final eventStart = event.startDate != null
                      ? DateTime(
                          event.startDate!.year,
                          event.startDate!.month,
                          event.startDate!.day,
                        )
                      : null;
                  final eventEnd = event.endDate != null
                      ? DateTime(
                          event.endDate!.year,
                          event.endDate!.month,
                          event.endDate!.day,
                        )
                      : null;

                  // For the event to be visible, its active period must overlap with the target period.
                  // Active period: [eventStart, eventEnd]
                  // Target period: [startTarget, endTarget]
                  // Overlap condition: eventEnd >= startTarget AND eventStart <= endTarget
                  // Treat missing start/end as +/- infinity for overlap logic.

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

              // Sort Logic
              events.sort((a, b) {
                final distantFuture = DateTime(9999, 12, 31);

                dynamic getFieldValue(_ParsedEvent event, String field) {
                  switch (field) {
                    case 'gameName':
                      return event.gameName;
                    case 'startDate':
                      return event.startDate ?? distantFuture;
                    case 'endDate':
                      return event.endDate ?? distantFuture;
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

              if (events.isEmpty) {
                return const Center(child: Text('No events matching filters.'));
              }

              return ListView.builder(
                itemCount: events.length,
                itemBuilder: (context, index) {
                  final parsedEvent = events[index];
                  final eventData = parsedEvent.data;
                  final eventGameName = parsedEvent.gameName;
                  final title = eventData['title'] as String? ?? 'No Title';
                  final tag = eventData['tag'] as String?;
                  final redeemCode = eventData['redeemCode'] as String?;
                  final eventUrl = eventData['eventUrl'] as String?;

                  final startDateStr = eventData['startDate'] as String?;
                  final endDateStr = eventData['endDate'] as String?;
                  final startDisplay = _formatDateString(startDateStr);
                  final endDisplay = _formatDateString(endDateStr);
                  final period = '$startDisplay ~ $endDisplay';

                  final summary = eventData['summary'] as String? ?? '';
                  final imageUrl = eventData['imageUrl'] as String?;

                  final startDate = parsedEvent.startDate;
                  final endDate = parsedEvent.endDate;

                  bool isUpcoming = false;
                  int? daysUntilStart;
                  final now = DateTime.now();
                  final today = DateTime(now.year, now.month, now.day);

                  if (startDate != null) {
                    final start = DateTime(
                      startDate.year,
                      startDate.month,
                      startDate.day,
                    );
                    if (start.isAfter(today)) {
                      isUpcoming = true;
                      daysUntilStart = start.difference(today).inDays;
                    }
                  }

                  int? remainingDays;
                  if (endDate != null) {
                    final end = DateTime(
                      endDate.year,
                      endDate.month,
                      endDate.day,
                    );
                    remainingDays = end.difference(today).inDays;
                  }

                  Widget? trailingWidget;
                  if (isUpcoming && daysUntilStart != null) {
                    trailingWidget = Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.withAlpha(26),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.green),
                      ),
                      child: Text(
                        '開催まで$daysUntilStart日',
                        style: const TextStyle(
                          color: Colors.green,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    );
                  } else if (remainingDays != null && remainingDays >= 0) {
                    trailingWidget = Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.withAlpha(26),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.red),
                      ),
                      child: Text(
                        '終了まで$remainingDays日',
                        style: const TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    );
                  }

                  final eventId = parsedEvent.doc.id;
                  final isChecked = _checkedEventIds.contains(eventId);
                  Color tagColor = Colors.orange;
                  if (tag == 'ゲーム内') {
                    tagColor = Colors.blue;
                  } else if (tag == 'コード') {
                    tagColor = Colors.purple;
                  }

                  final isDarkMode = Theme.of(context).brightness == Brightness.dark;

                  return Card(
                    margin: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 8.0,
                    ),
                    color: isChecked
                        ? (isDarkMode ? Colors.grey[800] : Colors.grey.shade300)
                        : null,
                    child: IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: isChecked
                                  ? null
                                  : () async {
                                      if (tag == 'コード') {
                                        final codeToCopy =
                                            (redeemCode != null &&
                                                redeemCode.isNotEmpty)
                                            ? redeemCode
                                            : title;
                                        await Clipboard.setData(
                                          ClipboardData(text: codeToCopy),
                                        );
                                        if (context.mounted) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text('コードをコピーしました'),
                                            ),
                                          );
                                        }
                                      } else {
                                        final query = '$eventGameName $title';
                                        final encodedQuery =
                                            Uri.encodeComponent(query);
                                        final uri = Uri.parse(
                                          'https://www.google.com/search?q=$encodedQuery',
                                        );
                                        if (await canLaunchUrl(uri)) {
                                          await launchUrl(
                                            uri,
                                            mode:
                                                LaunchMode.externalApplication,
                                          );
                                        } else {
                                          if (context.mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Could not launch URL',
                                                ),
                                              ),
                                            );
                                          }
                                        }
                                      }
                                    },
                              onLongPress: () {
                                setState(() {
                                  if (isChecked) {
                                    _checkedEventIds.remove(eventId);
                                  } else {
                                    _checkedEventIds.add(eventId);
                                  }
                                });
                                _savePreferences();
                              },
                              child: Stack(
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.all(12.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  if (imageUrl != null &&
                                                      imageUrl.isNotEmpty)
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                            bottom: 8.0,
                                                          ),
                                                      child: SizedBox(
                                                        width: 50,
                                                        height: 50,
                                                        child: Image.network(
                                                          imageUrl,
                                                          fit: BoxFit.cover,
                                                          errorBuilder:
                                                              (
                                                                context,
                                                                error,
                                                                stackTrace,
                                                              ) => const Icon(
                                                                Icons
                                                                    .image_not_supported,
                                                              ),
                                                        ),
                                                      ),
                                                    ),
                                                  Text(
                                                    eventGameName,
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      color: Theme.of(
                                                        context,
                                                      ).primaryColor,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            if (trailingWidget != null) ...[
                                              const SizedBox(width: 8),
                                              isChecked
                                                  ? Opacity(
                                                      opacity: 0.5,
                                                      child: trailingWidget,
                                                    )
                                                  : trailingWidget,
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Wrap(
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              spacing: 6.0,
                                              children: [
                                                if (tag != null &&
                                                    tag.isNotEmpty)
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 6,
                                                          vertical: 2,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: tagColor.withAlpha(
                                                        26,
                                                      ),
                                                      border: Border.all(
                                                        color: tagColor,
                                                      ),
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            4,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      tag,
                                                      style: TextStyle(
                                                        fontSize: 10,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: tagColor,
                                                      ),
                                                    ),
                                                  ),
                                                Text(
                                                  title,
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    decoration: isChecked
                                                        ? TextDecoration
                                                              .lineThrough
                                                        : null,
                                                    color: isChecked
                                                        ? Colors.grey
                                                        : null,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 4),
                                            Text(
                                              period,
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                color: isChecked
                                                    ? Colors.grey
                                                    : Colors.blueGrey,
                                              ),
                                            ),
                                            if (summary.isNotEmpty) ...[
                                              const SizedBox(height: 4),
                                              Text(
                                                summary,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontSize: 12,
                                                  color: isChecked
                                                      ? Colors.grey
                                                      : null,
                                                ),
                                              ),
                                            ],
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isChecked)
                                    Positioned.fill(
                                      child: Center(
                                        child: Transform.rotate(
                                          angle: -0.3,
                                          child: Text(
                                            '済',
                                            style: TextStyle(
                                              fontSize: 60,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.red.withAlpha(128),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (tag == 'コード' &&
                              eventUrl != null &&
                              eventUrl.isNotEmpty)
                            Container(
                              width: 70,
                              decoration: BoxDecoration(
                                borderRadius: const BorderRadius.only(
                                  topRight: Radius.circular(12),
                                  bottomRight: Radius.circular(12),
                                ),
                                color: isChecked
                                    ? Colors.grey.shade400
                                    : Theme.of(context).primaryColor,
                              ),
                              child: Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  borderRadius: const BorderRadius.only(
                                    topRight: Radius.circular(12),
                                    bottomRight: Radius.circular(12),
                                  ),
                                  onTap: isChecked
                                      ? null
                                      : () async {
                                          final uri = Uri.parse(eventUrl);
                                          if (await canLaunchUrl(uri)) {
                                            await launchUrl(
                                              uri,
                                              mode: LaunchMode
                                                  .externalApplication,
                                            );
                                          } else if (context.mounted) {
                                            ScaffoldMessenger.of(
                                              context,
                                            ).showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                  'Could not launch URL',
                                                ),
                                              ),
                                            );
                                          }
                                        },
                                  child: const Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.open_in_browser,
                                        color: Colors.white,
                                      ),
                                      SizedBox(height: 4),
                                      Text(
                                        '自動\n入力',
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
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
