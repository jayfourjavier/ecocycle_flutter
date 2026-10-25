// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ecocycle/main.dart';

void main() {
  testWidgets('Dashboard shows layout sections', (WidgetTester tester) async {
    await tester.pumpWidget(const EcoCycleApp());

    expect(find.text('ECOCYCLE'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Current Activity'), findsOneWidget);
    expect(find.text('Hopper Status'), findsOneWidget);
    expect(find.text('Food Waste'), findsOneWidget);
    expect(find.text('Loam Soil'), findsOneWidget);
    expect(find.text('Production Records'), findsOneWidget);

    // Toggle online/offline.
    await tester.tap(find.byIcon(Icons.sync));
    await tester.pump();
    expect(find.text('Offline'), findsOneWidget);
  });
}
