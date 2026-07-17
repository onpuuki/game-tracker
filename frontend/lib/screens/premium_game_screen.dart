import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

class PremiumGameScreen extends StatefulWidget {
  const PremiumGameScreen({super.key});

  @override
  State<PremiumGameScreen> createState() => _PremiumGameScreenState();
}

class _PremiumGameScreenState extends State<PremiumGameScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;
  bool _isAdding = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('イベント抽出ゲーム追加'),
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'イベント抽出対象に加えるゲーム名を選択してください（最大3件）。\n※大手攻略メディアに情報がないタイトルの場合、イベントが抽出されないことがあります。まずは無料トライアル期間を利用して、対象ゲームの抽出が行われるかお試しください。\n※ゲームイベントの自動検索は毎日3:00〜5:00にかけて行われるため、イベントの初回表示は翌日以降になります。',
              style: TextStyle(fontSize: 14),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      hintText: 'ゲーム名を入力',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _searchGames(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isSearching ? null : _searchGames,
                  child: _isSearching
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('検索'),
                ),
              ],
            ),
          ),
          const Divider(height: 32),
          Expanded(
            child: _buildCustomGamesList(),
          ),
        ],
      ),
    );
  }

  Future<void> _searchGames() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    if (_isSearching) return;

    if (!mounted) return;
    setState(() {
      _isSearching = true;
    });

    try {
      final callable = FirebaseFunctions.instanceFor(region: 'asia-northeast1').httpsCallable('searchIGDBGames');
      final result = await callable.call({'query': query});

      if (!mounted) return;

      if (result.data != null && result.data['success'] == true) {
         final List<dynamic> games = result.data['games'] ?? [];
         final List<String> gameNames = [];

         for (var g in games) {
           final name = g['name'] as String;
           if (g.containsKey('first_release_date')) {
             final timestamp = g['first_release_date'] as int;
             final date = DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);
             gameNames.add('$name (${date.year})');
           } else {
             gameNames.add(name);
           }
         }

         if (gameNames.isEmpty) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('ゲームが見つかりませんでした。')),
           );
         } else {
           _showSearchResultsDialog(gameNames);
         }
      } else {
         ScaffoldMessenger.of(context).showSnackBar(
           SnackBar(content: Text(result.data?['message']?.toString() ?? '検索に失敗しました')),
         );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エラーが発生しました: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  void _showSearchResultsDialog(List<String> gameNames) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('検索結果'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: gameNames.length,
              itemBuilder: (context, index) {
                final gameName = gameNames[index];
                return ListTile(
                  title: Text(gameName),
                  onTap: () {
                    Navigator.pop(context);
                    _addGame(gameName);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('キャンセル'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _addGame(String gameName) async {
    if (_isAdding) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    setState(() {
      _isAdding = true;
    });

    try {
      final docRef = FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'default').collection('users').doc(user.uid);
      final docSnap = await docRef.get();

      if (docSnap.exists) {
        final data = docSnap.data() as Map<String, dynamic>;
        final customGames = List<String>.from(data['customGames'] ?? []);

        if (customGames.length >= 3) {
          if (!mounted) return;
          showDialog(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('エラー'),
              content: const Text('登録できるゲームは最大3件までです。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('OK'),
                ),
              ],
            ),
          );
          return;
        }

        if (customGames.contains(gameName)) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('すでに登録されています。')),
          );
          return;
        }
      }

      await docRef.set({
        'customGames': FieldValue.arrayUnion([gameName]),
      }, SetOptions(merge: true));

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ゲームを追加しました。')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('追加エラー: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isAdding = false;
        });
      }
    }
  }

  Future<void> _removeGame(String gameName) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('確認'),
        content: const Text('本当に削除してよろしいですか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('OK', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'default').collection('users').doc(user.uid).update({
        'customGames': FieldValue.arrayRemove([gameName]),
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('ゲームを削除しました。')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('削除エラー: $e')),
      );
    }
  }

  Widget _buildCustomGamesList() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return const Center(child: Text('ログインが必要です'));
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'default').collection('users').doc(user.uid).snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('エラーが発生しました'));
        }

        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const Center(child: Text('登録されたゲームがありません'));
        }

        final data = snapshot.data!.data() as Map<String, dynamic>?;
        if (data == null || !data.containsKey('customGames')) {
          return const Center(child: Text('登録されたゲームがありません'));
        }

        final customGames = List<String>.from(data['customGames']);

        if (customGames.isEmpty) {
          return const Center(child: Text('登録されたゲームがありません'));
        }

        return ListView.builder(
          itemCount: customGames.length,
          itemBuilder: (context, index) {
            final gameName = customGames[index];
            return ListTile(
              title: Text(gameName),
              trailing: IconButton(
                icon: const Icon(Icons.delete, color: Colors.grey),
                onPressed: () => _removeGame(gameName),
              ),
            );
          },
        );
      },
    );
  }
}
