import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart'; // Import themeNotifier

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _selectedTheme = 'system';
  bool _rotationLock = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _selectedTheme = prefs.getString('theme') ?? 'system';
      _rotationLock = prefs.getBool('rotationLock') ?? false;
      _isLoading = false;
    });
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
        ],
      ),
    );
  }
}
