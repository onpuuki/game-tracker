import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/main.dart';
import 'package:frontend/screens/home_screen.dart';

void main() {
  testWidgets('HomeScreen smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));

    // Verify that the title is present.
    expect(find.text('Trigger Manual Scraping'), findsOneWidget);
  });
}
