import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'feedback_success_screen.dart';
import '../utils/debug_log_manager.dart';

class FeedbackScreen extends StatefulWidget {
  final String? initialTitle;
  final String? initialTag;
  final String? targetEventId;

  const FeedbackScreen({
    super.key,
    this.initialTitle,
    this.initialTag,
    this.targetEventId,
  });

  @override
  State<FeedbackScreen> createState() => _FeedbackScreenState();
}

class _FeedbackScreenState extends State<FeedbackScreen> {
  late TextEditingController _titleController;
  late TextEditingController _bodyController;
  String? _selectedTag;

  final List<String> _tags = ['要望', 'バグ', '誤情報', 'その他'];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle ?? '');
    _bodyController = TextEditingController();
    _bodyController.addListener(_onBodyChanged);
    _selectedTag = widget.initialTag;
  }

  void _onBodyChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.removeListener(_onBodyChanged);
    _bodyController.dispose();
    super.dispose();
  }

  void _submitFeedback() {
    if (_bodyController.text.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('本文を入力してください。')));
      return;
    }

    DebugLogManager().addLog('Submit started (fire-and-forget)');

    final uid = FirebaseAuth.instance.currentUser?.uid;

    FirebaseFirestore.instanceFor(app: Firebase.app(), databaseId: 'default')
        .collection('feedbacks')
        .add({
          'title': _titleController.text.trim(),
          'tag': _selectedTag,
          'body': _bodyController.text.trim(),
          'targetEventId': widget.targetEventId,
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
          'uid': uid,
        })
        .catchError((e) {
          DebugLogManager().addLog(
            'Error in background feedback submission: $e',
          );
          throw e;
        });

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const FeedbackSuccessScreen()),
    );
  }

  Widget _buildTagButton(String tag) {
    final isSelected = _selectedTag == tag;
    return SizedBox(
      height: 48,
      child: OutlinedButton(
        onPressed: () {
          setState(() {
            _selectedTag = tag;
          });
        },
        style: OutlinedButton.styleFrom(
          backgroundColor: isSelected
              ? Theme.of(context).colorScheme.primaryContainer
              : null,
          side: BorderSide(
            color: isSelected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.outline,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4),
        ),
        child: Text(
          tag,
          style: TextStyle(
            color: isSelected
                ? Theme.of(context).colorScheme.onPrimaryContainer
                : Theme.of(context).colorScheme.onSurface,
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('フィードバックを送信')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'タイトル (任意)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _titleController,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'タイトルを入力',
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'フィードバック内容(必須)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Column(
              children: [
                Row(
                  children: [
                    Expanded(child: _buildTagButton(_tags[0])),
                    const SizedBox(width: 8),
                    Expanded(child: _buildTagButton(_tags[1])),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(child: _buildTagButton(_tags[2])),
                    const SizedBox(width: 8),
                    Expanded(child: _buildTagButton(_tags[3])),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              '本文 (必須)',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _bodyController,
              maxLines: 8,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '具体的な内容をご記入ください',
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed:
                  (_selectedTag != null &&
                      _bodyController.text.trim().isNotEmpty)
                  ? _submitFeedback
                  : null,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
              child: const Text('送信', style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}
