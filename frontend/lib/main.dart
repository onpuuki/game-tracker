import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'firebase_options.dart';
import 'screens/home_screen.dart';

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final themeStr = prefs.getString('theme');
  if (themeStr == 'light') {
    themeNotifier.value = ThemeMode.light;
  } else if (themeStr == 'dark') {
    themeNotifier.value = ThemeMode.dark;
  } else {
    themeNotifier.value = ThemeMode.system;
  }

  final rotationLock = prefs.getBool('rotationLock') ?? false;
  if (rotationLock) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  } else {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  runApp(const MyApp());
}

Future<void> _initializeFirebase() async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: 'default',
  ).settings = const Settings(
    persistenceEnabled: true,
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, ThemeMode currentMode, child) {
        return MaterialApp(
          title: 'マルチゲームタスク',
          themeMode: currentMode,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.deepPurple,
              brightness: Brightness.dark,
            ),
            useMaterial3: true,
          ),
          home: FutureBuilder(
            future: _initializeFirebase(),
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Scaffold(
                  body: Center(
                    child: Text(
                      'Failed to initialize Firebase:\n${snapshot.error}',
                      style: const TextStyle(color: Colors.red),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              if (snapshot.connectionState == ConnectionState.done) {
                return const HomeScreen();
              }
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            },
          ),
        );
      },
    );
  }
}
