with open('frontend/lib/screens/home_screen.dart', 'r') as f:
    content = f.read()

# 1. Add List<QueryDocumentSnapshot>? _currentEvents;
content = content.replace(
    'late Stream<DocumentSnapshot> _configStream;',
    'late Stream<DocumentSnapshot> _configStream;\n  List<QueryDocumentSnapshot>? _currentEvents;'
)

# 2. Remove _eventsStreamController and its references
content = content.replace(
    'StreamController<List<QueryDocumentSnapshot>>? _eventsStreamController;\n',
    ''
)

content = content.replace(
    '_eventsStreamController?.close();\n    _eventsStreamController = StreamController<List<QueryDocumentSnapshot>>.broadcast();',
    ''
)

content = content.replace(
    '_eventsStreamController?.close();\n',
    ''
)

content = content.replace(
    '_eventsStreamController?.addError(e);',
    "debugPrint('Error loading events: $e');"
)

# 3. Modify _emitEvents
old_emit = '''  void _emitEvents() {
    if (_eventsStreamController?.isClosed == true) return;
    final List<QueryDocumentSnapshot> allDocs = [];
    for (final docs in _eventSnapshotsMap.values) {
      allDocs.addAll(docs);
    }
    _eventsStreamController?.add(allDocs);
  }'''

new_emit = '''  void _emitEvents() {
    final List<QueryDocumentSnapshot> allDocs = [];
    for (final docs in _eventSnapshotsMap.values) {
      allDocs.addAll(docs);
    }
    if (mounted) {
      setState(() {
        _currentEvents = allDocs;
      });
    }
  }'''

content = content.replace(old_emit, new_emit)

# 4. Remove StreamBuilder
old_stream_builder = '''            return StreamBuilder<List<QueryDocumentSnapshot>>(
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
                }'''

new_evaluation = '''            if (_currentEvents == null) {
              return const Center(child: CircularProgressIndicator());
            }

            final docs = _currentEvents!;

            if (docs.isEmpty) {
              return const Center(child: Text('No events found.'));
            }'''

content = content.replace(old_stream_builder, new_evaluation)

# Remove StreamBuilder closing brackets and parenthesis correctly
old_closing = '''                );
              },
            );'''
new_closing = '''                );'''
content = content.replace(old_closing, new_closing)


with open('frontend/lib/screens/home_screen.dart', 'w') as f:
    f.write(content)
