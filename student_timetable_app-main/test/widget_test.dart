import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:student_timetable_app/main.dart';

void main() {
  testWidgets('Login screen renders correctly', (WidgetTester tester) async {
    await tester.pumpWidget(const StudentTimetableApp());

    expect(find.text('Student Timetable'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.byIcon(Icons.calendar_month), findsOneWidget);
  });
}
