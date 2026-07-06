import 'package:flutter/material.dart';

class GameSelectionScreen extends StatefulWidget {
  final List<String> allGames;
  final List<String> selectedGames;
  final Function(List<String>) onSelectionChanged;

  const GameSelectionScreen({
    super.key,
    required this.allGames,
    required this.selectedGames,
    required this.onSelectionChanged,
  });

  @override
  State<GameSelectionScreen> createState() => _GameSelectionScreenState();
}

class _GameSelectionScreenState extends State<GameSelectionScreen> {
  late List<String> _currentSelectedGames;

  @override
  void initState() {
    super.initState();
    _currentSelectedGames = List.from(widget.selectedGames);
  }

  void _selectAll() {
    setState(() {
      _currentSelectedGames = List.from(widget.allGames);
    });
    widget.onSelectionChanged(_currentSelectedGames);
  }

  void _clearAll() {
    setState(() {
      _currentSelectedGames = [];
    });
    widget.onSelectionChanged(_currentSelectedGames);
  }

  void _toggleGame(String game, bool? checked) {
    setState(() {
      if (checked == true) {
        if (!_currentSelectedGames.contains(game)) {
          _currentSelectedGames.add(game);
        }
      } else {
        _currentSelectedGames.remove(game);
      }
    });
    widget.onSelectionChanged(_currentSelectedGames);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ゲーム絞り込み')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: _selectAll,
                    child: const Text('すべて選択'),
                  ),
                ),
                const SizedBox(width: 8.0),
                Expanded(
                  child: TextButton(
                    onPressed: _clearAll,
                    child: const Text('すべて解除'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: widget.allGames.length,
              itemBuilder: (context, index) {
                final game = widget.allGames[index];
                return CheckboxListTile(
                  title: Text(game),
                  value: _currentSelectedGames.contains(game),
                  onChanged: (bool? checked) => _toggleGame(game, checked),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
