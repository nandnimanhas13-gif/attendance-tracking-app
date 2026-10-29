Attendance Tracker - fixed source

1. Replace your project's lib/main.dart with the supplied lib/main.dart.
2. Replace test/widget_test.dart with the supplied test/widget_test.dart.
3. Ensure pubspec.yaml includes these dependencies (keep your existing versions if already installed):
   - path
   - sqflite
   - sqflite_common_ffi
4. From the project root, run:
   flutter pub get
   flutter analyze
   flutter test
   flutter run -d windows

The MyApp compatibility class fixes the analyzer error in the default Flutter test,
while the updated widget test checks the Attendance Tracker instead of Flutter's
original counter demo.
