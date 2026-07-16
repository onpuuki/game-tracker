import 'package:flutter/material.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';
import 'home_screen.dart' show ParsedEvent;

class TimelineView extends StatefulWidget {
  final List<ParsedEvent> events;
  final Map<String, String> abbreviations;
  final Widget Function(ParsedEvent) buildEventCard;

  const TimelineView({
    super.key,
    required this.events,
    required this.abbreviations,
    required this.buildEventCard,
  });

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  List<String> games = [];
  List<DateTime?> displayRows = []; // hours を廃止し、ギャップ(null)を含む行データへ変更
  Map<String, Map<DateTime, List<ParsedEvent>>> eventMap =
      {}; // 内側のキーを int から DateTime に変更
  Map<String, bool> customGameMap = {};

  String _getShortCustomGameName(String fullName) {
    if (RegExp(r'^[a-zA-Z\s]+$').hasMatch(fullName)) {
      final words = fullName.split(' ').where((w) => w.isNotEmpty).toList();
      if (words.length == 1) {
        return words[0].substring(0, words[0].length < 4 ? words[0].length : 4).toUpperCase();
      } else {
        return words.map((w) => w[0]).take(4).join('').toUpperCase();
      }
    } else {
      if (fullName.length <= 4) {
        return fullName;
      } else {
        return '${fullName.substring(0, 4)}..';
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _processEvents();
  }

  @override
  void didUpdateWidget(TimelineView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.events != widget.events) {
      _processEvents();
    }
  }

  void _processEvents() {
    games = widget.events.map((e) => e.gameName).toSet().toList();
    games.sort();

    // イベントが存在する時間を一意に抽出
    Set<DateTime> uniqueHours = {};
    for (var event in widget.events) {
      if (event.endDate != null) {
        final d = event.endDate!;
        uniqueHours.add(DateTime(d.year, d.month, d.day, d.hour));
      }
    }

    List<DateTime> sortedHours = uniqueHours.toList()..sort();

    // 行データの構築（時間が1時間以上飛んでいる場合は null を挟む）
    displayRows = [];
    for (int i = 0; i < sortedHours.length; i++) {
      displayRows.add(sortedHours[i]);
      if (i < sortedHours.length - 1) {
        if (sortedHours[i + 1].difference(sortedHours[i]).inHours > 1) {
          displayRows.add(null); // 省略ギャップ
        }
      }
    }

    eventMap = {};
    customGameMap = {};
    for (var game in games) {
      eventMap[game] = {};
      customGameMap[game] = false;
    }

    // イベントの紐付け
    for (var event in widget.events) {
      if (event.data['isCustomGame'] == true) {
        customGameMap[event.gameName] = true;
      }
      if (event.endDate == null) continue;
      final d = event.endDate!;
      DateTime hourKey = DateTime(d.year, d.month, d.day, d.hour);

      if (eventMap[event.gameName] != null) {
        if (eventMap[event.gameName]![hourKey] == null) {
          eventMap[event.gameName]![hourKey] = [];
        }
        eventMap[event.gameName]![hourKey]!.add(event);
      }
    }
  }

  void _showEventDetails(
    BuildContext context,
    String gameName,
    DateTime hour,
    List<ParsedEvent> cellEvents,
  ) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Container(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text(
                    '$gameName - ${hour.month}/${hour.day} ${hour.hour}:00',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: cellEvents.length,
                    itemBuilder: (context, index) {
                      final ev = cellEvents[index];
                      return widget.buildEventCard(ev);
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (games.isEmpty || displayRows.isEmpty) {
      return const Center(child: Text('タイムラインデータがありません'));
    }

    return TableView.builder(
      pinnedColumnCount: 1,
      pinnedRowCount: 1,
      columnCount: games.length + 1,
      rowCount: displayRows.length + 1,
      columnBuilder: _buildColumnSpan,
      rowBuilder: _buildRowSpan,
      cellBuilder: (BuildContext context, TableVicinity vicinity) {
        if (vicinity.column == 0 && vicinity.row == 0) {
          return const TableViewCell(
            child: Center(
              child: Text(
                '時間/ゲーム',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
              ),
            ),
          );
        } else if (vicinity.row == 0) {
          final gameName = games[vicinity.column - 1];
          final isCustom = customGameMap[gameName] == true;
          String abbrev = '';

          if (isCustom) {
            final shortName = _getShortCustomGameName(gameName);
            abbrev = '👑\n${shortName.split('').join('\n')}';
          } else {
            abbrev = widget.abbreviations[gameName] ?? '';
            if (abbrev.isEmpty) {
              abbrev = gameName.substring(
                0,
                gameName.length < 3 ? gameName.length : 3,
              );
            }
            abbrev = abbrev.split('').join('\n');
          }

          return TableViewCell(
            child: Center(
              child: Text(
                abbrev,
                style: const TextStyle(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        if (vicinity.row > 0) {
          final rowData = displayRows[vicinity.row - 1];

          if (vicinity.column == 0) {
            if (rowData == null) {
              return const TableViewCell(
                child: Center(
                  child: Text(
                    '⋮',
                    style: TextStyle(
                      color: Colors.grey,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              );
            }
            return TableViewCell(
              child: Center(
                child: Text(
                  '${rowData.month}/${rowData.day} ${rowData.hour.toString().padLeft(2, '0')}:00',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.visible,
                ),
              ),
            );
          }

          final gameName = games[vicinity.column - 1];

          if (rowData == null) {
            return TableViewCell(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.grey.withAlpha(20),
                  border: Border(
                    left: BorderSide(color: Colors.grey.shade300),
                    right: BorderSide(color: Colors.grey.shade300),
                  ),
                ),
              ),
            );
          }

          final cellEvents = eventMap[gameName]?[rowData] ?? [];

          if (cellEvents.isEmpty) {
            return TableViewCell(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                ),
              ),
            );
          }

          DateTime now = DateTime.now();
          bool hasWarning = false;
          bool hasDanger = false;

          if (cellEvents.length >= 3) {
            hasDanger = true;
          } else {
            for (var ev in cellEvents) {
              if (ev.endDate != null &&
                  ev.endDate!.difference(now).inHours < 24) {
                hasWarning = true;
              }
            }
          }

          Color bgColor = Colors.blue.shade100;
          if (hasDanger) {
            bgColor = Colors.red.shade300;
          } else if (hasWarning) {
            bgColor = Colors.yellow.shade300;
          }

          return TableViewCell(
            child: InkWell(
              onTap: () =>
                  _showEventDetails(context, gameName, rowData, cellEvents),
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Center(
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: bgColor,
                    ),
                    child: Center(
                      child: Text(
                        cellEvents.length.toString(),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        }

        return const TableViewCell(child: SizedBox());
      },
    );
  }

  TableSpan _buildColumnSpan(int index) {
    if (index == 0) {
      return const TableSpan(extent: FixedTableSpanExtent(85.0));
    }
    return const TableSpan(extent: FixedTableSpanExtent(45.0));
  }

  TableSpan _buildRowSpan(int index) {
    if (index == 0) {
      return const TableSpan(extent: FixedTableSpanExtent(100.0));
    }
    if (displayRows[index - 1] == null) {
      return const TableSpan(extent: FixedTableSpanExtent(24.0)); // ギャップ行の高さ
    }
    return const TableSpan(extent: FixedTableSpanExtent(45.0)); // 通常行
  }
}
