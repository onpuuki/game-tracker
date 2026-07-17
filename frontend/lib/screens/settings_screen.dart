import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import '../main.dart'; // Import themeNotifier
import 'feedback_screen.dart';
import 'premium_game_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _selectedTheme = 'system';
  bool _rotationLock = false;
  bool _isLoading = true;

  bool _notificationEnabled = false;
  int _notificationHour = 21;
  int _notificationDaysBefore = 7;
  bool _isPremium = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();

    // Load FCM settings from Firestore
    bool notificationEnabled = false;
    int notificationHour = 21;
    int notificationDaysBefore = 7;
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final doc = await FirebaseFirestore.instanceFor(
          app: Firebase.app(),
          databaseId: 'default',
        ).collection('users').doc(user.uid).get();

        if (doc.exists) {
          final data = doc.data();
          if (data != null) {
            if (data.containsKey('settings')) {
              final settings = data['settings'] as Map<String, dynamic>;
              notificationEnabled = settings['notificationEnabled'] ?? false;
              notificationHour = settings['notificationHour'] ?? 21;
              notificationDaysBefore = settings['notificationDaysBefore'] ?? 7;
            }
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
          }
        }
      } catch (e) {
        debugPrint('Error loading user settings: $e');
      }
    }

    setState(() {
      _selectedTheme = prefs.getString('theme') ?? 'system';
      _rotationLock = prefs.getBool('rotationLock') ?? false;
      _notificationEnabled = notificationEnabled;
      _notificationHour = notificationHour;
      _notificationDaysBefore = notificationDaysBefore;
      _isPremium = prefs.getBool('is_premium') ?? false;
      _isLoading = false;
    });
  }

  Future<void> _syncNotificationSettings() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        String? token;
        if (_notificationEnabled) {
          await FirebaseMessaging.instance.requestPermission();
          token = await FirebaseMessaging.instance.getToken();
        }

        final Map<String, dynamic> updateData = {
          'settings': {
            'notificationEnabled': _notificationEnabled,
            'notificationHour': _notificationHour,
            'notificationDaysBefore': _notificationDaysBefore,
          },
        };

        if (_notificationEnabled && token != null) {
          updateData['fcmToken'] = token;
        } else if (!_notificationEnabled) {
          updateData['fcmToken'] = FieldValue.delete();
        }

        await FirebaseFirestore.instanceFor(
              app: Firebase.app(),
              databaseId: 'default',
            )
            .collection('users')
            .doc(user.uid)
            .set(updateData, SetOptions(merge: true));
      } catch (e) {
        debugPrint('Error syncing user settings: $e');
      }
    }
  }

  Future<void> _updateNotificationEnabled(bool enabled) async {
    bool finalEnabled = enabled;
    if (enabled) {
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional) {
        finalEnabled = false;
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('通知の権限が拒否されました。設定から許可してください。')),
        );
      }
    }

    if (!mounted) return;
    setState(() {
      _notificationEnabled = finalEnabled;
    });
    await _syncNotificationSettings();
  }

  Future<void> _updateNotificationHour(int? hour) async {
    if (hour != null) {
      if (!mounted) return;
      setState(() {
        _notificationHour = hour;
      });
      await _syncNotificationSettings();
    }
  }

  Future<void> _updateTheme(String theme) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme', theme);
    setState(() {
      _selectedTheme = theme;
    });

    if (theme == 'light') {
      themeNotifier.value = ThemeMode.light;
    } else if (theme == 'dark') {
      themeNotifier.value = ThemeMode.dark;
    } else {
      themeNotifier.value = ThemeMode.system;
    }
  }

  Future<void> _updateRotationLock(bool lock) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('rotationLock', lock);
    setState(() {
      _rotationLock = lock;
    });

    if (lock) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else {
      SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('設定')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '外観',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'system', label: Text('システム設定')),
              ButtonSegment(value: 'light', label: Text('ライト')),
              ButtonSegment(value: 'dark', label: Text('ダーク')),
            ],
            selected: {_selectedTheme},
            onSelectionChanged: (Set<String> newSelection) {
              _updateTheme(newSelection.first);
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '通知設定',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          SwitchListTile(
            title: const Text('未完了イベントの通知を有効にする'),
            value: _notificationEnabled,
            onChanged: _updateNotificationEnabled,
          ),
          ListTile(
            title: const Text('期限の何日前に通知'),
            trailing: Text(
              _notificationDaysBefore == 0
                  ? '当日期限のみ'
                  : '$_notificationDaysBefore日前まで',
            ),
            onTap: _notificationEnabled
                ? () {
                    showModalBottomSheet(
                      context: context,
                      builder: (BuildContext builder) {
                        return SizedBox(
                          height: 250,
                          child: CupertinoPicker(
                            itemExtent: 32.0,
                            scrollController: FixedExtentScrollController(
                              initialItem: _notificationDaysBefore,
                            ),
                            onSelectedItemChanged: (int index) {
                              setState(() {
                                _notificationDaysBefore = index;
                              });
                            },
                            children: List<Widget>.generate(31, (int index) {
                              return Center(
                                child: Text(
                                  index == 0 ? '当日期限のみ' : '$index日前まで',
                                ),
                              );
                            }),
                          ),
                        );
                      },
                    ).whenComplete(() => _syncNotificationSettings());
                  }
                : null,
          ),
          ListTile(
            title: const Text('通知時間'),
            trailing: DropdownButton<int>(
              value: _notificationHour,
              items: List.generate(24, (index) {
                return DropdownMenuItem(value: index, child: Text('$index:00'));
              }),
              onChanged: _notificationEnabled ? _updateNotificationHour : null,
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '画面設定',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          SwitchListTile(
            title: const Text('画面を縦方向に固定する'),
            value: _rotationLock,
            onChanged: (value) {
              _updateRotationLock(value);
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'その他',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.feedback_outlined),
            title: const Text('フィードバックを送信'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const FeedbackScreen()),
              );
            },
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'プレミアムモード（月額150円）',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16.0),
            child: Text(
              '※ここにプレミアムモードの機能詳細やトライアル期間の説明が入ります。',
              style: TextStyle(fontSize: 14),
            ),
          ),
          if (_isPremium)
            ListTile(
              leading: const Icon(Icons.videogame_asset),
              title: const Text('イベント抽出ゲーム追加'),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const PremiumGameScreen(),
                  ),
                );
              },
            ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: ElevatedButton(
              onPressed: () async {
                const bool isAdmin = bool.fromEnvironment(
                  'IS_ADMIN',
                  defaultValue: false,
                );
                if (isAdmin) {
                  final prefs = await SharedPreferences.getInstance();
                  final newValue = !_isPremium;
                  await prefs.setBool('is_premium', newValue);

                  final user = FirebaseAuth.instance.currentUser;
                  if (user != null) {
                    await FirebaseFirestore.instanceFor(
                      app: Firebase.app(),
                      databaseId: 'default',
                    ).collection('users').doc(user.uid).set({
                      'isPremium': newValue,
                    }, SetOptions(merge: true));
                  }

                  setState(() {
                    _isPremium = newValue;
                  });
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        '管理者権限：プレミアムモードを${newValue ? '有効' : '無効'}にしました',
                      ),
                    ),
                  );
                } else {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('課金処理は準備中です')));
                }
              },
              child: Text(_isPremium ? 'プレミアムモードを終了する' : 'プレミアムモードを利用する'),
            ),
          ),
          const Divider(),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              '本アプリは非公式アプリです。各ゲームの画像や名称の著作権はそれぞれの権利者に帰属します。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}
