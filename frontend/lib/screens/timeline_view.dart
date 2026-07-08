import 'package:flutter/material.dart';
import 'package:two_dimensional_scrollables/two_dimensional_scrollables.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'home_screen.dart' show ParsedEvent;

class TimelineView extends StatefulWidget {
  final List<ParsedEvent> events;
  final Widget Function(ParsedEvent) buildEventCard;

  const TimelineView({
    super.key,
    required this.events,
    required this.buildEventCard,
  });

  @override
  State<TimelineView> createState() => _TimelineViewState();
}

class _TimelineViewState extends State<TimelineView> {
  List<String> games = [];
  List<DateTime> hours = [];
  Map<String, Map<int, List<ParsedEvent>>> eventMap = {};
  Map<String, String> _abbreviations = {};
  bool _isLoadingAbbreviations = true;

  @override
  void initState() {
    super.initState();
    _fetchAbbreviations();
    _processEvents();
  }

  Future<void> _fetchAbbreviations() async {
    try {
      final doc =
          await FirebaseFirestore.instanceFor(
                app: Firebase.app(),
                databaseId: 'default',
              )
              .collection('settings')
              .doc('config')
              .get(const GetOptions(source: Source.server))
              .timeout(const Duration(seconds: 5))
              .catchError((_) {
                return FirebaseFirestore.instanceFor(
                      app: Firebase.app(),
                      databaseId: 'default',
                    )
                    .collection('settings')
                    .doc('config')
                    .get(const GetOptions(source: Source.cache));
              });

      if (doc.exists) {
        final data = doc.data();
        if (data != null && data.containsKey('targets')) {
          final targets = data['targets'] as List<dynamic>;
          final abbrevs = <String, String>{};
          for (var target in targets) {
            if (target is Map<String, dynamic> &&
                target.containsKey('gameName')) {
              final gameName = target['gameName'] as String;
              final abbrev = (target['abbreviation'] as String?) ?? '';
              abbrevs[gameName] = abbrev;
            }
          }
          if (mounted) {
            setState(() {
              _abbreviations = abbrevs;
            });
          }
        }
      }
    } catch (e) {
      // Failed to load abbreviations, use defaults
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingAbbreviations = false;
        });
      }
    }
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

    DateTime now = DateTime.now();
    DateTime startHour = DateTime(now.year, now.month, now.day, now.hour);
    // 3 days ahead
    DateTime endHour = startHour.add(const Duration(days: 3));

    hours = [];
    DateTime current = startHour;
    while (current.isBefore(endHour) || current.isAtSameMomentAs(endHour)) {
      hours.add(current);
      current = current.add(const Duration(hours: 1));
    }

    eventMap = {};
    for (var game in games) {
      eventMap[game] = {};
      for (int i = 0; i < hours.length; i++) {
        eventMap[game]![i] = [];
      }
    }

    for (var event in widget.events) {
      if (event.endDate == null) continue;

      String gameName = event.gameName;
      DateTime endDate = event.endDate!;

      // Find the slot
      for (int i = 0; i < hours.length; i++) {
        DateTime slotStart = hours[i];
        DateTime slotEnd = slotStart.add(const Duration(hours: 1));

        // If end date falls in this hour slot
        if ((endDate.isAfter(slotStart) ||
                endDate.isAtSameMomentAs(slotStart)) &&
            endDate.isBefore(slotEnd)) {
          if (eventMap.containsKey(gameName)) {
            eventMap[gameName]![i]!.add(event);
          }
          break;
        }
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
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$gameName - ${hour.month}/${hour.day} ${hour.hour}:00',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              ListView.builder(
                shrinkWrap: true,
                itemCount: cellEvents.length,
                itemBuilder: (context, index) {
                  final ev = cellEvents[index];
                  return widget.buildEventCard(ev);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingAbbreviations) {
      return const Center(child: CircularProgressIndicator());
    }

    if (games.isEmpty || hours.isEmpty) {
      return const Center(child: Text('タイムラインデータがありません'));
    }

    return TableView.builder(
      pinnedColumnCount: 1,
      pinnedRowCount: 1,
      columnCount: games.length + 1,
      rowCount: hours.length + 1,
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
          String abbrev = _abbreviations[gameName] ?? '';
          if (abbrev.isEmpty) {
            abbrev = gameName.substring(
              0,
              gameName.length < 3 ? gameName.length : 3,
            );
          }
          return TableViewCell(
            child: Center(
              child: Text(
                abbrev.split('').join('\n'),
                style: const TextStyle(fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          );
        } else if (vicinity.column == 0) {
          final h = hours[vicinity.row - 1];
          return TableViewCell(
            child: Center(
              child: Text(
                '${h.month}/${h.day} ${h.hour.toString().padLeft(2, '0')}:00',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.visible,
              ),
            ),
          );
        }

        final gameName = games[vicinity.column - 1];
        final hIndex = vicinity.row - 1;
        final cellEvents = eventMap[gameName]?[hIndex] ?? [];

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
                _showEventDetails(context, gameName, hours[hIndex], cellEvents),
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
    return const TableSpan(extent: FixedTableSpanExtent(45.0));
  }
}
