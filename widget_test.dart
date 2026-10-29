import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_tracker/main.dart';

void main() {
  setUpAll(() async {
    await AttendanceDatabase.initialize();
    appSettingsNotifier.value = await AttendanceDatabase.loadAppSettings();
  });

  testWidgets('Attendance Tracker opens', (WidgetTester tester) async {
    await tester.pumpWidget(const AttendanceApp());
    await tester.pumpAndSettle();

    expect(find.text('Attendance'), findsOneWidget);
    expect(find.text('Tracker ♡'), findsOneWidget);
  });
}
