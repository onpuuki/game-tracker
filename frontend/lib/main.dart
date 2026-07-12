import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'firebase_options.dart';
import 'screens/home_screen.dart';
import 'services/widget_sync_service.dart';

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  debugPrint('Handling a background message: ${message.messageId}');

  await WidgetSyncService.syncTop5Events();
}

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.system);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MobileAds.instance.initialize();

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

  runApp(const ProviderScope(child: MyApp()));
}

Future<void> _initializeFirebase() async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  FirebaseFirestore.instanceFor(
    app: Firebase.app(),
    databaseId: 'default',
  ).settings = const Settings(
    persistenceEnabled: true,
  );

  try {
    if (FirebaseAuth.instance.currentUser != null) {
      debugPrint(
        'Anonymous Login Success: ${FirebaseAuth.instance.currentUser!.uid}',
      );
    } else {
      final userCredential = await FirebaseAuth.instance.signInAnonymously();
      debugPrint('Anonymous Login Success: ${userCredential.user?.uid}');
    }

    // --- ここからRBAC(管理者権限)の自動付与処理を追加 ---
    const bool isAdminApp = bool.fromEnvironment(
      'IS_ADMIN',
      defaultValue: false,
    );
    if (isAdminApp) {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) {
        final idTokenResult = await user.getIdTokenResult();
        final isAdminClaim = idTokenResult.claims?['admin'] == true;

        if (!isAdminClaim) {
          debugPrint('Requesting admin role...');
          final callable = FirebaseFunctions.instanceFor(
            region: 'asia-northeast1',
          ).httpsCallable('setAdminRole');
          const adminSecret = String.fromEnvironment('ADMIN_SECRET');
          await callable.call({'secret': adminSecret});

          // クレーム付与後、強制的にトークンをリフレッシュして最新状態にする
          await user.getIdToken(true);
          debugPrint('Admin role granted and token refreshed.');
        } else {
          debugPrint('Already has admin role.');
        }
      }
    }
    // --- ここまで ---

    // FCM Permissions & Token registration
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      await FirebaseMessaging.instance.requestPermission();
      FirebaseMessaging.onBackgroundMessage(
        _firebaseMessagingBackgroundHandler,
      );

      final String? fcmToken = await FirebaseMessaging.instance.getToken();
      if (fcmToken != null) {
        await FirebaseFirestore.instanceFor(
          app: Firebase.app(),
          databaseId: 'default',
        ).collection('users').doc(user.uid).set({
          'fcmToken': fcmToken,
        }, SetOptions(merge: true));
      }

      FirebaseMessaging.instance.onTokenRefresh
          .listen((fcmToken) {
            FirebaseFirestore.instanceFor(
              app: Firebase.app(),
              databaseId: 'default',
            ).collection('users').doc(user.uid).set({
              'fcmToken': fcmToken,
            }, SetOptions(merge: true));
          })
          .onError((err) {
            debugPrint('Token Refresh Error: $err');
          });
    }
  } catch (e) {
    debugPrint('Failed to sign in anonymously: $e');
  }
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
