import 'timeline_view.dart';
import 'package:flutter/material.dart';
import 'dart:ui';
import 'dart:async';
import '../widgets/keep_alive_page.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'debug_log_screen.dart';
import 'prompt_editor_screen.dart';
import 'sync_status_screen.dart';
import 'settings_screen.dart';
import 'timer_settings_screen.dart';
import 'feedback_screen.dart';
import 'feedback_list_screen.dart';

import 'add_event_screen.dart';
import 'game_selection_screen.dart';
import 'export_settings_screen.dart';
import '../services/widget_sync_service.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class ParsedEvent {
  final QueryDocumentSnapshot doc;
  final Map<String, dynamic> data;
  final String gameName;
  final DateTime? startDate;
  final DateTime? endDate;

  ParsedEvent({
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
  bool _isTestingNotification = false;
  List<String> _latestAllGameNames = [];

  final Map<int, NativeAd> _nativeAds = {};
  final Map<int, bool> _nativeAdLoaded = {};
  final Map<int, bool> _nativeAdFailed = {};
  static const int _adInterval = 8;
  bool _isPremium = false;

  // Filter State
  String _filterKeyword = '';
  List<String> _selectedGames = [];
  List<String> _userCustomGames = [];
  bool _showOnlyCustomGames = false;
  List<String> _selectedTags = [];
  DateTime? _filterStartDate;
  DateTime? _filterEndDate;
  bool _excludeChecked = false;
  bool _ongoingOnly = false;
  List<String> _checkedEventIds = [];
  Map<String, String> _codeUrls = {};

  bool _showDaily = true;
  bool _showWeekly = true;
  bool _showBiweekly = true;
  bool _showMonthly = true;

  // Sort State
  String _primarySortField = 'gameName';
  String _primarySortOrder = 'asc';
  Timer? _debounceTimer;

  DateTime? _parseEventDate(dynamic dateData) {
    if (dateData == null) return null;
    if (dateData is Timestamp) {
      return dateData.toDate();
    }
    String? dateStr = dateData?.toString();
    if (dateStr == null || dateStr.isEmpty) return null;

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

  bool _matchesKeyword(String keyword, ParsedEvent event) {
    if (keyword.trim().isEmpty) return true;

    final title = event.data['title']?.toString() ?? '';
    final summary = event.data['summary']?.toString() ?? '';
    final gameName = event.gameName;
    final redeemCode = event.data['redeemCode']?.toString() ?? '';

    final targetText = '$title $summary $gameName $redeemCode'.toLowerCase();

    final orTerms = keyword
        .toLowerCase()
        .split('|')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (orTerms.isEmpty) return true;

    for (final orTerm in orTerms) {
      final andTerms = orTerm
          .split(RegExp(r'[\s　]+'))
          .where((s) => s.isNotEmpty)
          .toList();
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

  String _formatDateString(dynamic dateData) {
    if (dateData == null) return '未定';

    DateTime? dt;
    if (dateData is Timestamp) {
      dt = dateData.toDate();
    } else {
      String? dateStr = dateData?.toString();
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

        dt = DateTime.parse(formatted);
        if (dt.hour == 0 &&
            dt.minute == 0 &&
            dt.second == 0 &&
            !dateStr.contains(':')) {
          return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";
        }
      } catch (e) {
        return '未定';
      }
    }

    return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }

  late Stream<DocumentSnapshot> _configStream;
  StreamController<List<QueryDocumentSnapshot>>? _eventsStreamController;
  final List<StreamSubscription> _eventSubscriptions = [];
  final Map<String, List<QueryDocumentSnapshot>> _eventSnapshotsMap = {};

  void _initEventsStream() {
    _eventsStreamController?.close();
    _eventsStreamController = StreamController<List<QueryDocumentSnapshot>>.broadcast();
    for (var sub in _eventSubscriptions) {
      sub.cancel();
    }
    _eventSubscriptions.clear();
    _eventSnapshotsMap.clear();

    final db = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: 'default',
    );

    // Standard events (filtered by isStandard = true as per memory rule)
    final standardSub = db
        .collectionGroup('events')
        .where('isStandard', isEqualTo: true)
        .snapshots()
        .listen((snapshot) {
      _eventSnapshotsMap['standard'] = snapshot.docs;
      _emitEvents();
    }, onError: (e) {
      _eventsStreamController?.addError(e);
    });
    _eventSubscriptions.add(standardSub);

    // Custom games events
    for (final gameName in _userCustomGames) {
      if (gameName.isNotEmpty) {
        final safeGameName = Uri.encodeComponent(gameName.replaceAll('/', '／'));
        final customSub = db
            .collection('games')
            .doc(safeGameName)
            .collection('events')
            .snapshots()
            .listen((snapshot) {
          _eventSnapshotsMap['custom_$gameName'] = snapshot.docs;
          _emitEvents();
        }, onError: (e) {
          _eventsStreamController?.addError(e);
        });
        _eventSubscriptions.add(customSub);
      }
    }
  }

  void _emitEvents() {
    if (_eventsStreamController?.isClosed == true) return;
    final List<QueryDocumentSnapshot> allDocs = [];
    for (final docs in _eventSnapshotsMap.values) {
      allDocs.addAll(docs);
    }
    _eventsStreamController?.add(allDocs);
  }

  Widget _buildEventCard(ParsedEvent parsedEvent) {
    try {
      final isDarkMode = Theme.of(context).brightness == Brightness.dark;
      final eventData = parsedEvent.data;
      final eventGameName = parsedEvent.gameName;
      final title = eventData['title']?.toString() ?? 'No Title';
      final tag = eventData['tag']?.toString();
      final subTag = eventData['subTag']?.toString();
      final redeemCode = eventData['redeemCode']?.toString();
      final eventUrl = eventData['eventUrl']?.toString();

      final startDateData = eventData['startDate'];
      final endDateData = eventData['endDate'];
      final startDisplay = _formatDateString(startDateData);
      final endDisplay = _formatDateString(endDateData);
      final period = '$startDisplay ~ $endDisplay';

      final summary = eventData['summary']?.toString() ?? '';
      final imageUrl = eventData['imageUrl']?.toString();
      final rewardsRaw = eventData['rewards'];
      final List<String> rewards = [];
      if (rewardsRaw is List) {
        for (var r in rewardsRaw) {
          if (r is Map) {
            final name = r['name']?.toString() ?? '';
            final quantity = r['quantity']?.toString() ?? '';
            if (name.isNotEmpty) {
               rewards.add(quantity.isNotEmpty ? '$name x$quantity' : name);
            }
          } else {
            rewards.add(r.toString());
          }
        }
      }

      final startDate = parsedEvent.startDate;
      final endDate = parsedEvent.endDate;

      final gameCodeUrl = _codeUrls[eventGameName];
      final hasValidCodeUrl = gameCodeUrl != null && gameCodeUrl.isNotEmpty;

      bool isUpcoming = false;
      int? startInDays;
      int? startInHours;
      int? endInDays;
      int? endInHours;

      final now = DateTime.now();

      if (startDate != null) {
        if (startDate.isAfter(now)) {
          isUpcoming = true;
          final diff = startDate.difference(now);
          startInDays = diff.inDays;
          startInHours = diff.inHours % 24;
        }
      }

      bool isOngoing = false;
      if (!isUpcoming && endDate != null) {
        if (endDate.isAfter(now) || endDate.isAtSameMomentAs(now)) {
          isOngoing = true;
          final diff = endDate.difference(now);
          endInDays = diff.inDays;
          endInHours = diff.inHours % 24;
        }
      }

      Widget? trailingWidget;
      if (isUpcoming && startInDays != null && startInHours != null) {
        final textStr = startInDays > 0
            ? '開催まで$startInDays日$startInHours時間'
            : '開催まで$startInHours時間';
        trailingWidget = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.green.withAlpha(26),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.green),
          ),
          child: Text(
            textStr,
            style: const TextStyle(
              color: Colors.green,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        );
      } else if (isOngoing && endInDays != null && endInHours != null) {
        final textStr = endInDays > 0
            ? '終了まで$endInDays日$endInHours時間'
            : '終了まで$endInHours時間';
        trailingWidget = Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.red.withAlpha(26),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.red),
          ),
          child: Text(
            textStr,
            style: const TextStyle(
              color: Colors.red,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        );
      }

      final eventId = parsedEvent.doc.id;
      final isCycleEvent = eventData['isCycleEvent'] == true;
      final eventIsCompletedDoc = eventData['isCompleted'] == true;
      final isChecked =
          _checkedEventIds.contains(eventId) || eventIsCompletedDoc;

      Color tagColor = Colors.orange;
      if (tag == 'ゲーム内') {
        tagColor = Colors.blue;
      } else if (tag == 'コード') {
        tagColor = Colors.purple;
      }

      final rawUpdated = eventData['updatedAt'] ?? eventData['createdAt'];
      DateTime? updatedDt;
      if (rawUpdated is Timestamp) {
        updatedDt = rawUpdated.toDate();
      } else if (rawUpdated is String) {
        updatedDt = DateTime.tryParse(
          rawUpdated.toString().replaceAll('/', '-'),
        );
      }

      String dateStr = '';
      if (updatedDt != null) {
        final d = updatedDt;
        dateStr =
            '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
      }

      return _EventCardItem(
        key: ValueKey(eventId),
        isPremium: _isPremium,
        parsedEvent: parsedEvent,
        eventData: eventData,
        eventGameName: _userCustomGames.contains(eventGameName)
            ? '👑 $eventGameName'
            : eventGameName,
        title: title,
        tag: tag,
        subTag: subTag,
        redeemCode: redeemCode,
        eventUrl: eventUrl,
        startDateStr: startDateData?.toString(),
        endDateStr: endDateData?.toString(),
        startDisplay: startDisplay,
        endDisplay: endDisplay,
        period: period,
        summary: summary,
        imageUrl: imageUrl,
        rewards: rewards,
        startDate: startDate,
        endDate: endDate,
        gameCodeUrl: gameCodeUrl,
        hasValidCodeUrl: hasValidCodeUrl,
        trailingWidget: trailingWidget,
        eventId: eventId,
        isCycleEvent: isCycleEvent,
        eventIsCompletedDoc: eventIsCompletedDoc,
        isChecked: isChecked,
        tagColor: tagColor,
        isDarkMode: isDarkMode,
        dateStr: dateStr,
        onCheckedToggle: () async {
          setState(() {
            if (isChecked) {
              _checkedEventIds.remove(eventId);
            } else {
              _checkedEventIds.add(eventId);
            }
          });
          await _savePreferences();
          await _syncCheckedEventsToFirestore();
          try {
            await WidgetSyncService.syncTop5Events(
              excludedIds: _checkedEventIds.toList(),
              throwError: true,
            );
          } catch (e) {
            debugPrint('WidgetSync Error: $e');
            FirebaseFirestore.instanceFor(
              app: Firebase.app(),
              databaseId: 'default',
            ).collection('debug_logs').add({
              'error': e.toString(),
              'timestamp': FieldValue.serverTimestamp(),
            });
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('ウィジェットの更新に失敗しました: $e')),
            );
          }
        },
      );
    } catch (e) {
      return const SizedBox.shrink();
    }
  }

  @override
  void initState() {
    super.initState();

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      final title =
          message.notification?.title ?? message.data['title'] ?? '通知';
      final body =
          message.notification?.body ?? message.data['body'] ?? '未完了のイベントがあります';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('🔔 $title\n$body'),
          duration: const Duration(seconds: 5),
          behavior: SnackBarBehavior.floating,
          backgroundColor: Colors.blue.shade900,
        ),
      );
    });

    _loadPreferences();
    WidgetSyncService.syncTop5Events();

    _configStream = FirebaseFirestore.instanceFor(
      app: Firebase.app(),
      databaseId: 'default',
    ).collection('settings').doc('config').snapshots();

    _initEventsStream();
  }

  @override
  void dispose() {
    for (final ad in _nativeAds.values) {
      ad.dispose();
    }
    for (var sub in _eventSubscriptions) {
      sub.cancel();
    }
    _eventsStreamController?.close();
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _isPremium = prefs.getBool('is_premium') ?? false;
      _filterKeyword = prefs.getString('filterKeyword') ?? '';
      _selectedGames = prefs.getStringList('selectedGames') ?? [];
      _selectedTags = prefs.getStringList('selectedTags') ?? [];

      final startDateStr = prefs.getString('filterStartDate');
      _filterStartDate = startDateStr != null
          ? DateTime.tryParse(startDateStr.replaceAll('/', '-'))
          : null;

      final endDateStr = prefs.getString('filterEndDate');
      _filterEndDate = endDateStr != null
          ? DateTime.tryParse(endDateStr.replaceAll('/', '-'))
          : null;

      _excludeChecked = prefs.getBool('excludeChecked') ?? false;
      _ongoingOnly = prefs.getBool('ongoingOnly') ?? false;
      _checkedEventIds = prefs.getStringList('checkedEventIds') ?? [];

      _showDaily = prefs.getBool('showDaily') ?? true;
      _showWeekly = prefs.getBool('showWeekly') ?? true;
      _showBiweekly = prefs.getBool('showBiweekly') ?? true;
      _showMonthly = prefs.getBool('showMonthly') ?? true;

      _showOnlyCustomGames = prefs.getBool('showOnlyCustomGames') ?? false;

      _primarySortField = prefs.getString('primarySortField') ?? 'gameName';
      _primarySortOrder = prefs.getString('primarySortOrder') ?? 'asc';
    });

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      FirebaseFirestore.instanceFor(
        app: Firebase.app(),
        databaseId: 'default',
      ).collection('users').doc(user.uid).get().then((doc) async {
        if (!mounted) return;
        if (doc.exists) {
          final data = doc.data();
          if (data != null) {
            if (data.containsKey('isPremium')) {
              final isPremiumDB = data['isPremium'] as bool;
              if (prefs.getBool('is_premium') != isPremiumDB) {
                await prefs.setBool('is_premium', isPremiumDB);
                if (!mounted) return;
                setState(() {
                  _isPremium = isPremiumDB;
                });
              }
            }
            if (!mounted) return;
            bool customGamesChanged = false;
            setState(() {
              if (data.containsKey('customGames')) {
                final newCustomGames = List<String>.from(data['customGames'] ?? []);
                if (newCustomGames.join(',') != _userCustomGames.join(',')) {
                  _userCustomGames = newCustomGames;
                  customGamesChanged = true;
                }
              }
              if (data.containsKey('checkedEvents')) {
                _checkedEventIds = List<String>.from(
                  data['checkedEvents'] ?? [],
                );
              }
            });
            if (customGamesChanged) {
              _initEventsStream();
            }
          }
        }
      });
    }

    final hasShownWelcomeDialog =
        prefs.getBool('hasShownWelcomeDialog') ?? false;
    if (!hasShownWelcomeDialog) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _showWelcomeDialog();
      });
    }
  }

  Future<void> _showWelcomeDialog() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('はじめに（必ずお読みください）'),
          content: const SingleChildScrollView(
            child: Text(
              'ダウンロードありがとうございます！\n本アプリは、複数ゲームのイベントスケジュールやコード情報を効率よく確認するためのファンメイドの非公式アプリです。各ゲームの公式運営会社様とは一切関係ありません。\n\n掲載しているイベント情報はAIを活用して自動収集しているため、実際の開催期間や内容と異なる場合があります。課金やガチャなどに関する正確な情報は、必ず公式のアナウンスをご確認ください。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('hasShownWelcomeDialog', true);
                if (!context.mounted) return;
                Navigator.of(context).pop();
              },
              child: const Text('同意してはじめる'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _syncCheckedEventsToFirestore() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        await FirebaseFirestore.instanceFor(
          app: Firebase.app(),
          databaseId: 'default',
        ).collection('users').doc(user.uid).set({
          'checkedEvents': _checkedEventIds,
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint('Failed to sync checked events: $e');
      }
    }
  }

  Future<void> _savePreferences() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('filterKeyword', _filterKeyword);
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
    await prefs.setBool('showOnlyCustomGames', _showOnlyCustomGames);

    await prefs.setBool('showDaily', _showDaily);
    await prefs.setBool('showWeekly', _showWeekly);
    await prefs.setBool('showBiweekly', _showBiweekly);
    await prefs.setBool('showMonthly', _showMonthly);

    await prefs.setString('primarySortField', _primarySortField);
    await prefs.setString('primarySortOrder', _primarySortOrder);
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
                          hintStyle: const TextStyle(
                            fontWeight: FontWeight.w300,
                          ),
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
                          _debounceTimer?.cancel();
                          _debounceTimer = Timer(const Duration(milliseconds: 500), () {
                            _savePreferences();
                          });
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
                    const Divider(),

                    // Cycle Events
                    const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 16.0,
                        vertical: 8.0,
                      ),
                      child: Text(
                        'サイクルイベント',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Wrap(
                        spacing: 8.0,
                        children: [
                          FilterChip(
                            label: const Text('デイリー'),
                            selected: _showDaily,
                            onSelected: (bool selected) {
                              setModalState(() {
                                _showDaily = selected;
                              });
                              setState(() {});
                              _savePreferences();
                            },
                          ),
                          FilterChip(
                            label: const Text('ウィークリー'),
                            selected: _showWeekly,
                            onSelected: (bool selected) {
                              setModalState(() {
                                _showWeekly = selected;
                              });
                              setState(() {});
                              _savePreferences();
                            },
                          ),
                          FilterChip(
                            label: const Text('隔週'),
                            selected: _showBiweekly,
                            onSelected: (bool selected) {
                              setModalState(() {
                                _showBiweekly = selected;
                              });
                              setState(() {});
                              _savePreferences();
                            },
                          ),
                          FilterChip(
                            label: const Text('マンスリー'),
                            selected: _showMonthly,
                            onSelected: (bool selected) {
                              setModalState(() {
                                _showMonthly = selected;
                              });
                              setState(() {});
                              _savePreferences();
                            },
                          ),
                        ],
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
                              userCustomGames: _userCustomGames,
                              showOnlyCustomGames: _showOnlyCustomGames,
                              onSelectionChanged: (List<String> newSelection) {
                                setModalState(() {
                                  _selectedGames = newSelection;
                                });
                                setState(() {});
                                _savePreferences();
                              },
                              onToggleShowOnlyCustomGames: (bool value) {
                                setModalState(() {
                                  _showOnlyCustomGames = value;
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


  @override
  Widget build(BuildContext context) {
    final isDarkMode = Theme.of(context).brightness == Brightness.dark;
    const bool isAdmin = bool.fromEnvironment('IS_ADMIN', defaultValue: false);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          automaticallyImplyLeading: false,
          bottom: const TabBar(
            tabs: [
              Tab(text: 'リスト'),
              Tab(text: 'タイムライン'),
            ],
          ),
          actions: [
            if (isAdmin)
              Padding(
                padding: const EdgeInsets.only(right: 4.0),
                child: TextButton.icon(
                  onPressed: () {
                    _scaffoldKey.currentState?.openDrawer();
                  },
                  icon: const Icon(Icons.admin_panel_settings, size: 18),
                  label: const Text('管理者メニュー'),
                  style: TextButton.styleFrom(
                    foregroundColor: isDarkMode
                        ? Colors.white
                        : Theme.of(context).colorScheme.primary,
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
            Builder(
              builder: (context) {
                final tabController = DefaultTabController.of(context);
                return ListenableBuilder(
                  listenable: tabController,
                  builder: (context, child) {
                    if (tabController.index != 0) {
                      return const SizedBox.shrink(); // タイムラインタブでは非表示
                    }
                    return Padding(
                      padding: const EdgeInsets.only(right: 4.0),
                      child: PopupMenuButton<String>(
                        onSelected: (value) {
                          final parts = value.split('_');
                          if (parts.length == 2) {
                            setState(() {
                              _primarySortField = parts[0];
                              _primarySortOrder = parts[1];
                            });
                            _savePreferences();
                          }
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem(
                            value: 'gameName_asc',
                            child: Text('ゲーム名 (昇順)'),
                          ),
                          const PopupMenuItem(
                            value: 'gameName_desc',
                            child: Text('ゲーム名 (降順)'),
                          ),
                          const PopupMenuItem(
                            value: 'startDate_asc',
                            child: Text('開始日 (昇順)'),
                          ),
                          const PopupMenuItem(
                            value: 'startDate_desc',
                            child: Text('開始日 (降順)'),
                          ),
                          const PopupMenuItem(
                            value: 'endDate_asc',
                            child: Text('終了日 (昇順)'),
                          ),
                          const PopupMenuItem(
                            value: 'endDate_desc',
                            child: Text('終了日 (降順)'),
                          ),
                        ],
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 2,
                                offset: const Offset(0, 1),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.sort,
                                size: 18,
                                color: Theme.of(context).primaryColor,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                '並び替え',
                                style: TextStyle(
                                  color: Theme.of(context).primaryColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.settings),
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const SettingsScreen(),
                  ),
                );
                _loadPreferences();
              },
            ),
            const SizedBox(width: 8.0),
          ],
        ),
        drawer: isAdmin
            ? Drawer(
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
                      title: const Text('対象ゲーム設定'),
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
                      leading: const Icon(Icons.feedback),
                      title: const Text('フィードバック一覧'),
                      onTap: () {
                        Navigator.pop(context); // Close drawer
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const FeedbackListScreen(),
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.bug_report),
                      title: const Text('デバッグログ'),
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
                      title: const Text('自動スキャン時刻設定'),
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
                      title: const Text('手動スキャン実行'),
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
                      leading: const Icon(Icons.add),
                      title: const Text('イベント追加'),
                      onTap: () {
                        Navigator.pop(context);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const AddEventScreen(),
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
                          : const Text('全イベント削除'),
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
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('キャンセル'),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, true),
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
                                  final callable =
                                      FirebaseFunctions.instanceFor(
                                        region: 'asia-northeast1',
                                      ).httpsCallable(
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
                                      content: Text(
                                        'Events cleared successfully',
                                      ),
                                    ),
                                  );
                                } catch (e) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'Failed to clear events: $e',
                                      ),
                                    ),
                                  );
                                }
                                if (!mounted) return;
                                setState(() {
                                  _isClearingEvents = false;
                                });
                              }
                            },
                    ),
                    ListTile(
                      leading: const Icon(Icons.notifications_active),
                      title: _isTestingNotification
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('手動通知テスト(即時)'),
                      onTap: _isTestingNotification
                          ? null
                          : () async {
                              setState(() {
                                _isTestingNotification = true;
                              });

                              if (!context.mounted) return;
                              Navigator.pop(
                                context,
                              ); // Close drawer immediately

                              try {
                                final callable = FirebaseFunctions.instanceFor(
                                  region: 'asia-northeast1',
                                ).httpsCallable('testSendNotifications');
                                final result = await callable.call();
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      result.data['message'] ?? '実行完了',
                                    ),
                                  ),
                                );
                              } catch (e) {
                                debugPrint('Test notification error: $e');
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('テスト失敗: ${e.toString()}'),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                              if (!context.mounted) return;
                              setState(() {
                                _isTestingNotification = false;
                              });
                            },
                    ),
                    ListTile(
                      leading: const Icon(Icons.file_download),
                      title: const Text('エクスポート'),
                      onTap: () {
                        Navigator.pop(context); // Close drawer
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const ExportSettingsScreen(),
                          ),
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('ウェルカムダイアログ確認'),
                      onTap: () {
                        Navigator.pop(context); // Close drawer
                        _showWelcomeDialog();
                      },
                    ),
                  ],
                ),
              )
            : null,
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

            final abbreviationsMap = <String, String>{};
            for (var target in targets) {
              final gName = target['gameName'] as String?;
              final abbrev = target['abbreviation'] as String?;
              if (gName != null && abbrev != null && abbrev.isNotEmpty) {
                abbreviationsMap[gName] = abbrev;
              }
            }

            final codeUrlsData =
                (data?['codeUrls'] as List<dynamic>?)
                    ?.cast<Map<String, dynamic>>() ??
                [];
            final codeUrls = <String, String>{};
            for (var item in codeUrlsData) {
              final gameName = item['gameName'] as String?;
              final url = item['url'] as String?;
              if (gameName != null && url != null && url.isNotEmpty) {
                codeUrls[gameName] = url;
              }
            }
            _codeUrls = codeUrls;

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

            return StreamBuilder<List<QueryDocumentSnapshot>>(
              stream: _eventsStreamController?.stream,
              builder: (context, eventSnapshot) {
                if (eventSnapshot.hasError) {
                  return Center(
                    child: Text('Error loading events: ${eventSnapshot.error}'),
                  );
                }
                if (eventSnapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                final docs = eventSnapshot.data ?? [];

                if (docs.isEmpty) {
                  return const Center(child: Text('No events found.'));
                }

                List<ParsedEvent> parsedEvents = docs.map((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final startDateData = data['startDate'];
                  final endDateData = data['endDate'];

                  DateTime? startDate = _parseEventDate(startDateData);
                  DateTime? endDate = _parseEventDate(endDateData);

                  return ParsedEvent(
                    doc: doc,
                    data: data,
                    gameName: data['gameName']?.toString() ?? 'Unknown Game',
                    startDate: startDate,
                    endDate: endDate,
                  );
                }).toList();

                final Set<String> uniqueGamesSet = {};
                for (var event in parsedEvents) {
                  uniqueGamesSet.add(event.gameName);
                }
                final List<String> allGameNames = uniqueGamesSet.toList()
                  ..sort();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  if (_latestAllGameNames.length != allGameNames.length) {
                    setState(() {
                      _latestAllGameNames = allGameNames;
                    });
                  }
                });

                List<ParsedEvent> events = parsedEvents.where((event) {
                  // Ignore logically deleted events
                  if (event.data['isDeleted'] == true) {
                    return false;
                  }

                  // Keyword Filter
                  if (!_matchesKeyword(_filterKeyword, event)) {
                    return false;
                  }

                  // Tag Filter
                  if (_selectedTags.isNotEmpty &&
                      !_selectedTags.contains(event.data['tag'])) {
                    return false;
                  }

                  // Cycle Event Filter
                  if (event.data['isCycleEvent'] == true) {
                    final cycleType = event.data['cycleType'];
                    if (cycleType == 'daily' && !_showDaily) return false;
                    if (cycleType == 'weekly' && !_showWeekly) return false;
                    if (cycleType == 'biweekly' && !_showBiweekly) return false;
                    if (cycleType == 'monthly' && !_showMonthly) return false;
                  }

                  // Custom Games Visibility and Filter
                  final isCustom = event.data['isCustomGame'] == true;
                  if (isCustom && !_userCustomGames.contains(event.gameName)) {
                    return false;
                  }

                  if (_showOnlyCustomGames) {
                    if (!_userCustomGames.contains(event.gameName)) {
                      return false;
                    }
                  } else {
                    // Game Filter
                    if (_selectedGames.isNotEmpty &&
                        !_selectedGames.contains(event.gameName)) {
                      return false;
                    }
                  }

                  // Checked Filter
                  if (_excludeChecked &&
                      (_checkedEventIds.contains(event.doc.id) ||
                          event.data['isCompleted'] == true)) {
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
                            23,
                            59,
                            59,
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

                  dynamic getFieldValue(ParsedEvent event, String field) {
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

                  return result;
                });

                if (events.isEmpty) {
                  return const Center(
                    child: Text('No events matching filters.'),
                  );
                }

                return TabBarView(
                  children: [
                    KeepAlivePage(
                      child: ListView.builder(
                        itemCount: _isPremium
                            ? events.length
                            : events.length + (events.length ~/ _adInterval),
                        itemBuilder: (context, index) {
                          if (_isPremium) {
                            return _buildEventCard(events[index]);
                          }

                          final bool isAdIndex =
                              (index + 1) % (_adInterval + 1) == 0;
                          final int eventIndex =
                              index - (index ~/ (_adInterval + 1));

                          if (isAdIndex) {
                            if (!_nativeAds.containsKey(index)) {
                              _nativeAds[index] = NativeAd(
                                adUnitId:
                                    'ca-app-pub-3940256099942544/2247696110', // Test Native ad ID
                                request: const AdRequest(),
                                listener: NativeAdListener(
                                  onAdLoaded: (ad) {
                                    debugPrint(
                                      '$NativeAd loaded at index $index.',
                                    );
                                    if (!mounted) return;
                                    setState(() {
                                      _nativeAdLoaded[index] = true;
                                    });
                                  },
                                  onAdFailedToLoad: (ad, error) {
                                    debugPrint(
                                      '$NativeAd failedToLoad at index $index: $error',
                                    );
                                    ad.dispose();
                                    _nativeAds.remove(index);
                                    if (!mounted) return;
                                    setState(() {
                                      _nativeAdFailed[index] = true;
                                    });
                                  },
                                ),
                                nativeTemplateStyle: NativeTemplateStyle(
                                  templateType: TemplateType.small,
                                ),
                              )..load();
                            }

                            if (_nativeAdFailed[index] == true) {
                              return const SizedBox.shrink();
                            }

                            if (_nativeAdLoaded[index] == true) {
                              return Container(
                                height: 120,
                                margin: const EdgeInsets.symmetric(
                                  horizontal: 16.0,
                                  vertical: 8.0,
                                ),
                                child: AdWidget(ad: _nativeAds[index]!),
                              );
                            } else {
                              return const SizedBox(
                                height: 120,
                                child: Center(
                                  child: CircularProgressIndicator(),
                                ),
                              );
                            }
                          }

                          return _buildEventCard(events[eventIndex]);
                        },
                      ),
                    ),
                    KeepAlivePage(
                      child: TimelineView(
                        events: events,
                        abbreviations: abbreviationsMap,
                        buildEventCard: _buildEventCard,
                        userCustomGames: _userCustomGames,
                      ),
                    ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _EventCardItem extends StatefulWidget {
  final ParsedEvent parsedEvent;
  final Map<String, dynamic> eventData;
  final String eventGameName;
  final String title;
  final String? tag;
  final String? subTag;
  final String? redeemCode;
  final String? eventUrl;
  final String? startDateStr;
  final String? endDateStr;
  final String startDisplay;
  final String endDisplay;
  final String period;
  final String summary;
  final String? imageUrl;
  final List<String> rewards;
  final DateTime? startDate;
  final DateTime? endDate;
  final String? gameCodeUrl;
  final bool hasValidCodeUrl;
  final Widget? trailingWidget;
  final String eventId;
  final bool isCycleEvent;
  final bool eventIsCompletedDoc;
  final bool isChecked;
  final Color tagColor;
  final bool isDarkMode;
  final String dateStr;
  final Future<void> Function() onCheckedToggle;
  final bool isPremium;

  const _EventCardItem({
    super.key,
    required this.parsedEvent,
    required this.eventData,
    required this.eventGameName,
    required this.title,
    required this.tag,
    required this.subTag,
    required this.redeemCode,
    required this.eventUrl,
    required this.startDateStr,
    required this.endDateStr,
    required this.startDisplay,
    required this.endDisplay,
    required this.period,
    required this.summary,
    required this.imageUrl,
    required this.rewards,
    required this.startDate,
    required this.endDate,
    required this.gameCodeUrl,
    required this.hasValidCodeUrl,
    required this.trailingWidget,
    required this.eventId,
    required this.isCycleEvent,
    required this.eventIsCompletedDoc,
    required this.isChecked,
    required this.tagColor,
    required this.isDarkMode,
    required this.dateStr,
    required this.onCheckedToggle,
    required this.isPremium,
  });

  @override
  State<_EventCardItem> createState() => _EventCardItemState();
}

class _EventCardItemState extends State<_EventCardItem> {
  bool _isEditing = false;
  late TextEditingController _gameNameController;
  late TextEditingController _titleController;
  late TextEditingController _summaryController;
  late TextEditingController _redeemCodeController;
  late TextEditingController _startDateController;
  late TextEditingController _endDateController;
  late TextEditingController _eventUrlController;
  String? _selectedTag;
  String? _selectedSubTag;
  bool _isUpdateLocked = false;
  bool _isHistoryExpanded = false;
  late bool _localIsChecked;

  @override
  void initState() {
    super.initState();
    _localIsChecked = widget.isChecked;
    _initEditFields();
  }

  @override
  void didUpdateWidget(covariant _EventCardItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isChecked != widget.isChecked) {
      _localIsChecked = widget.isChecked;
    }

    if (!_isEditing) {
      _gameNameController.text = widget.parsedEvent.gameName;
      _titleController.text = widget.parsedEvent.data['title'] ?? widget.title;
      _summaryController.text =
          widget.parsedEvent.data['summary'] ?? widget.summary;
      _redeemCodeController.text = widget.redeemCode ?? '';
      _startDateController.text = widget.startDate != null
          ? DateFormat('yyyy-MM-dd HH:mm').format(widget.startDate!)
          : '';
      _endDateController.text = widget.endDate != null
          ? DateFormat('yyyy-MM-dd HH:mm').format(widget.endDate!)
          : '';
      _eventUrlController.text = widget.eventUrl ?? '';
    }
  }

  void _initEditFields() {
    _gameNameController = TextEditingController(
      text: widget.parsedEvent.gameName,
    );
    _titleController = TextEditingController(
      text: widget.parsedEvent.data['title'] ?? widget.title,
    );
    _summaryController = TextEditingController(
      text: widget.parsedEvent.data['summary'] ?? widget.summary,
    );
    _redeemCodeController = TextEditingController(
      text: widget.redeemCode ?? '',
    );
    _startDateController = TextEditingController(
      text: widget.startDate != null
          ? DateFormat('yyyy-MM-dd HH:mm').format(widget.startDate!)
          : '',
    );
    _endDateController = TextEditingController(
      text: widget.endDate != null
          ? DateFormat('yyyy-MM-dd HH:mm').format(widget.endDate!)
          : '',
    );
    _eventUrlController = TextEditingController(text: widget.eventUrl ?? '');
    _selectedTag = widget.tag;
    _selectedSubTag = widget.subTag;
    _isUpdateLocked = widget.eventData['isUpdateLocked'] == true;
  }

  @override
  void dispose() {
    _gameNameController.dispose();
    _titleController.dispose();
    _summaryController.dispose();
    _redeemCodeController.dispose();
    _startDateController.dispose();
    _endDateController.dispose();
    _eventUrlController.dispose();
    super.dispose();
  }

  Future<void> _saveChanges() async {
    Timestamp? parseDate(String text, String fieldName) {
      if (text.isEmpty) return null;
      final parsed = DateTime.tryParse(text.replaceAll('/', '-'));
      if (parsed == null) {
        throw FormatException(
          '$fieldNameのフォーマットが正しくありません。(例: 2024-01-01 12:00)',
        );
      }
      return Timestamp.fromDate(parsed);
    }

    Map<String, dynamic> updateData;
    try {
      updateData = {
        'gameName': _gameNameController.text,
        'title': _titleController.text,
        'summary': _summaryController.text,
        'redeemCode': _redeemCodeController.text,
        'startDate': parseDate(_startDateController.text, '開始日時'),
        'endDate': parseDate(_endDateController.text, '終了日時'),
        'eventUrl': _eventUrlController.text,
        'tag': _selectedTag,
        'subTag': _selectedSubTag,
        'isUpdateLocked': _isUpdateLocked,
        'updatedAt': FieldValue.serverTimestamp(),
      };
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString().replaceAll('FormatException: ', '')),
        ),
      );
      return;
    }

    try {
      await widget.parsedEvent.doc.reference.update(updateData);
      await WidgetSyncService.syncTop5Events(throwError: true);
      if (!mounted) return;
      setState(() {
        _isEditing = false;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save changes: $e')));
    }
  }

  Future<void> _deleteEvent() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('削除確認'),
          content: const Text('本当に該当イベントを削除してよろしいですか？\n(論理削除されます)'),
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
        );
      },
    );

    if (confirm == true) {
      try {
        await widget.parsedEvent.doc.reference.update({
          'isDeleted': true,
          'isCreationLocked': true,
          'updatedAt': FieldValue.serverTimestamp(),
        });
        await WidgetSyncService.syncTop5Events(throwError: true);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to delete event: $e')));
      }
    }
  }

  Widget _buildRewardsSection() {
    final theme = Theme.of(context);
    final accentColor = theme.colorScheme.primary.withValues(alpha: 0.08);
    final borderColor = theme.colorScheme.primary.withValues(alpha: 0.2);

    Widget content = Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: accentColor,
        border: Border.all(color: borderColor, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.card_giftcard, size: 14, color: theme.colorScheme.primary),
              const SizedBox(width: 4),
              Text(
                'イベント報酬',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: widget.rewards.map((reward) {
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: theme.dividerColor.withValues(alpha: 0.5), width: 0.5),
                ),
                child: Text(
                  reward,
                  style: TextStyle(
                    fontSize: 11,
                    color: _localIsChecked ? Colors.grey : null,
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );

    if (!widget.isPremium) {
      return Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
              child: content,
            ),
          ),
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: theme.scaffoldBackgroundColor.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.lock, size: 20, color: Colors.grey),
                  const SizedBox(height: 4),
                  Text(
                    '報酬の詳細を見るには',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: theme.textTheme.bodyMedium?.color,
                    ),
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () {
                      Navigator.pushNamed(context, '/settings');
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'プレミアム登録',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return content;
  }

  @override
  Widget build(BuildContext context) {
    if (_isEditing) {
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _gameNameController,
                decoration: const InputDecoration(
                  labelText: 'ゲーム名',
                  isDense: true,
                ),
              ),
              TextField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'イベント名',
                  isDense: true,
                ),
              ),
              DropdownButtonFormField<String>(
                initialValue: ['ゲーム内', 'ゲーム外', 'コード'].contains(_selectedTag)
                    ? _selectedTag
                    : null,
                items: ['ゲーム内', 'ゲーム外', 'コード']
                    .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                    .toList(),
                onChanged: (val) => setState(() => _selectedTag = val),
                decoration: const InputDecoration(
                  labelText: 'タグ',
                  isDense: true,
                ),
              ),
              TextField(
                controller: _summaryController,
                decoration: const InputDecoration(
                  labelText: '詳細',
                  isDense: true,
                ),
                maxLines: 2,
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _startDateController,
                      decoration: const InputDecoration(
                        labelText: '開始',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _endDateController,
                      decoration: const InputDecoration(
                        labelText: '終了',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              TextField(
                controller: _redeemCodeController,
                decoration: const InputDecoration(
                  labelText: 'シリアルコード',
                  isDense: true,
                ),
              ),
              TextField(
                controller: _eventUrlController,
                decoration: const InputDecoration(
                  labelText: 'URL',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('更新ロック:'),
                      Switch(
                        value: _isUpdateLocked,
                        onChanged: (val) =>
                            setState(() => _isUpdateLocked = val),
                      ),
                    ],
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _isEditing = false;
                            _initEditFields();
                          });
                        },
                        child: const Text('キャンセル'),
                      ),
                      ElevatedButton(
                        onPressed: _saveChanges,
                        child: const Text('保存'),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final bool showAutoFillButton =
        widget.tag == 'コード' &&
        widget.redeemCode != null &&
        widget.redeemCode!.isNotEmpty;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      color: _localIsChecked
          ? (widget.isDarkMode ? Colors.grey[850] : Colors.grey.shade200)
          : null,
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(right: showAutoFillButton ? 75.0 : 0.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                InkWell(
                  onTap: _localIsChecked
                      ? null
                      : () async {
                          if (widget.tag == 'コード') {
                            final codeToCopy =
                                (widget.redeemCode != null &&
                                    widget.redeemCode!.isNotEmpty)
                                ? widget.redeemCode!
                                : widget.title;
                            await Clipboard.setData(
                              ClipboardData(text: codeToCopy),
                            );
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('コードをコピーしました')),
                              );
                            }
                          } else {
                            final query =
                                '${widget.eventGameName} ${widget.title}';
                            final encodedQuery = Uri.encodeComponent(query);
                            final uri = Uri.parse(
                              'https://www.google.com/search?q=$encodedQuery',
                            );
                            if (await canLaunchUrl(uri)) {
                              await launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              );
                            } else {
                              if (!context.mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Could not launch URL'),
                                ),
                              );
                            }
                          }
                        },
                  onLongPress: () async {
                    setState(() {
                      _localIsChecked = !_localIsChecked;
                    });
                    await widget.onCheckedToggle(); // 親の状態もバックグラウンドで更新
                  },
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      if (widget.imageUrl != null &&
                                          widget.imageUrl!.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 8.0,
                                          ),
                                          child: SizedBox(
                                            width: 50,
                                            height: 50,
                                            child: Image.network(
                                              widget.imageUrl!,
                                              fit: BoxFit.cover,
                                              errorBuilder:
                                                  (
                                                    context,
                                                    error,
                                                    stackTrace,
                                                  ) => const Icon(
                                                    Icons.image_not_supported,
                                                  ),
                                            ),
                                          ),
                                        ),
                                      Text(
                                        widget.eventGameName,
                                        style: TextStyle(
                                          fontSize: 14,
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.onSurface,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      if (widget.dateStr.isNotEmpty)
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 2.0,
                                            bottom: 4.0,
                                          ),
                                          child: Text(
                                            '更新日:${widget.dateStr}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                if (widget.trailingWidget != null) ...[
                                  const SizedBox(width: 8),
                                  _localIsChecked
                                      ? Opacity(
                                          opacity: 0.5,
                                          child: widget.trailingWidget,
                                        )
                                      : widget.trailingWidget!,
                                ],
                              ],
                            ),
                            const SizedBox(height: 8),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  spacing: 6.0,
                                  children: [
                                    if (widget.tag != null &&
                                        widget.tag!.isNotEmpty)
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: widget.tagColor.withAlpha(26),
                                          border: Border.all(
                                            color: widget.tagColor,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          widget.tag!,
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: widget.tagColor,
                                          ),
                                        ),
                                      ),
                                    if (widget.subTag != null &&
                                        widget.subTag!.isNotEmpty)
                                      Text(
                                        widget.subTag!,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey,
                                        ),
                                      ),
                                    Text(
                                      widget.title,
                                      style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        decoration: _localIsChecked
                                            ? TextDecoration.lineThrough
                                            : null,
                                        color: _localIsChecked
                                            ? Colors.grey
                                            : null,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  widget.period,
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: _localIsChecked
                                        ? Colors.grey
                                        : Colors.blueGrey,
                                  ),
                                ),
                                if (widget.summary.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    widget.summary,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: _localIsChecked
                                          ? Colors.grey
                                          : null,
                                    ),
                                  ),
                                ],
                                if (widget.rewards.isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  _buildRewardsSection(),
                                ],
                                if (widget.isCycleEvent &&
                                    widget.eventData['tasks'] != null &&
                                    (widget.eventData['tasks'] as List)
                                        .isNotEmpty) ...[
                                  const SizedBox(height: 8),
                                  GridView.builder(
                                    shrinkWrap: true,
                                    physics: const NeverScrollableScrollPhysics(),
                                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: 2,
                                      mainAxisExtent: 40,
                                      crossAxisSpacing: 8,
                                      mainAxisSpacing: 0,
                                    ),
                                    itemCount: (widget.eventData['tasks'] as List).length,
                                    itemBuilder: (context, taskIndex) {
                                      final task = (widget.eventData['tasks'] as List)[taskIndex] as Map<String, dynamic>;
                                      final taskName = task['name'] ?? '';
                                      final isTaskCompleted = task['isCompleted'] == true;

                                      return Row(
                                        children: [
                                          SizedBox(
                                            width: 24,
                                            child: Checkbox(
                                              visualDensity: VisualDensity.compact,
                                              value: isTaskCompleted,
                                              onChanged: (bool? value) async {
                                                if (value == null) return;

                                                final updatedTasks =
                                                    (widget.eventData['tasks'] as List)
                                                        .map((t) => Map<String, dynamic>.from(t))
                                                        .toList();
                                                updatedTasks[taskIndex]['isCompleted'] = value;

                                                setState(() {
                                                  widget.eventData['tasks'] = updatedTasks;
                                                });

                                                final allCompleted = updatedTasks.every(
                                                  (t) => t['isCompleted'] == true,
                                                );

                                                await widget.parsedEvent.doc.reference.update({
                                                  'tasks': updatedTasks,
                                                  'isCompleted': allCompleted,
                                                });

                                                try {
                                                  await WidgetSyncService.syncTop5Events(
                                                    excludedIds: allCompleted
                                                        ? [widget.parsedEvent.doc.id]
                                                        : [],
                                                    throwError: true,
                                                  );
                                                } catch (e) {
                                                  debugPrint('WidgetSync Error: $e');
                                                  FirebaseFirestore.instanceFor(
                                                    app: Firebase.app(),
                                                    databaseId: 'default',
                                                  ).collection('debug_logs').add({
                                                    'error': e.toString(),
                                                    'timestamp': FieldValue.serverTimestamp(),
                                                  });
                                                  if (!context.mounted) return;
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(content: Text('ウィジェットの更新に失敗しました: $e')),
                                                  );
                                                }
                                              },
                                            ),
                                          ),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              taskName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                decoration: isTaskCompleted
                                                    ? TextDecoration.lineThrough
                                                    : null,
                                                color: isTaskCompleted
                                                    ? Colors.grey
                                                    : null,
                                              ),
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (_localIsChecked)
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
                Padding(
                  padding: const EdgeInsets.only(
                    left: 12.0,
                    bottom: 8.0,
                    right: 8.0,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (const bool.fromEnvironment(
                                  'IS_ADMIN',
                                  defaultValue: false,
                                ) &&
                                !_localIsChecked &&
                                !_isEditing)
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  TextButton(
                                    onPressed: () {
                                      setState(() {
                                        _isHistoryExpanded =
                                            !_isHistoryExpanded;
                                      });
                                    },
                                    style: TextButton.styleFrom(
                                      padding: EdgeInsets.zero,
                                      minimumSize: const Size(0, 0),
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    child: Text(
                                      _isHistoryExpanded
                                          ? '▲ 更新履歴を閉じる'
                                          : '▼ 更新履歴',
                                      style: const TextStyle(
                                        fontSize: 12,
                                        color: Colors.blueGrey,
                                      ),
                                    ),
                                  ),
                                  if (_isHistoryExpanded)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8.0),
                                      child: Builder(
                                        builder: (context) {
                                          final dynamic historyData =
                                              widget.eventData['updateHistory'];
                                          List<String> historyList = [];
                                          if (historyData is List) {
                                            historyList = historyData
                                                .map((e) => e?.toString() ?? '')
                                                .where(
                                                  (e) =>
                                                      e.isNotEmpty &&
                                                      !e.contains('変更あり（概要）'),
                                                )
                                                .toList();
                                          }

                                          if (historyList.isEmpty) {
                                            return const Text(
                                              '更新履歴はありません',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey,
                                              ),
                                            );
                                          }

                                          return Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: historyList.reversed
                                                .take(5)
                                                .map(
                                                  (history) => Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          bottom: 4.0,
                                                        ),
                                                    child: Text(
                                                      history,
                                                      style: const TextStyle(
                                                        fontSize: 12,
                                                        color: Colors.grey,
                                                      ),
                                                    ),
                                                  ),
                                                )
                                                .toList(),
                                          );
                                        },
                                      ),
                                    ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (const bool.fromEnvironment(
                            'IS_ADMIN',
                            defaultValue: false,
                          ))
                            PopupMenuButton<String>(
                              padding: EdgeInsets.zero,
                              child: const Text(
                                '管理者メニュー',
                                style: TextStyle(
                                  color: Colors.blue,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              onSelected: (String result) {
                                if (result == 'edit') {
                                  setState(() {
                                    _isEditing = true;
                                  });
                                } else if (result == 'delete') {
                                  _deleteEvent();
                                }
                              },
                              itemBuilder: (BuildContext context) =>
                                  <PopupMenuEntry<String>>[
                                    const PopupMenuItem<String>(
                                      value: 'edit',
                                      child: Text('イベント編集'),
                                    ),
                                    const PopupMenuItem<String>(
                                      value: 'delete',
                                      child: Text(
                                        'イベント削除',
                                        style: TextStyle(color: Colors.red),
                                      ),
                                    ),
                                  ],
                            ),
                          PopupMenuButton<String>(
                            padding: EdgeInsets.zero,
                            icon: const Icon(
                              Icons.more_vert,
                              size: 20,
                              color: Colors.grey,
                            ),
                            onSelected: (String result) {
                              if (result == 'report') {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => FeedbackScreen(
                                      initialTitle:
                                          '${widget.eventGameName}のイベント『${widget.title}』の情報に誤りがあります',
                                      initialTag: '誤情報',
                                      targetEventId: widget.parsedEvent.doc.id,
                                    ),
                                  ),
                                );
                              }
                            },
                            itemBuilder: (BuildContext context) =>
                                <PopupMenuEntry<String>>[
                                  const PopupMenuItem<String>(
                                    value: 'report',
                                    child: Text('誤情報報告'),
                                  ),
                                ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (showAutoFillButton)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 70,
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(12),
                    bottomRight: Radius.circular(12),
                  ),
                  color: _localIsChecked
                      ? Colors.grey.shade400
                      : (widget.hasValidCodeUrl
                            ? Theme.of(context).primaryColor
                            : Colors.blueGrey),
                ),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                    onTap: _localIsChecked
                        ? null
                        : () async {
                            final messenger = ScaffoldMessenger.of(context);
                            await Clipboard.setData(
                              ClipboardData(text: widget.redeemCode!),
                            );
                            messenger.showSnackBar(
                              const SnackBar(
                                content: Text('コードをコピーしました'),
                                duration: Duration(seconds: 1),
                              ),
                            );

                            if (widget.hasValidCodeUrl) {
                              final urlToLaunch = widget.gameCodeUrl!
                                  .replaceAll('（コード）', widget.redeemCode!)
                                  .replaceAll('(コード)', widget.redeemCode!);
                              final uri = Uri.parse(urlToLaunch);
                              if (await canLaunchUrl(uri)) {
                                await launchUrl(
                                  uri,
                                  mode: LaunchMode.externalApplication,
                                );
                              } else {
                                messenger.showSnackBar(
                                  const SnackBar(
                                    content: Text('Could not launch URL'),
                                  ),
                                );
                              }
                            }
                          },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4.0),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            widget.hasValidCodeUrl
                                ? Icons.open_in_browser
                                : Icons.copy,
                            color: Colors.white,
                            size: 16,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.hasValidCodeUrl ? '自動\n入力' : 'コピー',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
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
              ),
            ),
        ],
      ),
    );
  }
}
