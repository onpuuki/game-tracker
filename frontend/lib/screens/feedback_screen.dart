import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

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
  bool _isSubmitting = false;

  final List<String> _tags = [
    '機能追加要望',
    'バグ報告',
    'イベント誤情報',
    'その他',
  ];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.initialTitle ?? '');
    _bodyController = TextEditingController();
    _selectedTag = widget.initialTag ?? _tags.first;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  Future<void> _submitFeedback() async {
    if (_bodyController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本文を入力してください。')),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;

      await FirebaseFirestore.instance.collection('feedbacks').add({
        'title': _titleController.text.trim(),
        'tag': _selectedTag,
        'body': _bodyController.text.trim(),
        'targetEventId': widget.targetEventId,
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'uid': uid,
      });

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('フィードバックを送信しました。ご協力ありがとうございます！')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('エラーが発生しました: $e')),
      );
      setState(() {
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('フィードバックを送信'),
      ),
      body: _isSubmitting
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
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
                    '要望タグ',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8.0,
                    runSpacing: 8.0,
                    children: _tags.map((tag) {
                      return ChoiceChip(
                        label: Text(tag),
                        selected: _selectedTag == tag,
                        onSelected: (selected) {
                          if (selected) {
                            setState(() {
                              _selectedTag = tag;
                            });
                          }
                        },
                      );
                    }).toList(),
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
                    onPressed: _submitFeedback,
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
