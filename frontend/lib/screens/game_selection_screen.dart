import 'package:flutter/material.dart';

class GameSelectionScreen extends StatefulWidget {
  final List<String> allGames;
  final List<String> selectedGames;
  final List<String> userCustomGames;
  final bool showOnlyCustomGames;
  final Function(List<String>) onSelectionChanged;
  final Function(bool) onToggleShowOnlyCustomGames;

  const GameSelectionScreen({
    super.key,
    required this.allGames,
    required this.selectedGames,
    required this.userCustomGames,
    required this.showOnlyCustomGames,
    required this.onSelectionChanged,
    required this.onToggleShowOnlyCustomGames,
  });

  @override
  State<GameSelectionScreen> createState() => _GameSelectionScreenState();
}

class _GameSelectionScreenState extends State<GameSelectionScreen> {
  late List<String> _currentSelectedGames;
  late bool _showOnlyCustomGames;
  late List<String> _displayGames;

  @override
  void initState() {
    super.initState();
    _currentSelectedGames = List.from(widget.selectedGames);
    _showOnlyCustomGames = widget.showOnlyCustomGames;

    final defaultGames = widget.allGames.where((g) => !widget.userCustomGames.contains(g)).toList();
    final customGames = widget.allGames.where((g) => widget.userCustomGames.contains(g)).toList();
    _displayGames = [...defaultGames, ...customGames];
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
              itemCount: _displayGames.length,
              itemBuilder: (context, index) {
                final game = _displayGames[index];
                final isCustom = widget.userCustomGames.contains(game);
                return CheckboxListTile(
                  title: Text(isCustom ? '👑 $game' : game),
                  value: _currentSelectedGames.contains(game),
                  onChanged: _showOnlyCustomGames
                      ? null
                      : (bool? checked) => _toggleGame(game, checked),
                );
              },
            ),
          ),
          const Divider(height: 1),
          SwitchListTile(
            title: const Text('👑 追加したゲームのイベントのみ'),
            value: _showOnlyCustomGames,
            onChanged: (bool value) {
              setState(() {
                _showOnlyCustomGames = value;
              });
              widget.onToggleShowOnlyCustomGames(value);
            },
          ),
        ],
      ),
    );
  }
}
