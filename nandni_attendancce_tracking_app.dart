// ignore: file_names
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;

String _joinPath(String first, String second) {
  final separator = Platform.pathSeparator;
  final left = first.replaceAll(RegExp(r'[\\/]+$'), '');
  final right = second.replaceAll(RegExp(r'^[\\/]+'), '');
  if (left.isEmpty) return '$separator$right';
  return '$left$separator$right';
}

class AppSettings {
  final String studentName;
  final String rollNumber;
  final String course;
  final String section;
  final String academicSession;
  final bool darkMode;
  final String pastelTheme;
  final bool remindersEnabled;
  final int reminderHour;
  final int reminderMinute;
  final int warningPercentage;

  const AppSettings({
    this.studentName = '',
    this.rollNumber = '',
    this.course = 'CSE/DS/AI – 3rd Sem',
    this.section = 'B',
    this.academicSession = 'Jul–Dec 2026',
    this.darkMode = false,
    this.pastelTheme = 'pink',
    this.remindersEnabled = true,
    this.reminderHour = 17,
    this.reminderMinute = 0,
    this.warningPercentage = 75,
  });

  AppSettings copyWith({
    String? studentName,
    String? rollNumber,
    String? course,
    String? section,
    String? academicSession,
    bool? darkMode,
    String? pastelTheme,
    bool? remindersEnabled,
    int? reminderHour,
    int? reminderMinute,
    int? warningPercentage,
  }) {
    return AppSettings(
      studentName: studentName ?? this.studentName,
      rollNumber: rollNumber ?? this.rollNumber,
      course: course ?? this.course,
      section: section ?? this.section,
      academicSession: academicSession ?? this.academicSession,
      darkMode: darkMode ?? this.darkMode,
      pastelTheme: pastelTheme ?? this.pastelTheme,
      remindersEnabled: remindersEnabled ?? this.remindersEnabled,
      reminderHour: reminderHour ?? this.reminderHour,
      reminderMinute: reminderMinute ?? this.reminderMinute,
      warningPercentage: warningPercentage ?? this.warningPercentage,
    );
  }
}

final ValueNotifier<AppSettings> appSettingsNotifier =
    ValueNotifier<AppSettings>(const AppSettings());

Color _themeSeed(String theme) {
  switch (theme) {
    case 'bright':
      return const Color(0xFF7C5CFC);
    default:
      return const Color(0xFF7C5CFC);
  }
}

Future<void> _saveSettings(AppSettings settings) async {
  // Update the UI first. SQLite persistence continues in the background.
  appSettingsNotifier.value = settings;
  try {
    await AttendanceDatabase.saveAppSettings(settings);
  } catch (error, stackTrace) {
    debugPrint('[settings] save failed: $error');
    debugPrint('$stackTrace');
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await AttendanceDatabase.initialize();
    appSettingsNotifier.value = await AttendanceDatabase.loadAppSettings();
  } catch (error, stackTrace) {
    // Keep the UI from being stuck on the splash screen if DB startup fails.
    debugPrint('[startup] database initialization failed: $error');
    debugPrint('$stackTrace');
  }

  runApp(const AttendanceApp());
}

// ============================================================
// APP
// ============================================================

class AttendanceApp extends StatelessWidget {
  const AttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: appSettingsNotifier,
      builder: (context, settings, _) {
        final accent = _themeSeed(settings.pastelTheme);
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Attendance Tracker',
          themeMode: settings.darkMode ? ThemeMode.dark : ThemeMode.light,
          themeAnimationDuration: const Duration(milliseconds: 120),
          themeAnimationCurve: Curves.easeOut,
          theme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFFFFF9FC),
            colorScheme: ColorScheme.fromSeed(
              seedColor: accent,
              brightness: Brightness.light,
            ),
            fontFamily: 'Arial',
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            scaffoldBackgroundColor: const Color(0xFF17131A),
            colorScheme: ColorScheme.fromSeed(
              seedColor: accent,
              brightness: Brightness.dark,
            ),
            fontFamily: 'Arial',
          ),
          home: const AttendanceHome(),
        );
      },
    );
  }
}

// ============================================================
// COLORS
// ============================================================

class AppColors {
  // Keep these as compile-time constants because the existing UI uses them
  // MaterialApp's ColorScheme.
  static const pink = Color(0xFFE95493);
  static const lightPink = Color(0xFFFFE5F0);
  static const lavender = Color(0xFFEDE5FF);
  static const purple = Color(0xFF7660C8);
  static const blue = Color(0xFFE4F1FF);
  static const blueDark = Color(0xFF2864B7);
  static const mint = Color(0xFFE0F7EC);
  static const green = Color(0xFF28A879);
  static const peach = Color(0xFFFFEBD9);
  static const orange = Color(0xFFE68A32);
  static const yellow = Color(0xFFFFF3CC);
  static const text = Color(0xFF172554);
  static const grey = Color(0xFF6B7280);
}

int get attendanceWarningPercentage =>
    appSettingsNotifier.value.warningPercentage;

// ============================================================
// DATA MODELS
// ============================================================

enum StudentGroup { g1, g2 }

const Map<String, String> _attendanceSubjectIds = {
  'Data Structures & Algorithms': 'dsa',
  'Mathematics-III': 'mathematics_iii',
  'OOPS': 'oops',
  'Digital Electronics': 'digital_electronics',
  'AWS': 'aws',
  'AWS Lab': 'aws_lab',
  'Foundation Course in Humanities': 'humanities',
  'Life Skills': 'life_skills',
  'DSA Lab': 'dsa_lab',
  'OOPS Lab': 'oops_lab',
  'IT Workshop': 'it_workshop',
};

String _attendanceSubjectIdFor(String subject) {
  if (subject == 'IT Workshop / DSA Lab' || subject == 'it_workshop_dsa_lab') {
    return 'it_workshop';
  }
  return _attendanceSubjectIds[subject] ?? subject;
}

class AttendanceDatabase {
  static Database? _database;
  static const String _tableName = 'attendance';
  static const String _entriesTableName = 'attendance_entries';
  static int _eventSequence = 0;

  static Future<void> initialize() async {
    // FFI is only for desktop. Android/iOS use sqflite's normal factory.
    if (Platform.isWindows || Platform.isLinux) {
      ffi.sqfliteFfiInit();
      databaseFactory = ffi.databaseFactoryFfi;
    }

    final db = await database;
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_tableName (
        group_name TEXT NOT NULL,
        subject TEXT NOT NULL,
        attended INTEGER NOT NULL,
        total INTEGER NOT NULL,
        entries TEXT NOT NULL,
        PRIMARY KEY(group_name, subject)
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_entriesTableName (
        id TEXT PRIMARY KEY,
        group_name TEXT NOT NULL,
        subject TEXT NOT NULL,
        status INTEGER NOT NULL,
        event_date TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
    await _migrateCombinedWorkshopRecords(db);
    await _migrateLegacyEntries(db);

    final rows = await db.query(_tableName);
    if (rows.isEmpty) {
      final defaults = {
        StudentGroup.g1: _defaultAttendanceRecords(),
        StudentGroup.g2: {
          for (final entry in _defaultAttendanceRecords().entries)
            entry.key: entry.value.copy(),
        },
      };
      await saveGroupRecords(defaults);
    }
  }

  static Future<void> _migrateCombinedWorkshopRecords(Database db) async {
    await db.transaction((txn) async {
      final legacyRows = await txn.query(
        _tableName,
        where: 'subject IN (?, ?)',
        whereArgs: ['IT Workshop / DSA Lab', 'it_workshop_dsa_lab'],
      );

      for (final row in legacyRows) {
        final groupName = row['group_name'] as String;
        final canonicalRows = await txn.query(
          _tableName,
          columns: ['subject'],
          where: 'group_name = ? AND subject = ?',
          whereArgs: [groupName, 'it_workshop'],
          limit: 1,
        );

        if (canonicalRows.isEmpty) {
          await txn.update(
            _tableName,
            {'subject': 'it_workshop'},
            where: 'group_name = ? AND subject = ?',
            whereArgs: [groupName, row['subject']],
          );
        }
      }
    });
  }

  static Future<void> _migrateLegacyEntries(Database db) async {
    final existingEvents = await db.query(
      _entriesTableName,
      columns: ['id'],
      limit: 1,
    );
    if (existingEvents.isNotEmpty) {
      return;
    }

    final rows = await db.query(_tableName);
    await db.transaction((txn) async {
      for (final row in rows) {
        final group = row['group_name'] as String? ?? StudentGroup.g1.name;
        final subject = _attendanceSubjectIdFor(
          row['subject'] as String? ?? '',
        );
        final entries = _deserializeEntries(row['entries'] as String? ?? '{}');

        var index = 0;
        for (final entry in entries.entries) {
          final id =
              'legacy_${group}_${subject}_${entry.key.microsecondsSinceEpoch}_${index++}';
          await txn.insert(_entriesTableName, {
            'id': id,
            'group_name': group,
            'subject': subject,
            'status': entry.value ? 1 : 0,
            'event_date': entry.key.toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
    });
  }

  static Future<void> insertAttendanceEvent({
    required StudentGroup group,
    required String subject,
    required DateTime date,
    required bool present,
  }) async {
    final db = await database;
    final id =
        '${group.name}_${subject}_${date.microsecondsSinceEpoch}_'
        '${DateTime.now().microsecondsSinceEpoch}_${_eventSequence++}';
    await db.insert(_entriesTableName, {
      'id': id,
      'group_name': group.name,
      'subject': subject,
      'status': present ? 1 : 0,
      'event_date': date.toIso8601String(),
    });
    debugPrint(
      '[attendance] event insert id=$id group=${group.name} subject=$subject '
      'present=$present date=${date.toIso8601String()}',
    );
  }

  static Future<Database> get database async {
    _database ??= await _openDatabase();
    return _database!;
  }

  static Future<Database> _openDatabase() async {
    late final String dbPath;

    if (Platform.isWindows || Platform.isLinux) {
      final baseDirectory =
          Platform.environment['LOCALAPPDATA'] ??
          Platform.environment['HOME'] ??
          Directory.current.path;

      final appDataDirectory = Directory(
        _joinPath(baseDirectory, 'attendance_tracker'),
      );

      await appDataDirectory.create(recursive: true);
      dbPath = _joinPath(appDataDirectory.path, 'attendance_tracker.db');
    } else {
      // Android/iOS: use the app-private writable database directory.
      final databasesDirectory = await getDatabasesPath();
      dbPath = _joinPath(databasesDirectory, 'attendance_tracker.db');
    }

    return openDatabase(
      dbPath,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $_tableName (
            group_name TEXT NOT NULL,
            subject TEXT NOT NULL,
            attended INTEGER NOT NULL,
            total INTEGER NOT NULL,
            entries TEXT NOT NULL,
            PRIMARY KEY(group_name, subject)
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS $_entriesTableName (
            id TEXT PRIMARY KEY,
            group_name TEXT NOT NULL,
            subject TEXT NOT NULL,
            status INTEGER NOT NULL,
            event_date TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
  }

  static Future<Map<StudentGroup, Map<String, AttendanceRecord>>>
  loadAllGroups() async {
    final db = await database;
    final rows = await db.query(_tableName);
    final records = {
      StudentGroup.g1: <String, AttendanceRecord>{},
      StudentGroup.g2: <String, AttendanceRecord>{},
    };

    for (final row in rows) {
      final groupName = row['group_name'] as String? ?? StudentGroup.g1.name;
      final group = groupName == StudentGroup.g2.name
          ? StudentGroup.g2
          : StudentGroup.g1;

      final savedSubject = row['subject'] as String? ?? '';
      final subject = _attendanceSubjectIdFor(savedSubject);
      if (savedSubject != subject && records[group]!.containsKey(subject)) {
        continue;
      }
      final entries = _deserializeEntries(row['entries'] as String? ?? '{}');
      final attended =
          row['attended'] as int? ??
          entries.values.where((value) => value).length;
      final total = row['total'] as int? ?? entries.length;

      records[group]![subject] = AttendanceRecord(
        attended: attended,
        total: total,
        entries: entries,
      );
      debugPrint(
        '[attendance] read group=${group.name} subject=$subject '
        'attended=$attended total=$total',
      );
    }

    final defaults = {
      StudentGroup.g1: _defaultAttendanceRecords(),
      StudentGroup.g2: {
        for (final entry in _defaultAttendanceRecords().entries)
          entry.key: entry.value.copy(),
      },
    };

    for (final group in StudentGroup.values) {
      final groupRecords = records[group] ?? <String, AttendanceRecord>{};
      for (final entry in defaults[group]!.entries) {
        groupRecords.putIfAbsent(entry.key, () => entry.value.copy());
      }
      records[group] = groupRecords;
    }

    return records;
  }

  static Future<AppSettings> loadAppSettings() async {
    final db = await database;
    final rows = await db.query('app_settings');
    final values = <String, String>{
      for (final row in rows) (row['key'] as String): (row['value'] as String),
    };
    return AppSettings(
      studentName: values['studentName'] ?? '',
      rollNumber: values['rollNumber'] ?? '',
      course: values['course'] ?? 'CSE/DS/AI – 3rd Sem',
      section: values['section'] ?? 'B',
      academicSession: values['academicSession'] ?? 'Jul–Dec 2026',
      darkMode: values['darkMode'] == 'true',
      pastelTheme: values['pastelTheme'] ?? 'pink',
      remindersEnabled: values['remindersEnabled'] != 'false',
      reminderHour: int.tryParse(values['reminderHour'] ?? '') ?? 17,
      reminderMinute: int.tryParse(values['reminderMinute'] ?? '') ?? 0,
      warningPercentage: int.tryParse(values['warningPercentage'] ?? '') ?? 75,
    );
  }

  static Future<void> saveAppSettings(AppSettings settings) async {
    final db = await database;
    final values = <String, String>{
      'studentName': settings.studentName,
      'rollNumber': settings.rollNumber,
      'course': settings.course,
      'section': settings.section,
      'academicSession': settings.academicSession,
      'darkMode': '${settings.darkMode}',
      'pastelTheme': settings.pastelTheme,
      'remindersEnabled': '${settings.remindersEnabled}',
      'reminderHour': '${settings.reminderHour}',
      'reminderMinute': '${settings.reminderMinute}',
      'warningPercentage': '${settings.warningPercentage}',
    };
    await db.transaction((txn) async {
      for (final entry in values.entries) {
        await txn.insert('app_settings', {
          'key': entry.key,
          'value': entry.value,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  static Future<String> databasePath() async {
    final appDataDirectory = Directory(
      _joinPath(
        Platform.environment['LOCALAPPDATA'] ?? Directory.current.path,
        'attendance_tracker',
      ),
    );
    return _joinPath(appDataDirectory.path, 'attendance_tracker.db');
  }

  static Future<void> closeDatabase() async {
    final db = _database;
    _database = null;
    if (db != null) {
      await db.close();
    }
  }

  static Future<void> saveGroupRecords(
    Map<StudentGroup, Map<String, AttendanceRecord>> records,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final group in StudentGroup.values) {
        final groupRecords = records[group] ?? <String, AttendanceRecord>{};
        for (final entry in groupRecords.entries) {
          final record = entry.value;
          final values = {
            'group_name': group.name,
            'subject': entry.key,
            'attended': record.attended,
            'total': record.total,
            'entries': jsonEncode(_serializeEntries(record.entries)),
          };
          final updatedRows = await txn.update(
            _tableName,
            values,
            where: 'group_name = ? AND subject = ?',
            whereArgs: [group.name, entry.key],
          );
          if (updatedRows == 0) {
            await txn.insert(_tableName, values);
          }
          debugPrint(
            '[attendance] write group=${group.name} subject=${entry.key} '
            'attended=${record.attended} total=${record.total} '
            'operation=${updatedRows == 0 ? 'insert' : 'update'}',
          );
        }
      }
    });
  }

  static Future<void> saveAllGroups(
    Map<StudentGroup, Map<String, AttendanceRecord>> records,
  ) async {
    await saveGroupRecords(records);
  }

  static Map<String, bool> _serializeEntries(Map<DateTime, bool> entries) {
    final serialized = <String, bool>{};

    for (final entry in entries.entries) {
      serialized[entry.key.toIso8601String()] = entry.value;
    }

    return serialized;
  }

  static Map<DateTime, bool> _deserializeEntries(String rawEntries) {
    if (rawEntries.isEmpty || rawEntries == '{}') {
      return {};
    }

    final decoded = jsonDecode(rawEntries);
    if (decoded is! Map) {
      return {};
    }

    final entries = <DateTime, bool>{};
    for (final item in decoded.entries) {
      final key = item.key.toString();
      final value = item.value;
      if (value is! bool) {
        continue;
      }

      final date = DateTime.tryParse(key);
      if (date != null) {
        entries[DateTime(date.year, date.month, date.day)] = value;
      }
    }

    return entries;
  }
}

class TimetableClass {
  final String attendanceId;
  final String subject;
  final String teacher;
  final String room;
  final String time;
  final bool isLab;
  final Color color;
  final IconData icon;

  const TimetableClass({
    required this.attendanceId,
    required this.subject,
    required this.teacher,
    required this.room,
    required this.time,
    required this.isLab,
    required this.color,
    required this.icon,
  });
}

class AttendanceRecord {
  int attended;
  int total;
  final Map<DateTime, bool> entries;

  AttendanceRecord({
    required this.attended,
    required this.total,
    Map<DateTime, bool>? entries,
  }) : entries = entries ?? {};

  AttendanceRecord copy() {
    return AttendanceRecord(
      attended: attended,
      total: total,
      entries: Map<DateTime, bool>.from(entries),
    );
  }

  void saveAttendance(DateTime date, bool isPresent) {
    var eventDate = DateTime(date.year, date.month, date.day);
    while (entries.containsKey(eventDate)) {
      eventDate = eventDate.add(const Duration(microseconds: 1));
    }

    total++;
    if (isPresent) {
      attended++;
    }
    entries[eventDate] = isPresent;
  }

  double get percentage => total == 0 ? 0 : attended / total;
}

class AttendanceSummary {
  final int attended;
  final int total;

  const AttendanceSummary({required this.attended, required this.total});

  double get percentage => total == 0 ? 0 : attended / total;
}

class AttendanceEntry {
  final String subjectId;
  final DateTime date;
  final bool present;

  const AttendanceEntry({
    required this.subjectId,
    required this.date,
    required this.present,
  });
}

// ============================================================
// MAIN HOME
// ============================================================

class AttendanceHome extends StatefulWidget {
  const AttendanceHome({super.key});

  @override
  State<AttendanceHome> createState() => _AttendanceHomeState();
}

class _AttendanceHomeState extends State<AttendanceHome> {
  int selectedPage = 0;
  StudentGroup selectedGroup = StudentGroup.g1;
  bool weekView = true;
  final Map<StudentGroup, Map<String, AttendanceRecord>> attendanceByGroup =
      _createAttendanceByGroup();
  Future<void> _saveQueue = Future<void>.value();
  bool isLoading = true;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  final List<String> pageNames = [
    'Dashboard',
    'Timetable',
    'Attendance',
    'Calendar',
    'Reports',
    'Calculator',
    'Profile',
    'Settings',
  ];

  @override
  void initState() {
    super.initState();
    _loadAttendance();
  }

  Future<void> _loadAttendance() async {
    final savedRecords = await AttendanceDatabase.loadAllGroups();
    if (!mounted) {
      return;
    }

    setState(() {
      attendanceByGroup
        ..clear()
        ..addAll(savedRecords);
      isLoading = false;
    });
  }

  Future<void> _saveAttendanceEvent(
    StudentGroup group,
    AttendanceEntry entry,
  ) async {
    // Queue database writes so rapid Present/Absent clicks are processed
    // one-by-one, while the UI remains immediately responsive.
    _saveQueue = _saveQueue.then<void>((_) async {
      try {
        debugPrint(
          '[attendance] saving group=${group.name} '
          'subject=${entry.subjectId} present=${entry.present}',
        );

        // Store this individual attendance event in SQLite.
        await AttendanceDatabase.insertAttendanceEvent(
          group: group,
          subject: entry.subjectId,
          date: entry.date,
          present: entry.present,
        );

        // Persist the current in-memory totals/entries.
        //
        // IMPORTANT:
        // Do NOT reload attendance from SQLite here. Reloading after every
        // click can restore a stale snapshot and make the user press the
        // button multiple times before the visible value advances.
        await AttendanceDatabase.saveAllGroups(attendanceByGroup);

        debugPrint('[attendance] attendance save complete');
      } catch (error, stackTrace) {
        debugPrint('[attendance] attendance save failed: $error');
        debugPrint('$stackTrace');
      }
    });

    await _saveQueue;
  }

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return Scaffold(
        body: Center(
          child: CircularProgressIndicator(
            valueColor: AlwaysStoppedAnimation<Color>(AppColors.pink),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isMobile = constraints.maxWidth < 800;

        void selectPage(int index) {
          setState(() {
            selectedPage = index;
          });
          if (isMobile && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
        }

        final content = Column(
          children: [
            _TopBar(
              selectedPage: pageNames[selectedPage],
              selectedGroup: selectedGroup,
              showMenuButton: isMobile,
              onMenuPressed: isMobile
                  ? () => _scaffoldKey.currentState?.openDrawer()
                  : null,
              onGroupChanged: (group) {
                setState(() {
                  selectedGroup = group;
                });
              },
            ),
            Expanded(child: _buildPage()),
          ],
        );

        if (isMobile) {
          return Scaffold(
            key: _scaffoldKey,
            drawer: Drawer(
              width: constraints.maxWidth >= 320
                  ? 290
                  : constraints.maxWidth * 0.86,
              child: SafeArea(
                child: _Sidebar(
                  width: double.infinity,
                  selectedIndex: selectedPage,
                  onSelected: selectPage,
                ),
              ),
            ),
            body: content,
          );
        }

        return Scaffold(
          body: Row(
            children: [
              _Sidebar(
                width: 245,
                selectedIndex: selectedPage,
                onSelected: selectPage,
              ),
              Expanded(child: content),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPage() {
    switch (selectedPage) {
      case 0:
        return _DashboardPage(
          selectedGroup: selectedGroup,
          records: attendanceByGroup[selectedGroup]!,
          onTimetablePressed: () {
            setState(() {
              selectedPage = 1;
            });
          },
        );

      case 1:
        return _TimetablePage(
          selectedGroup: selectedGroup,
          weekView: weekView,
          onViewChanged: (value) {
            setState(() {
              weekView = value;
            });
          },
        );

      case 2:
        return _AttendancePage(
          group: selectedGroup,
          records: attendanceByGroup[selectedGroup]!,
          onAttendanceAdded: (entry) {
            final group = selectedGroup;
            final record = attendanceByGroup[group]![entry.subjectId]!;

            debugPrint(
              '[attendance] CLICK group=${group.name} '
              'subject=${entry.subjectId} present=${entry.present}',
            );

            // Update the in-memory record immediately so every physical
            // click produces an immediate UI update.
            setState(() {
              record.saveAttendance(entry.date, entry.present);
            });

            // Persist the event in the background. The UI is intentionally
            // NOT reloaded from SQLite after the click.
            unawaited(_saveAttendanceEvent(group, entry));
          },
        );

      case 3:
        return _AttendanceCalendarPage(
          group: selectedGroup,
          records: attendanceByGroup[selectedGroup]!,
        );

      case 4:
        return _ReportsPage(
          group: selectedGroup,
          records: attendanceByGroup[selectedGroup]!,
        );

      case 5:
        return _CalculatorPage(
          group: selectedGroup,
          records: attendanceByGroup[selectedGroup]!,
        );

      case 6:
        return const _ProfilePage();

      case 7:
        return _SettingsPage(onDataRestored: _loadAttendance);

      default:
        return const SizedBox();
    }
  }
}

// ============================================================
// SIDEBAR
// ============================================================

class _Sidebar extends StatelessWidget {
  final double width;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  const _Sidebar({
    required this.width,
    required this.selectedIndex,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: Color(0xFFFFF3F8),
        border: Border(right: BorderSide(color: Color(0xFFF0DCE7))),
      ),
      child: Column(
        children: [
          const SizedBox(height: 28),

          // Logo
          const Text(
            'Attendance',
            style: TextStyle(
              fontSize: 29,
              fontWeight: FontWeight.w700,
              color: AppColors.purple,
            ),
          ),

          const Text(
            'Tracker ♡',
            style: TextStyle(
              fontSize: 29,
              fontWeight: FontWeight.w700,
              color: AppColors.pink,
            ),
          ),

          const SizedBox(height: 6),

          const Text(
            'Small steps,\nbig dreams ✨',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.purple, fontSize: 13),
          ),

          const SizedBox(height: 28),

          // Navigation is scrollable so the sidebar never overflows on
          // short/narrow desktop windows after adding Calendar and Profile.
          Expanded(
            child: SingleChildScrollView(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _SideButton(
                    icon: Icons.home_outlined,
                    title: 'Dashboard',
                    selected: selectedIndex == 0,
                    onTap: () => onSelected(0),
                  ),

                  _SideButton(
                    icon: Icons.calendar_month_outlined,
                    title: 'Timetable',
                    selected: selectedIndex == 1,
                    onTap: () => onSelected(1),
                  ),

                  _SideButton(
                    icon: Icons.check_circle_outline,
                    title: 'Attendance',
                    selected: selectedIndex == 2,
                    onTap: () => onSelected(2),
                  ),

                  _SideButton(
                    icon: Icons.calendar_today_outlined,
                    title: 'Calendar',
                    selected: selectedIndex == 3,
                    onTap: () => onSelected(3),
                  ),

                  _SideButton(
                    icon: Icons.bar_chart_rounded,
                    title: 'Reports',
                    selected: selectedIndex == 4,
                    onTap: () => onSelected(4),
                  ),

                  _SideButton(
                    icon: Icons.calculate_outlined,
                    title: 'Calculator',
                    selected: selectedIndex == 5,
                    onTap: () => onSelected(5),
                  ),

                  _SideButton(
                    icon: Icons.person_outline_rounded,
                    title: 'Profile',
                    selected: selectedIndex == 6,
                    onTap: () => onSelected(6),
                  ),

                  _SideButton(
                    icon: Icons.settings_outlined,
                    title: 'Settings',
                    selected: selectedIndex == 7,
                    onTap: () => onSelected(7),
                  ),
                ],
              ),
            ),
          ),

          // Cute decoration stays at the bottom when there is enough room.
          const Padding(
            padding: EdgeInsets.fromLTRB(18, 10, 18, 8),
            child: Column(
              children: [
                Text('📚  🐱  ☕', style: TextStyle(fontSize: 28)),
                SizedBox(height: 8),
                Text(
                  'Study • Track • Grow ♡',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.purple,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _SideButton extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _SideButton({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 4),
      child: Material(
        color: selected ? AppColors.lightPink : Colors.transparent,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
            child: Row(
              children: [
                Icon(icon, color: selected ? AppColors.pink : AppColors.text),
                const SizedBox(width: 14),
                Text(
                  title,
                  style: TextStyle(
                    color: selected ? AppColors.pink : AppColors.text,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// TOP BAR
// ============================================================

class _TopBar extends StatelessWidget {
  final String selectedPage;
  final StudentGroup selectedGroup;
  final ValueChanged<StudentGroup> onGroupChanged;
  final bool showMenuButton;
  final VoidCallback? onMenuPressed;

  const _TopBar({
    required this.selectedPage,
    required this.selectedGroup,
    required this.onGroupChanged,
    this.showMenuButton = false,
    this.onMenuPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 92),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFF0E2EA))),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < 1100;
          final titleColumn = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                selectedPage == 'Dashboard'
                    ? (appSettingsNotifier.value.studentName.trim().isEmpty
                          ? 'Good morning! 🌸'
                          : 'Good morning, ${appSettingsNotifier.value.studentName.trim()}! 🌸')
                    : selectedPage,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
              const SizedBox(height: 3),
              const Text(
                'Have a productive day ahead ✨',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppColors.grey),
              ),
            ],
          );

          final titleBlock = showMenuButton
              ? Row(
                  children: [
                    IconButton(
                      onPressed: onMenuPressed,
                      tooltip: 'Open menu',
                      icon: const Icon(Icons.menu_rounded),
                      color: AppColors.purple,
                    ),
                    const SizedBox(width: 2),
                    Expanded(child: titleColumn),
                  ],
                )
              : titleColumn;

          final groupSelector = ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: SizedBox(
              width: narrow ? constraints.maxWidth : null,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: AppColors.lavender,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<StudentGroup>(
                    value: selectedGroup,
                    isExpanded: true,
                    icon: const Icon(
                      Icons.keyboard_arrow_down_rounded,
                      color: AppColors.purple,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: StudentGroup.g1,
                        child: Text(
                          'G1 • Data Science / CSE',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: StudentGroup.g2,
                        child: Text(
                          'G2 • AI/ML',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        onGroupChanged(value);
                      }
                    },
                  ),
                ),
              ),
            ),
          );

          final notificationButton = Material(
            color: AppColors.lightPink,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: () => _showTodayReminder(context, selectedGroup),
              child: const SizedBox(
                width: 44,
                height: 44,
                child: Icon(
                  Icons.notifications_none_rounded,
                  color: AppColors.pink,
                ),
              ),
            ),
          );

          if (showMenuButton) {
            return SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: 18),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    titleBlock,
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: groupSelector),
                        const SizedBox(width: 10),
                        notificationButton,
                      ],
                    ),
                  ],
                ),
              ),
            );
          }

          final actions = narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    groupSelector,
                    const SizedBox(height: 10),
                    notificationButton,
                  ],
                )
              : Wrap(
                  spacing: 18,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [groupSelector, notificationButton],
                );

          if (narrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [titleBlock, const SizedBox(height: 12), actions],
            );
          }

          return Row(
            children: [
              Expanded(child: titleBlock),
              const SizedBox(width: 18),
              actions,
            ],
          );
        },
      ),
    );
  }
}

// ============================================================
// TODAY'S CLASSES + REMINDERS
// ============================================================

String _weekdayName(int weekday) {
  const names = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return names[weekday - 1];
}

List<TimetableClass> _todayClasses(StudentGroup group) {
  final weekday = DateTime.now().weekday;

  final classes = switch (weekday) {
    DateTime.monday => _monday(group),
    DateTime.tuesday => _tuesday(group),
    DateTime.wednesday => _wednesday(group),
    DateTime.thursday => _thursday(group),
    DateTime.friday => _friday(group),
    _ => <TimetableClass?>[],
  };

  return classes.whereType<TimetableClass>().toList();
}

void _showTodayReminder(BuildContext context, StudentGroup group) {
  final todayClasses = _todayClasses(group);
  final todayName = _weekdayName(DateTime.now().weekday);
  final groupName = group == StudentGroup.g1
      ? 'G1 • Data Science / CSE'
      : 'G2 • AI/ML';

  showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: AppColors.lightPink,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.notifications_rounded,
                color: AppColors.pink,
              ),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Today Reminder',
                style: TextStyle(
                  color: AppColors.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: todayClasses.isEmpty
              ? Text(
                  'No classes are scheduled for $todayName.\n\nEnjoy your day! 🌸',
                  style: const TextStyle(color: AppColors.grey, height: 1.5),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$groupName • $todayName',
                      style: const TextStyle(
                        color: AppColors.purple,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'Remember to mark your attendance after each class.',
                      style: TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...todayClasses.map(
                      (item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.circle,
                              size: 8,
                              color: item.color.computeLuminance() > 0.8
                                  ? AppColors.purple
                                  : AppColors.pink,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${item.time}  •  ${item.subject}',
                                style: const TextStyle(
                                  color: AppColors.grey,
                                  height: 1.3,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      );
    },
  );
}

class _ReminderCard extends StatelessWidget {
  final int classCount;

  const _ReminderCard({required this.classCount});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.lightPink,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.pink.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.notifications_active_rounded,
              color: AppColors.pink,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Reminder: mark attendance after your $classCount '
              '${classCount == 1 ? 'class' : 'classes'} today. ✨',
              style: const TextStyle(
                color: AppColors.text,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoClassesCard extends StatelessWidget {
  const _NoClassesCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppColors.mint,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: AppColors.green.withValues(alpha: 0.25)),
      ),
      child: const Row(
        children: [
          Icon(Icons.celebration_rounded, color: AppColors.green),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'No classes today. Take a little break and recharge! 🌸',
              style: TextStyle(
                color: AppColors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// DASHBOARD
// ============================================================

class _DashboardPage extends StatelessWidget {
  final StudentGroup selectedGroup;
  final Map<String, AttendanceRecord> records;
  final VoidCallback onTimetablePressed;

  const _DashboardPage({
    required this.selectedGroup,
    required this.records,
    required this.onTimetablePressed,
  });

  @override
  Widget build(BuildContext context) {
    final summary = _summarizeAttendance(records);
    final percentageText = '${_formatPercentage(summary.percentage * 100)}%';
    final isWarning = summary.percentage * 100 < attendanceWarningPercentage;
    final todayClassCount = _todayClasses(selectedGroup).length;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final cards = [
                _StatCard(
                  title: 'Overall Attendance',
                  value: percentageText,
                  subtitle: isWarning ? 'Needs attention' : 'Looking good ♡',
                  icon: Icons.favorite_rounded,
                  color: AppColors.lightPink,
                  iconColor: AppColors.pink,
                ),
                _StatCard(
                  title: 'Classes Today',
                  value: '$todayClassCount',
                  subtitle: 'Stay consistent',
                  icon: Icons.school_rounded,
                  color: AppColors.lavender,
                  iconColor: AppColors.purple,
                ),
                _StatCard(
                  title: 'Attendance Warning',
                  value: isWarning ? 'Yes' : 'No',
                  subtitle: isWarning ? 'Needs attention' : 'You are safe ✨',
                  icon: Icons.warning_amber_rounded,
                  color: AppColors.peach,
                  iconColor: AppColors.orange,
                ),
              ];

              if (constraints.maxWidth < 900) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    cards[0],
                    const SizedBox(height: 14),
                    cards[1],
                    const SizedBox(height: 14),
                    cards[2],
                  ],
                );
              }

              return Row(
                children: [
                  Expanded(child: cards[0]),
                  const SizedBox(width: 18),
                  Expanded(child: cards[1]),
                  const SizedBox(width: 18),
                  Expanded(child: cards[2]),
                ],
              );
            },
          ),

          const SizedBox(height: 28),

          Builder(
            builder: (context) {
              final todayClasses = _todayClasses(selectedGroup);
              final todayName = _weekdayName(DateTime.now().weekday);

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          "Today's Classes • $todayName",
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            color: AppColors.text,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: onTimetablePressed,
                        icon: const Icon(Icons.arrow_forward_rounded),
                        label: const Text('View timetable'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  if (todayClasses.isEmpty)
                    const _NoClassesCard()
                  else ...[
                    ...todayClasses.map(
                      (item) => _TodayClassCard(
                        subject: item.subject,
                        teacher: item.teacher,
                        time: item.time,
                        room: item.room,
                        icon: item.icon,
                        color: item.color,
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (appSettingsNotifier.value.remindersEnabled)
                      _ReminderCard(classCount: todayClasses.length),
                  ],
                ],
              );
            },
          ),

          const SizedBox(height: 25),

          Row(
            children: [
              Expanded(
                child: _ProgressCard(
                  title: 'Attendance Progress',
                  percentage: summary.percentage,
                  label: '$percentageText overall',
                ),
              ),
              const SizedBox(width: 18),
              Expanded(child: _CuteMessageCard()),
            ],
          ),
        ],
      ),
    );
  }
}

// ============================================================
// STAT CARD
// ============================================================

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Color iconColor;

  const _StatCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.iconColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: color.withValues(alpha: 0.8)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.035),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 55,
            height: 55,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(color: AppColors.grey, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    color: iconColor,
                    fontSize: 25,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// TODAY CLASS
// ============================================================

class _TodayClassCard extends StatelessWidget {
  final String subject;
  final String teacher;
  final String time;
  final String room;
  final IconData icon;
  final Color color;

  const _TodayClassCard({
    required this.subject,
    required this.teacher,
    required this.time,
    required this.room,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(17),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFF0E5EC)),
      ),
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(15),
            ),
            child: Icon(icon, color: AppColors.purple),
          ),
          const SizedBox(width: 15),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  subject,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                    fontSize: 15,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  '$teacher  •  $room',
                  style: const TextStyle(color: AppColors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          Text(
            time,
            style: const TextStyle(
              color: AppColors.purple,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// PROGRESS CARD
// ============================================================

class _ProgressCard extends StatelessWidget {
  final String title;
  final double percentage;
  final String label;

  const _ProgressCard({
    required this.title,
    required this.percentage,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return _SimpleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 17,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 18),
          LinearProgressIndicator(
            value: percentage,
            minHeight: 10,
            borderRadius: BorderRadius.circular(10),
            backgroundColor: AppColors.lightPink,
            color: AppColors.pink,
          ),
          const SizedBox(height: 10),
          Text(label, style: const TextStyle(color: AppColors.grey)),
        ],
      ),
    );
  }
}

// ============================================================
// CUTE MESSAGE
// ============================================================

class _CuteMessageCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return _SimpleCard(
      color: AppColors.lavender,
      child: const Row(
        children: [
          Text('🌷', style: TextStyle(fontSize: 40)),
          SizedBox(width: 15),
          Expanded(
            child: Text(
              'Small steps every day create big results tomorrow. Keep going! ♡',
              style: TextStyle(
                color: AppColors.purple,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SimpleCard extends StatelessWidget {
  final Widget child;
  final Color color;

  const _SimpleCard({required this.child, this.color = Colors.white});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF0E5EC)),
      ),
      child: child,
    );
  }
}

// ============================================================
// TIMETABLE PAGE
// ============================================================

class _TimetablePage extends StatelessWidget {
  final StudentGroup selectedGroup;
  final bool weekView;
  final ValueChanged<bool> onViewChanged;

  const _TimetablePage({
    required this.selectedGroup,
    required this.weekView,
    required this.onViewChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 700;

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Timetable ♡',
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                      ),
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth,
                      ),
                      child: Container(
                        width: constraints.maxWidth,
                        decoration: BoxDecoration(
                          color: AppColors.lightPink,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _ViewButton(
                                title: 'Week View',
                                selected: weekView,
                                onTap: () => onViewChanged(true),
                              ),
                            ),
                            Expanded(
                              child: _ViewButton(
                                title: 'List View',
                                selected: !weekView,
                                onTap: () => onViewChanged(false),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              }

              return Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Timetable ♡',
                      style: TextStyle(
                        fontSize: 27,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                      ),
                    ),
                  ),
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.lightPink,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ViewButton(
                          title: 'Week View',
                          selected: weekView,
                          onTap: () => onViewChanged(true),
                        ),
                        _ViewButton(
                          title: 'List View',
                          selected: !weekView,
                          onTap: () => onViewChanged(false),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 12),

          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 600;

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'July – December 2026',
                      style: TextStyle(color: AppColors.grey),
                    ),
                    const SizedBox(height: 8),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth,
                      ),
                      child: _GroupBadge(group: selectedGroup),
                    ),
                  ],
                );
              }

              return Row(
                children: [
                  const Text(
                    'July – December 2026',
                    style: TextStyle(color: AppColors.grey),
                  ),
                  const SizedBox(width: 15),
                  _GroupBadge(group: selectedGroup),
                ],
              );
            },
          ),

          const SizedBox(height: 25),

          weekView
              ? _WeekTimetable(group: selectedGroup)
              : _ListTimetable(group: selectedGroup),
        ],
      ),
    );
  }
}

class _ViewButton extends StatelessWidget {
  final String title;
  final bool selected;
  final VoidCallback onTap;

  const _ViewButton({
    required this.title,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Center(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              title,
              maxLines: 1,
              style: TextStyle(
                color: selected ? AppColors.pink : AppColors.purple,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GroupBadge extends StatelessWidget {
  final StudentGroup group;

  const _GroupBadge({required this.group});

  @override
  Widget build(BuildContext context) {
    final isG1 = group == StudentGroup.g1;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: isG1 ? AppColors.blue : AppColors.lavender,
        borderRadius: BorderRadius.circular(14),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text(
          isG1 ? 'G1 • Data Science / CSE' : 'G2 • AI/ML',
          maxLines: 1,
          style: TextStyle(
            color: isG1 ? AppColors.blueDark : AppColors.purple,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// ============================================================
// WEEK TIMETABLE
// ============================================================

class _WeekTimetable extends StatelessWidget {
  final StudentGroup group;

  const _WeekTimetable({required this.group});

  static const times = [
    '09:05 – 10:00',
    '10:00 – 10:55',
    '10:55 – 11:50',
    '11:50 – 12:45',
    '12:45 – 01:30',
    '01:30 – 02:20',
    '02:20 – 03:10',
    '03:10 – 04:00',
  ];

  @override
  Widget build(BuildContext context) {
    final days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'];
    final daySchedules = [
      _monday(group),
      _tuesday(group),
      _wednesday(group),
      _thursday(group),
      _friday(group),
    ];

    final rows = <Widget>[
      for (int i = 0; i < times.length; i++)
        i == 4
            ? const _TimetableBreakRow()
            : _TimetableDayRow(
                time: times[i],
                data: List.generate(
                  daySchedules.length,
                  (dayIndex) => daySchedules[dayIndex][i],
                ),
              ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final minTableWidth = 860.0;
        final effectiveWidth = constraints.maxWidth < minTableWidth
            ? minTableWidth
            : constraints.maxWidth;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: effectiveWidth,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFFEEDFE8)),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: const BoxDecoration(
                      color: Color(0xFFFFF1F7),
                      borderRadius: BorderRadius.vertical(
                        top: Radius.circular(22),
                      ),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 110,
                          child: Text(
                            'Time / Day',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppColors.text,
                            ),
                          ),
                        ),
                        ...days.map(
                          (day) => Expanded(
                            child: Text(
                              day,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                color: AppColors.pink,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  ...rows,
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _Legend(color: AppColors.blue, text: 'Lecture'),
                        SizedBox(width: 20),
                        _Legend(color: AppColors.lightPink, text: 'Lab'),
                        SizedBox(width: 20),
                        _Legend(color: AppColors.mint, text: 'Other'),
                        SizedBox(width: 20),
                        _Legend(color: AppColors.peach, text: 'Break'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TimetableBreakRow extends StatelessWidget {
  const _TimetableBreakRow();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF0E5EC))),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 110,
            child: Text(
              '12:45 – 01:30',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.orange,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          ...List.generate(
            5,
            (index) => Expanded(
              child: Container(
                height: 86,
                margin: const EdgeInsets.all(3),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                decoration: BoxDecoration(
                  color: AppColors.peach,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE7CFA0)),
                ),
                child: const Center(
                  child: Text(
                    'BREAK',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.orange,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// TIMETABLE ROW
// ============================================================

class _TimetableDayRow extends StatelessWidget {
  final String time;
  final List<TimetableClass?> data;

  const _TimetableDayRow({required this.time, required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0xFFF0E5EC))),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              time,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 11,
                color: AppColors.grey,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ...data.map(
            (item) => Expanded(
              child: item == null
                  ? Container(
                      height: 86,
                      margin: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFCFAFC),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    )
                  : _ClassCell(item: item),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// CLASS CELL
// ============================================================

class _ClassCell extends StatelessWidget {
  final TimetableClass item;

  const _ClassCell({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 86,
      margin: const EdgeInsets.all(3),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: item.color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(item.icon, size: 18, color: AppColors.purple),
          const SizedBox(height: 3),
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: Text(
                item.subject,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.text,
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                ),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            item.teacher,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.grey, fontSize: 9),
          ),
          Text(
            item.room,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.grey, fontSize: 9),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// LIST VIEW
// ============================================================

class _ListTimetable extends StatelessWidget {
  final StudentGroup group;

  const _ListTimetable({required this.group});

  @override
  Widget build(BuildContext context) {
    final all = <String, List<TimetableClass>>{
      'Monday': _monday(group).whereType<TimetableClass>().toList(),
      'Tuesday': _tuesday(group).whereType<TimetableClass>().toList(),
      'Wednesday': _wednesday(group).whereType<TimetableClass>().toList(),
      'Thursday': _thursday(group).whereType<TimetableClass>().toList(),
      'Friday': _friday(group).whereType<TimetableClass>().toList(),
    };

    return Column(
      children: all.entries.map((entry) {
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFF0E5EC)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.key,
                style: const TextStyle(
                  color: AppColors.pink,
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 12),
              ...entry.value.map((item) => _ListClassItem(item: item)),
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _ListClassItem extends StatelessWidget {
  final TimetableClass item;

  const _ListClassItem({required this.item});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: item.color,
        borderRadius: BorderRadius.circular(13),
      ),
      child: Row(
        children: [
          Icon(item.icon, color: AppColors.purple),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              item.subject,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              '${item.teacher} • ${item.room}',
              textAlign: TextAlign.right,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// LEGEND
// ============================================================

class _Legend extends StatelessWidget {
  final Color color;
  final String text;

  const _Legend({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 13,
          height: 13,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(text, style: const TextStyle(color: AppColors.grey, fontSize: 12)),
      ],
    );
  }
}

// ============================================================
// TIMETABLE DATA
// ============================================================

TimetableClass dsaLecture() {
  return const TimetableClass(
    attendanceId: 'dsa',
    subject: 'Data Structures & Algorithms',
    teacher: 'Sonia Mam (SM)',
    room: 'B-105',
    time: '09:05 – 10:00',
    isLab: false,
    color: AppColors.blue,
    icon: Icons.menu_book_rounded,
  );
}

TimetableClass maths() {
  return const TimetableClass(
    attendanceId: 'mathematics_iii',
    subject: 'Mathematics-III',
    teacher: 'Dhanpreet Mam (DP)',
    room: 'B-105',
    time: '10:00 – 10:55',
    isLab: false,
    color: AppColors.peach,
    icon: Icons.calculate_rounded,
  );
}

TimetableClass oops() {
  return const TimetableClass(
    attendanceId: 'oops',
    subject: 'OOPS',
    teacher: 'Navjot Kaur (NV)',
    room: 'B-105',
    time: '10:55 – 11:50',
    isLab: false,
    color: AppColors.mint,
    icon: Icons.code_rounded,
  );
}

TimetableClass oopsLab(String teacher, String room) {
  return TimetableClass(
    attendanceId: 'oops_lab',
    subject: 'OOPS Lab',
    teacher: teacher,
    room: room,
    time: '11:50 – 12:45',
    isLab: true,
    color: AppColors.lavender,
    icon: Icons.science_outlined,
  );
}

TimetableClass dsaLab(String teacher, String room) {
  return TimetableClass(
    attendanceId: 'dsa_lab',
    subject: 'DSA Lab',
    teacher: teacher,
    room: room,
    time: '01:30 – 02:20',
    isLab: true,
    color: AppColors.lightPink,
    icon: Icons.biotech_outlined,
  );
}

TimetableClass awsLab() {
  return const TimetableClass(
    attendanceId: 'aws_lab',
    subject: 'AWS Lab',
    teacher: 'Neha Mam (NH)',
    room: 'B-209',
    time: '01:30 – 02:20',
    isLab: true,
    color: AppColors.lightPink,
    icon: Icons.cloud_outlined,
  );
}

TimetableClass humanities() {
  return const TimetableClass(
    attendanceId: 'humanities',
    subject: 'Foundation Course in Humanities',
    teacher: 'Harbinder Mam (HB)',
    room: 'B-105',
    time: '03:10 – 04:00',
    isLab: false,
    color: AppColors.lavender,
    icon: Icons.people_outline_rounded,
  );
}

TimetableClass digitalElectronics() {
  return const TimetableClass(
    attendanceId: 'digital_electronics',
    subject: 'Digital Electronics',
    teacher: 'Jasmin Kaur (JS)',
    room: 'B-309',
    time: '10:55 – 11:50',
    isLab: false,
    color: AppColors.blue,
    icon: Icons.memory_rounded,
  );
}

TimetableClass lifeSkills() {
  return const TimetableClass(
    attendanceId: 'life_skills',
    subject: 'Life Skills',
    teacher: 'Simranpreet Mam (SP)',
    room: 'B-105',
    time: '10:00 – 10:55',
    isLab: false,
    color: Color(0xFFF5D8F5),
    icon: Icons.favorite_border_rounded,
  );
}

TimetableClass itWorkshop() {
  return const TimetableClass(
    attendanceId: 'it_workshop',
    subject: 'IT Workshop',
    teacher: 'Neha Mam (NH)',
    room: 'B-209',
    time: '10:00 – 10:55',
    isLab: true,
    color: AppColors.blue,
    icon: Icons.computer_rounded,
  );
}

TimetableClass awsLecture() {
  return const TimetableClass(
    attendanceId: 'aws',
    subject: 'AWS',
    teacher: 'Neha Mam (NH)',
    room: 'B-105',
    time: '10:55 – 11:50',
    isLab: false,
    color: AppColors.yellow,
    icon: Icons.cloud_outlined,
  );
}

// ------------------------------------------------------------
// MONDAY
// ------------------------------------------------------------

List<TimetableClass?> _monday(StudentGroup group) {
  if (group == StudentGroup.g1) {
    return [
      dsaLecture(),
      maths(),
      oops(),
      oopsLab('Chiranjeev (CV)', 'B-208'),
      null,
      awsLab(),
      dsaLab('Neha Mam (NH)', 'B-205'),
      humanities(),
    ];
  }

  return [
    itWorkshop(),
    maths(),
    oops(),
    oopsLab('Neha Mam (NH)', 'B-205'),
    null,
    awsLab(),
    oopsLab('Navjot Kaur (NV)', 'B-209'),
    humanities(),
  ];
}

// ------------------------------------------------------------
// TUESDAY
// ------------------------------------------------------------

List<TimetableClass?> _tuesday(StudentGroup group) {
  if (group == StudentGroup.g1) {
    return [
      maths(),
      lifeSkills(),
      digitalElectronics(),
      dsaLab('Jasmin Kaur (JS)', 'B-309'),
      null,
      dsaLab('Jasmin Kaur (JS)', 'B-309'),
      oopsLab('Navjot Kaur (NV)', 'B-209'),
      humanities(),
    ];
  }

  return [
    maths(),
    lifeSkills(),
    digitalElectronics(),
    dsaLab('Neha Mam (NH)', 'B-205'),
    null,
    dsaLab('Jasmin Kaur (JS)', 'B-309'),
    oopsLab('Jasmin Kaur (JS)', 'B-309'),
    humanities(),
  ];
}

// ------------------------------------------------------------
// WEDNESDAY
// ------------------------------------------------------------

List<TimetableClass?> _wednesday(StudentGroup group) {
  if (group == StudentGroup.g1) {
    return [
      awsLab(),
      awsLecture(),
      oopsLab('AF ml', 'B-211'),
      oopsLab('Chiranjeev (CV)', 'B-208'),
      null,
      dsaLab('Chiranjeev (CV)', 'B-208'),
      dsaLecture(),
      oops(),
    ];
  }

  return [
    dsaLab('AA', 'B-208'),
    awsLecture(),
    oopsLab('AF ml', 'B-211'),
    dsaLab('Chiranjeev (CV)', 'B-208'),
    null,
    dsaLab('Chiranjeev (CV)', 'B-208'),
    dsaLecture(),
    oops(),
  ];
}

// ------------------------------------------------------------
// THURSDAY
// ------------------------------------------------------------

List<TimetableClass?> _thursday(StudentGroup group) {
  if (group == StudentGroup.g1) {
    return [
      maths(),
      digitalElectronics(),
      dsaLab('Sonia Mam (SM)', 'B-204'),
      dsaLab('AA', 'B-208'),
      null,
      digitalElectronics(),
      maths(),
      humanities(),
    ];
  }

  return [
    maths(),
    digitalElectronics(),
    dsaLab('Sonia Mam (SM)', 'B-204'),
    dsaLab('AA', 'B-208'),
    null,
    digitalElectronics(),
    maths(),
    humanities(),
  ];
}

// ------------------------------------------------------------
// FRIDAY
// ------------------------------------------------------------

List<TimetableClass?> _friday(StudentGroup group) {
  return [
    oops(),
    digitalElectronics(),
    awsLecture(),
    lifeSkills(),
    null,
    dsaLecture(),
    maths(),
    humanities(),
  ];
}

// ============================================================
// ATTENDANCE PAGE
// ============================================================

Map<String, AttendanceRecord> _defaultAttendanceRecords() {
  return {
    'dsa': AttendanceRecord(attended: 8, total: 9),
    'mathematics_iii': AttendanceRecord(attended: 7, total: 8),
    'oops': AttendanceRecord(attended: 7, total: 8),
    'digital_electronics': AttendanceRecord(attended: 6, total: 8),
    'aws': AttendanceRecord(attended: 5, total: 6),
    'aws_lab': AttendanceRecord(attended: 0, total: 0),
    'humanities': AttendanceRecord(attended: 6, total: 8),
    'life_skills': AttendanceRecord(attended: 6, total: 8),
    'dsa_lab': AttendanceRecord(attended: 0, total: 0),
    'oops_lab': AttendanceRecord(attended: 0, total: 0),
    'it_workshop': AttendanceRecord(attended: 0, total: 0),
  };
}

Map<StudentGroup, Map<String, AttendanceRecord>> _createAttendanceByGroup() {
  final g1Records = _defaultAttendanceRecords();
  return {
    StudentGroup.g1: g1Records,
    StudentGroup.g2: Map.fromEntries(
      g1Records.entries.map((entry) => MapEntry(entry.key, entry.value.copy())),
    ),
  };
}

AttendanceSummary _summarizeAttendance(Map<String, AttendanceRecord> records) {
  var attended = 0;
  var total = 0;
  for (final record in records.values) {
    attended += record.attended;
    total += record.total;
  }
  return AttendanceSummary(attended: attended, total: total);
}

List<TimetableClass> _attendanceSubjects(StudentGroup group) {
  return [
    dsaLecture(),
    maths(),
    oops(),
    digitalElectronics(),
    awsLecture(),
    awsLab(),
    humanities(),
    lifeSkills(),
    itWorkshop(),
    dsaLab('Neha Mam (NH)', 'B-205'),
    oopsLab('Chiranjeev (CV)', 'B-208'),
  ];
}

class _AttendancePage extends StatelessWidget {
  final StudentGroup group;
  final Map<String, AttendanceRecord> records;
  final void Function(AttendanceEntry) onAttendanceAdded;

  const _AttendancePage({
    required this.group,
    required this.records,
    required this.onAttendanceAdded,
  });

  @override
  Widget build(BuildContext context) {
    final subjects = _attendanceSubjects(group);

    return LayoutBuilder(
      builder: (context, constraints) {
        final pagePadding = constraints.maxWidth < 500 ? 16.0 : 30.0;

        return SingleChildScrollView(
          padding: EdgeInsets.all(pagePadding),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Attendance ♡',
                    style: TextStyle(
                      fontSize: 27,
                      fontWeight: FontWeight.w800,
                      color: AppColors.text,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                group == StudentGroup.g1
                    ? 'G1 • Data Science / CSE'
                    : 'G2 • AI / ML',
                style: const TextStyle(
                  color: AppColors.purple,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 20),
              ...subjects.map(
                (subject) => _AttendanceSubject(
                  subject: subject,
                  record: records[subject.attendanceId]!,
                  onAttendanceChanged: (present) {
                    onAttendanceAdded(
                      AttendanceEntry(
                        subjectId: subject.attendanceId,
                        date: DateTime.now(),
                        present: present,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AttendanceSubject extends StatelessWidget {
  final TimetableClass subject;
  final AttendanceRecord record;
  final ValueChanged<bool>? onAttendanceChanged;

  const _AttendanceSubject({
    required this.subject,
    required this.record,
    this.onAttendanceChanged,
  });

  @override
  Widget build(BuildContext context) {
    final percentage = record.percentage;
    final percentageText = '${_formatPercentage(percentage * 100)}%';
    final isWarning = percentage * 100 < attendanceWarningPercentage;
    final subjectIcon = Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: subject.color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Icon(subject.icon, color: AppColors.purple),
    );
    final subjectDetails = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          subject.subject,
          softWrap: true,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            color: AppColors.text,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subject.teacher,
          softWrap: true,
          style: const TextStyle(color: AppColors.grey, fontSize: 12),
        ),
      ],
    );
    final percentageLabel = Text(
      percentageText,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.right,
      style: const TextStyle(
        color: AppColors.pink,
        fontWeight: FontWeight.w800,
        fontSize: 18,
      ),
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFF0E5EC)),
      ),
      child: Column(
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 360) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        subjectIcon,
                        const SizedBox(width: 14),
                        Expanded(child: subjectDetails),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: percentageLabel,
                    ),
                  ],
                );
              }

              return Row(
                children: [
                  subjectIcon,
                  const SizedBox(width: 14),
                  Expanded(child: subjectDetails),
                  const SizedBox(width: 8),
                  Flexible(child: percentageLabel),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          LinearProgressIndicator(
            value: percentage,
            minHeight: 9,
            borderRadius: BorderRadius.circular(10),
            color: AppColors.pink,
            backgroundColor: subject.color,
          ),
          const SizedBox(height: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${record.attended} present  •  ${record.total} total classes',
                style: const TextStyle(color: AppColors.grey, fontSize: 12),
              ),
              if (isWarning)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: AppColors.orange,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Below ${attendanceWarningPercentage.round()}% warning level',
                          style: const TextStyle(
                            color: AppColors.orange,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (onAttendanceChanged != null) ...[
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      onAttendanceChanged!(true);
                    },
                    icon: const Icon(Icons.check_rounded, size: 16),
                    label: const Text('Present'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.green,
                      side: const BorderSide(color: AppColors.green),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: () {
                      onAttendanceChanged!(false);
                    },
                    icon: const Icon(Icons.close_rounded, size: 16),
                    label: const Text('Absent'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.orange,
                      side: const BorderSide(color: AppColors.orange),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AddAttendanceDialog extends StatefulWidget {
  final List<TimetableClass> subjects;

  const _AddAttendanceDialog({required this.subjects});

  @override
  State<_AddAttendanceDialog> createState() => _AddAttendanceDialogState();
}

class _AddAttendanceDialogState extends State<_AddAttendanceDialog> {
  late String selectedSubjectId;
  DateTime selectedDate = DateTime.now();
  bool present = true;

  @override
  void initState() {
    super.initState();
    selectedSubjectId = widget.subjects.first.attendanceId;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Attendance'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              initialValue: selectedSubjectId,
              decoration: const InputDecoration(labelText: 'Subject'),
              items: widget.subjects
                  .map(
                    (subject) => DropdownMenuItem(
                      value: subject.attendanceId,
                      child: Text(subject.subject),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() => selectedSubjectId = value);
                }
              },
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () async {
                final pickedDate = await showDatePicker(
                  context: context,
                  initialDate: selectedDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2100),
                );
                if (pickedDate != null) {
                  setState(() => selectedDate = pickedDate);
                }
              },
              icon: const Icon(Icons.calendar_today_rounded, size: 18),
              label: Text(_formatAttendanceDate(selectedDate)),
            ),
            const SizedBox(height: 8),
            const Text(
              'Attendance status',
              style: TextStyle(
                color: AppColors.grey,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment<bool>(
                  value: true,
                  label: Text('Present'),
                  icon: Icon(Icons.check_rounded),
                ),
                ButtonSegment<bool>(
                  value: false,
                  label: Text('Absent'),
                  icon: Icon(Icons.close_rounded),
                ),
              ],
              selected: {present},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                setState(() => present = selection.first);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.pop(
              context,
              AttendanceEntry(
                subjectId: selectedSubjectId,
                date: selectedDate,
                present: present,
              ),
            );
          },
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.pink,
            foregroundColor: Colors.white,
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

String _formatAttendanceDate(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

// ============================================================
// REPORTS
// ============================================================

class _ReportsPage extends StatelessWidget {
  final StudentGroup group;
  final Map<String, AttendanceRecord> records;

  const _ReportsPage({required this.group, required this.records});

  @override
  Widget build(BuildContext context) {
    final subjects = _attendanceSubjects(group);
    final hasRecords = records.values.any((record) => record.total > 0);

    if (!hasRecords) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(30),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Reports 📊',
              style: TextStyle(
                fontSize: 27,
                fontWeight: FontWeight.w800,
                color: AppColors.text,
              ),
            ),
            const SizedBox(height: 8),
            _ReportsGroupLabel(group: group),
            const SizedBox(height: 20),
            _SimpleCard(
              color: AppColors.lavender,
              child: const Row(
                children: [
                  Icon(
                    Icons.insert_chart_outlined_rounded,
                    color: AppColors.purple,
                    size: 30,
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      'No attendance records yet',
                      style: TextStyle(
                        color: AppColors.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    var presentClasses = 0;
    var totalClasses = 0;
    for (final subject in subjects) {
      final record = records[subject.attendanceId];
      if (record != null) {
        presentClasses += record.attended;
        totalClasses += record.total;
      }
    }

    final absentClasses = totalClasses - presentClasses;
    final overallPercentage = totalClasses == 0
        ? 0.0
        : presentClasses / totalClasses;
    final warningSubjects = subjects.where((subject) {
      final record = records[subject.attendanceId];
      return record != null &&
          record.total > 0 &&
          record.percentage * 100 < attendanceWarningPercentage;
    }).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Reports 📊',
            style: TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 8),
          _ReportsGroupLabel(group: group),
          const SizedBox(height: 20),

          _SimpleCard(
            color: AppColors.blue,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Overall Attendance',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${_formatPercentage(overallPercentage * 100)}%',
                  style: const TextStyle(
                    color: AppColors.blueDark,
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: overallPercentage,
                  minHeight: 10,
                  borderRadius: BorderRadius.circular(10),
                  color: AppColors.pink,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 10),
                Text(
                  '$presentClasses present  •  $totalClasses total classes',
                  style: const TextStyle(color: AppColors.grey),
                ),
              ],
            ),
          ),

          const SizedBox(height: 25),
          const Text(
            'Present vs Absent',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final stackCards = constraints.maxWidth < 620;
              final cardWidth = stackCards
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 18) / 2;
              final cards = [
                SizedBox(
                  width: cardWidth,
                  child: _ReportCard(
                    title: 'Present classes',
                    value: '$presentClasses',
                    color: AppColors.mint,
                    icon: Icons.check_circle_rounded,
                  ),
                ),
                SizedBox(
                  width: cardWidth,
                  child: _ReportCard(
                    title: 'Absent classes',
                    value: '$absentClasses',
                    color: AppColors.lightPink,
                    icon: Icons.cancel_rounded,
                  ),
                ),
              ];

              return stackCards
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        cards[0],
                        const SizedBox(height: 12),
                        cards[1],
                      ],
                    )
                  : Wrap(spacing: 18, runSpacing: 12, children: cards);
            },
          ),

          const SizedBox(height: 25),
          const Text(
            'Subject-wise Attendance',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 12),
          ...subjects.map(
            (subject) => _AttendanceSubject(
              subject: subject,
              record: records[subject.attendanceId]!,
            ),
          ),

          const SizedBox(height: 18),
          _MonthlyAttendanceTrend(records: records),

          const SizedBox(height: 18),
          Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () => _exportAttendanceCsv(context, group, records),
                icon: const Icon(Icons.table_view_rounded),
                label: const Text('Export CSV'),
              ),
              OutlinedButton.icon(
                onPressed: () => _exportAttendancePdf(context, group, records),
                icon: const Icon(Icons.picture_as_pdf_rounded),
                label: const Text('Export PDF'),
              ),
            ],
          ),

          const SizedBox(height: 10),
          _ReportsWarningCard(subjects: warningSubjects),
        ],
      ),
    );
  }
}

class _ReportsGroupLabel extends StatelessWidget {
  final StudentGroup group;

  const _ReportsGroupLabel({required this.group});

  @override
  Widget build(BuildContext context) {
    return Text(
      group == StudentGroup.g1 ? 'G1 • Data Science / CSE' : 'G2 • AI / ML',
      style: const TextStyle(
        color: AppColors.purple,
        fontWeight: FontWeight.w600,
      ),
    );
  }
}

class _ReportsWarningCard extends StatelessWidget {
  final List<TimetableClass> subjects;

  const _ReportsWarningCard({required this.subjects});

  @override
  Widget build(BuildContext context) {
    return _SimpleCard(
      color: subjects.isEmpty ? AppColors.mint : AppColors.peach,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                subjects.isEmpty
                    ? Icons.check_circle_outline_rounded
                    : Icons.warning_amber_rounded,
                color: subjects.isEmpty ? AppColors.green : AppColors.orange,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Text(
                  'Attendance warnings',
                  style: TextStyle(
                    color: AppColors.text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            subjects.isEmpty
                ? 'All subjects are at or above the ${attendanceWarningPercentage.round()}% warning level.'
                : 'Below the ${attendanceWarningPercentage.round()}% warning level:',
            style: const TextStyle(color: AppColors.grey),
          ),
          if (subjects.isNotEmpty) ...[
            const SizedBox(height: 8),
            ...subjects.map(
              (subject) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• ${subject.subject}  ·  ${subject.teacher}',
                  style: const TextStyle(
                    color: AppColors.orange,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final String title;
  final String value;
  final Color color;
  final IconData icon;

  const _ReportCard({
    required this.title,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return _SimpleCard(
      color: color,
      child: Row(
        children: [
          Icon(icon, color: AppColors.purple, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: AppColors.grey)),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: AppColors.text,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// CALCULATOR
// ============================================================

class _CalculatorPage extends StatefulWidget {
  final StudentGroup group;
  final Map<String, AttendanceRecord> records;

  const _CalculatorPage({required this.group, required this.records});

  @override
  State<_CalculatorPage> createState() => _CalculatorPageState();
}

class _CalculatorPageState extends State<_CalculatorPage> {
  late final TextEditingController attendController;
  late final TextEditingController missController;
  int targetPercentage = 85;

  @override
  void initState() {
    super.initState();
    attendController = TextEditingController(text: '5');
    missController = TextEditingController(text: '5');
  }

  @override
  void dispose() {
    attendController.dispose();
    missController.dispose();
    super.dispose();
  }

  int _readNonNegative(TextEditingController controller) {
    final value = int.tryParse(controller.text.trim()) ?? 0;
    return value < 0 ? 0 : value;
  }

  @override
  Widget build(BuildContext context) {
    var attended = 0;
    var total = 0;
    for (final record in widget.records.values) {
      attended += record.attended;
      total += record.total;
    }

    final currentPercentage = _attendancePercentage(attended, total);
    final upcomingAttended = _readNonNegative(attendController);
    final upcomingMissed = _readNonNegative(missController);
    final attendFuturePercentage = _attendancePercentage(
      attended + upcomingAttended,
      total + upcomingAttended,
    );
    final missFuturePercentage = _attendancePercentage(
      attended,
      total + upcomingMissed,
    );
    final targetClasses = _classesToReachTarget(
      attended,
      total,
      targetPercentage,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Attendance Calculator ✨',
            style: TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.group == StudentGroup.g1
                ? 'G1 • Data Science / CSE'
                : 'G2 • AI / ML',
            style: const TextStyle(
              color: AppColors.purple,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 20),
          _SimpleCard(
            color: AppColors.blue,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Current Attendance',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '${_formatPercentage(currentPercentage)}%',
                  style: const TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: AppColors.blueDark,
                  ),
                ),
                const SizedBox(height: 10),
                LinearProgressIndicator(
                  value: currentPercentage / 100,
                  minHeight: 10,
                  borderRadius: BorderRadius.circular(10),
                  color: AppColors.pink,
                  backgroundColor: Colors.white,
                ),
                const SizedBox(height: 10),
                Text(
                  '$attended present classes  •  $total total classes',
                  style: const TextStyle(color: AppColors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          LayoutBuilder(
            builder: (context, constraints) {
              final cardWidth = constraints.maxWidth >= 620
                  ? (constraints.maxWidth - 18) / 2
                  : constraints.maxWidth;

              return Wrap(
                spacing: 18,
                runSpacing: 18,
                children: [
                  SizedBox(
                    width: cardWidth,
                    child: _ProjectionCard(
                      title: 'If I Attend Next Classes',
                      color: AppColors.lavender,
                      icon: Icons.check_circle_outline_rounded,
                      controller: attendController,
                      result: attendFuturePercentage,
                      explanation:
                          'Attend $upcomingAttended upcoming classes → your attendance would become ${_formatPercentage(attendFuturePercentage)}%.',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  SizedBox(
                    width: cardWidth,
                    child: _ProjectionCard(
                      title: 'If I Miss Next Classes',
                      color: AppColors.lightPink,
                      icon: Icons.cancel_outlined,
                      controller: missController,
                      result: missFuturePercentage,
                      explanation:
                          'Miss $upcomingMissed upcoming classes → your attendance would become ${_formatPercentage(missFuturePercentage)}%.',
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          _SimpleCard(
            color: AppColors.mint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Reach Target Attendance',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<int>(
                  initialValue: targetPercentage,
                  decoration: const InputDecoration(
                    labelText: 'Target percentage',
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  items: [75, 80, 85, 90]
                      .map(
                        (target) => DropdownMenuItem(
                          value: target,
                          child: Text('$target%'),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => targetPercentage = value);
                    }
                  },
                ),
                const SizedBox(height: 14),
                Text(
                  targetClasses == null
                      ? 'This target cannot be reached with consecutive attended classes.'
                      : targetClasses == 0
                      ? 'You have already reached this target.'
                      : 'You need to attend $targetClasses consecutive classes to reach $targetPercentage%.',
                  style: const TextStyle(
                    color: AppColors.purple,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

double _attendancePercentage(int attended, int total) {
  if (total == 0) {
    return 0;
  }
  return attended / total * 100;
}

String _formatPercentage(double percentage) {
  return percentage.toStringAsFixed(2);
}

int? _classesToReachTarget(int attended, int total, int target) {
  final currentPercentage = _attendancePercentage(attended, total);
  if (currentPercentage >= target) {
    return 0;
  }
  if (target >= 100) {
    return null;
  }

  final divisor = 100 - target;
  final deficit = target * total - 100 * attended;
  var classes = deficit <= 0 ? 0 : (deficit + divisor - 1) ~/ divisor;

  if (total == 0 && classes == 0) {
    classes = 1;
  }
  return classes;
}

class _ProjectionCard extends StatelessWidget {
  final String title;
  final Color color;
  final IconData icon;
  final TextEditingController controller;
  final double result;
  final String explanation;
  final ValueChanged<String> onChanged;

  const _ProjectionCard({
    required this.title,
    required this.color,
    required this.icon,
    required this.controller,
    required this.result,
    required this.explanation,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _SimpleCard(
      color: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: AppColors.purple, size: 26),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            onChanged: onChanged,
            decoration: const InputDecoration(
              labelText: 'Upcoming classes',
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            '${_formatPercentage(result)}%',
            style: const TextStyle(
              color: AppColors.pink,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          LinearProgressIndicator(
            value: result / 100,
            minHeight: 9,
            borderRadius: BorderRadius.circular(10),
            color: AppColors.pink,
            backgroundColor: Colors.white,
          ),
          const SizedBox(height: 10),
          Text(
            explanation,
            style: const TextStyle(color: AppColors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// PROFILE
// ============================================================

class _ProfilePage extends StatefulWidget {
  const _ProfilePage();

  @override
  State<_ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<_ProfilePage> {
  final nameController = TextEditingController();
  final rollController = TextEditingController();
  final courseController = TextEditingController();
  final sectionController = TextEditingController();
  final sessionController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final settings = appSettingsNotifier.value;
    nameController.text = settings.studentName;
    rollController.text = settings.rollNumber;
    courseController.text = settings.course;
    sectionController.text = settings.section;
    sessionController.text = settings.academicSession;
  }

  @override
  void dispose() {
    nameController.dispose();
    rollController.dispose();
    courseController.dispose();
    sectionController.dispose();
    sessionController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final old = appSettingsNotifier.value;
    await _saveSettings(
      old.copyWith(
        studentName: nameController.text.trim(),
        rollNumber: rollController.text.trim(),
        course: courseController.text.trim(),
        section: sectionController.text.trim(),
        academicSession: sessionController.text.trim(),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Profile saved ✨')));
  }

  @override
  Widget build(BuildContext context) {
    final settings = appSettingsNotifier.value;
    final initials = settings.studentName.trim().isEmpty
        ? '♡'
        : settings.studentName
              .trim()
              .split(RegExp(r'\s+'))
              .map((e) => e[0])
              .take(2)
              .join()
              .toUpperCase();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Student Profile 👤',
            style: TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 18),
          _SimpleCard(
            color: AppColors.lightPink,
            child: Row(
              children: [
                CircleAvatar(
                  radius: 38,
                  backgroundColor: Colors.white,
                  child: Text(
                    initials,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: AppColors.pink,
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        settings.studentName.isEmpty
                            ? 'Your Name'
                            : settings.studentName,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          color: AppColors.text,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        settings.rollNumber.isEmpty
                            ? 'Add your roll number'
                            : settings.rollNumber,
                        style: const TextStyle(color: AppColors.grey),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _profileField(nameController, 'Student name', Icons.person_outline),
          _profileField(rollController, 'Roll number', Icons.badge_outlined),
          _profileField(
            courseController,
            'Course / Semester',
            Icons.school_outlined,
          ),
          _profileField(sectionController, 'Section', Icons.groups_outlined),
          _profileField(
            sessionController,
            'Academic session',
            Icons.event_outlined,
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Save Profile'),
          ),
        ],
      ),
    );
  }

  Widget _profileField(
    TextEditingController controller,
    String label,
    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }
}

// ============================================================
// ATTENDANCE CALENDAR
// ============================================================

class _AttendanceCalendarPage extends StatefulWidget {
  final StudentGroup group;
  final Map<String, AttendanceRecord> records;

  const _AttendanceCalendarPage({required this.group, required this.records});

  @override
  State<_AttendanceCalendarPage> createState() =>
      _AttendanceCalendarPageState();
}

class _AttendanceCalendarPageState extends State<_AttendanceCalendarPage> {
  late DateTime month;
  DateTime selectedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    month = DateTime(now.year, now.month);
  }

  Map<DateTime, bool> get _dayStatuses {
    final result = <DateTime, bool>{};
    for (final record in widget.records.values) {
      for (final entry in record.entries.entries) {
        final day = DateTime(entry.key.year, entry.key.month, entry.key.day);
        result[day] = (result[day] ?? true) && entry.value;
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final statuses = _dayStatuses;
    final firstDay = DateTime(month.year, month.month, 1);
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final leading = firstDay.weekday - 1;
    final cells = <Widget>[];
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

    for (final day in weekdays) {
      cells.add(
        Center(
          child: Text(
            day,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppColors.purple,
            ),
          ),
        ),
      );
    }
    for (var i = 0; i < leading; i++) {
      cells.add(const SizedBox());
    }
    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime(month.year, month.month, day);
      final normalized = DateTime(date.year, date.month, date.day);
      final status = statuses[normalized];
      final selected =
          normalized ==
          DateTime(selectedDate.year, selectedDate.month, selectedDate.day);
      cells.add(
        GestureDetector(
          onTap: () => setState(() => selectedDate = normalized),
          child: Container(
            margin: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: selected ? AppColors.lavender : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: status == null
                    ? const Color(0xFFF0E5EC)
                    : (status ? AppColors.green : AppColors.pink),
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$day',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                if (status != null)
                  Icon(
                    status ? Icons.check_circle_rounded : Icons.cancel_rounded,
                    size: 15,
                    color: status ? AppColors.green : AppColors.pink,
                  ),
              ],
            ),
          ),
        ),
      );
    }

    final selectedEvents = <String>[];
    for (final entry in widget.records.entries) {
      for (final event in entry.value.entries.entries) {
        if (event.key.year == selectedDate.year &&
            event.key.month == selectedDate.month &&
            event.key.day == selectedDate.day) {
          selectedEvents.add(
            '${_displaySubjectName(entry.key)} • ${event.value ? 'Present' : 'Absent'}',
          );
        }
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.only(left: 30, right: 30, top: 68, bottom: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Attendance Calendar 📅',
            style: TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.group == StudentGroup.g1
                ? 'G1 • Data Science / CSE'
                : 'G2 • AI / ML',
            style: const TextStyle(
              color: AppColors.purple,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 18),
          _SimpleCard(
            color: AppColors.blue,
            child: Row(
              children: [
                IconButton(
                  onPressed: () => setState(
                    () => month = DateTime(month.year, month.month - 1),
                  ),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: Center(
                    child: Text(
                      '${_monthName(month.month)} ${month.year}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        color: AppColors.text,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(
                    () => month = DateTime(month.year, month.month + 1),
                  ),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _SimpleCard(
            color: AppColors.lavender,
            child: GridView.count(
              crossAxisCount: 7,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              childAspectRatio: 1.15,
              children: cells,
            ),
          ),
          const SizedBox(height: 14),
          _SimpleCard(
            color: AppColors.mint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Selected: ${selectedDate.day} ${_monthName(selectedDate.month)} ${selectedDate.year}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 10),
                if (selectedEvents.isEmpty)
                  const Text(
                    'No attendance event recorded for this date.',
                    style: TextStyle(color: AppColors.grey),
                  )
                else
                  ...selectedEvents.map(
                    (e) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '• $e',
                        style: const TextStyle(
                          color: AppColors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _monthName(int month) {
  const names = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return names[month - 1];
}

// ============================================================
// REPORT TREND + EXPORT
// ============================================================

class _MonthlyAttendanceTrend extends StatelessWidget {
  final Map<String, AttendanceRecord> records;
  const _MonthlyAttendanceTrend({required this.records});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final months = List.generate(
      6,
      (index) => DateTime(now.year, now.month - 5 + index, 1),
    );
    final values = months.map((month) {
      var present = 0;
      var total = 0;
      for (final record in records.values) {
        for (final entry in record.entries.entries) {
          if (entry.key.year == month.year && entry.key.month == month.month) {
            total++;
            if (entry.value) present++;
          }
        }
      }
      return total == 0 ? null : present / total * 100;
    }).toList();

    return _SimpleCard(
      color: AppColors.lavender,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Monthly Attendance Trend',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 170,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: List.generate(months.length, (i) {
                final value = values[i];
                final height = value == null
                    ? 12.0
                    : (value.clamp(0, 100) * 1.25).toDouble();
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Text(
                          value == null ? '—' : '${value.toStringAsFixed(0)}%',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.grey,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          height: height,
                          decoration: BoxDecoration(
                            color: value == null
                                ? Colors.white
                                : AppColors.pink,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _monthName(months[i].month).substring(0, 3),
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.text,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Based on attendance events you have recorded in the selected group.',
            style: TextStyle(color: AppColors.grey, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

String _displaySubjectName(String id) {
  for (final subject in _attendanceSubjects(StudentGroup.g1)) {
    if (subject.attendanceId == id) return subject.subject;
  }
  return id;
}

Future<void> _exportAttendanceCsv(
  BuildContext context,
  StudentGroup group,
  Map<String, AttendanceRecord> records,
) async {
  try {
    final desktop = Directory(
      _joinPath(
        Platform.environment['USERPROFILE'] ?? Directory.current.path,
        'Desktop',
      ),
    );
    await desktop.create(recursive: true);
    final groupName = group == StudentGroup.g1
        ? 'G1_Data_Science_CSE'
        : 'G2_AI_ML';
    final file = File(_joinPath(desktop.path, 'attendance_$groupName.csv'));
    final buffer = StringBuffer('Subject,Present,Total,Percentage\n');
    for (final subject in _attendanceSubjects(group)) {
      final record = records[subject.attendanceId];
      if (record == null) continue;
      buffer.writeln(
        '"${subject.subject.replaceAll('"', '""')}",${record.attended},${record.total},${(record.percentage * 100).toStringAsFixed(2)}',
      );
    }
    await file.writeAsString(buffer.toString());
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('CSV exported to ${file.path}')));
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('CSV export failed: $error')));
  }
}

String _pdfEscape(String value) =>
    value.replaceAll('\\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');

Future<void> _exportAttendancePdf(
  BuildContext context,
  StudentGroup group,
  Map<String, AttendanceRecord> records,
) async {
  try {
    final desktop = Directory(
      _joinPath(
        Platform.environment['USERPROFILE'] ?? Directory.current.path,
        'Desktop',
      ),
    );
    await desktop.create(recursive: true);
    final groupName = group == StudentGroup.g1
        ? 'G1_Data_Science_CSE'
        : 'G2_AI_ML';
    final file = File(_joinPath(desktop.path, 'attendance_$groupName.pdf'));
    final lines = <String>[
      'Attendance Tracker',
      group == StudentGroup.g1 ? 'G1 - Data Science / CSE' : 'G2 - AI / ML',
      'Generated: ${DateTime.now().toLocal()}',
      '',
      'Subject                 Present  Total  Percentage',
      '---------------------------------------------------',
      ..._attendanceSubjects(group).map((subject) {
        final record = records[subject.attendanceId];
        if (record == null) return subject.subject;
        return '${subject.subject.padRight(24).substring(0, subject.subject.length > 24 ? 24 : subject.subject.length).padRight(24)} ${record.attended.toString().padLeft(7)} ${record.total.toString().padLeft(6)} ${(record.percentage * 100).toStringAsFixed(2)}%';
      }),
    ];
    final content = StringBuffer('BT\n/F1 10 Tf\n50 760 Td\n');
    for (final line in lines) {
      content.write('(${_pdfEscape(line)}) Tj\n0 -15 Td\n');
    }
    content.write('ET');
    final stream = content.toString();
    final objects = <String>[
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
      '<< /Length ${stream.length} >>\nstream\n$stream\nendstream',
    ];
    final bytes = BytesBuilder();
    bytes.add(Uint8List.fromList('%PDF-1.4\n'.codeUnits));
    final offsets = <int>[0];
    for (var i = 0; i < objects.length; i++) {
      offsets.add(bytes.length);
      bytes.add(
        Uint8List.fromList('${i + 1} 0 obj\n${objects[i]}\nendobj\n'.codeUnits),
      );
    }
    final xref = bytes.length;
    bytes.add(
      Uint8List.fromList(
        'xref\n0 ${objects.length + 1}\n0000000000 65535 f \n'.codeUnits,
      ),
    );
    for (var i = 1; i < offsets.length; i++) {
      bytes.add(
        Uint8List.fromList(
          '${offsets[i].toString().padLeft(10, '0')} 00000 n \n'.codeUnits,
        ),
      );
    }
    bytes.add(
      Uint8List.fromList(
        'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF'
            .codeUnits,
      ),
    );
    await file.writeAsBytes(bytes.takeBytes());
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('PDF exported to ${file.path}')));
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('PDF export failed: $error')));
  }
}

// ============================================================
// SETTINGS
// ============================================================

class _SettingsPage extends StatefulWidget {
  final Future<void> Function() onDataRestored;

  const _SettingsPage({required this.onDataRestored});

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  @override
  void initState() {
    super.initState();
    appSettingsNotifier.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    appSettingsNotifier.removeListener(_onSettingsChanged);
    super.dispose();
  }

  Future<void> _editReminder() async {
    final settings = appSettingsNotifier.value;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: settings.reminderHour,
        minute: settings.reminderMinute,
      ),
    );
    if (picked == null) return;
    await _saveSettings(
      settings.copyWith(
        reminderHour: picked.hour,
        reminderMinute: picked.minute,
      ),
    );
    if (mounted) setState(() {});
  }

  Future<void> _restoreDatabase() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore attendance backup?'),
        content: const Text(
          'This replaces the current local attendance database with the backup file from your Desktop. Continue only if that is what you want.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final desktop = Directory(
        _joinPath(
          Platform.environment['USERPROFILE'] ?? Directory.current.path,
          'Desktop',
        ),
      );
      final backup = File(_joinPath(desktop.path, 'attendance_tracker_backup.db'));
      if (!await backup.exists()) {
        throw Exception('No attendance_tracker_backup.db found on Desktop.');
      }
      final dbPath = await AttendanceDatabase.databasePath();
      await AttendanceDatabase.closeDatabase();
      await backup.copy(dbPath);
      await AttendanceDatabase.initialize();
      await widget.onDataRestored();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Attendance database restored successfully.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Restore failed: $error')));
    }
  }

  Future<void> _resetAttendance() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset attendance?'),
        content: const Text(
          'This resets attendance records for both G1 and G2 to the original starting values. Your profile and settings are kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final g1 = _defaultAttendanceRecords();
    final defaults = <StudentGroup, Map<String, AttendanceRecord>>{
      StudentGroup.g1: g1,
      StudentGroup.g2: Map.fromEntries(
        g1.entries.map((entry) => MapEntry(entry.key, entry.value.copy())),
      ),
    };
    await AttendanceDatabase.saveAllGroups(defaults);
    await widget.onDataRestored();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Attendance reset successfully.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = appSettingsNotifier.value;
    final reminderTime = TimeOfDay(
      hour: settings.reminderHour,
      minute: settings.reminderMinute,
    );

    return SingleChildScrollView(
      padding: const EdgeInsets.all(30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Settings ♡',
            style: TextStyle(
              fontSize: 27,
              fontWeight: FontWeight.w800,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 20),
          _SettingTile(
            icon: Icons.person_outline_rounded,
            title: 'Student Profile',
            subtitle: settings.studentName.isEmpty
                ? 'Not set yet'
                : '${settings.studentName} • ${settings.rollNumber}',
            color: AppColors.lightPink,
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => const _ProfilePage())),
          ),
          _SettingTile(
            icon: Icons.groups_outlined,
            title: 'Group',
            subtitle: 'G1 • Data Science / CSE  |  G2 • AI / ML',
            color: AppColors.lavender,
          ),
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(17),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: const Color(0xFFF0E5EC)),
            ),
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(
                Icons.notifications_active_outlined,
                color: AppColors.pink,
              ),
              title: const Text(
                'Attendance reminders',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
              subtitle: Text(
                'In-app reminder at ${reminderTime.format(context)}',
                style: const TextStyle(color: AppColors.grey, fontSize: 12),
              ),
              value: settings.remindersEnabled,
              onChanged: (value) async {
                await _saveSettings(settings.copyWith(remindersEnabled: value));
                if (mounted) setState(() {});
              },
            ),
          ),
          _SettingTile(
            icon: Icons.schedule_rounded,
            title: 'Reminder time',
            subtitle: reminderTime.format(context),
            color: AppColors.blue,
            onTap: _editReminder,
          ),
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(17),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: const Color(0xFFF0E5EC)),
            ),
            child: SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(
                Icons.dark_mode_outlined,
                color: AppColors.purple,
              ),
              title: const Text(
                'Dark mode',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                ),
              ),
              subtitle: const Text(
                'Use a darker app appearance',
                style: TextStyle(color: AppColors.grey, fontSize: 12),
              ),
              value: settings.darkMode,
              onChanged: (value) {
                unawaited(_saveSettings(settings.copyWith(darkMode: value)));
              },
            ),
          ),
          _SettingTile(
            icon: Icons.warning_amber_rounded,
            title: 'Warning Percentage',
            subtitle: 'Current: ${settings.warningPercentage}%',
            color: AppColors.peach,
            onTap: () async {
              final controller = TextEditingController(
                text: '${settings.warningPercentage}',
              );
              final value = await showDialog<int>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Warning percentage'),
                  content: TextField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Percentage',
                      suffixText: '%',
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(
                        context,
                        int.tryParse(controller.text.trim()),
                      ),
                      child: const Text('Save'),
                    ),
                  ],
                ),
              );
              controller.dispose();
              if (value != null && value >= 1 && value <= 100) {
                await _saveSettings(
                  settings.copyWith(warningPercentage: value),
                );
                if (mounted) setState(() {});
              }
            },
          ),
          const SizedBox(height: 10),
          const Text(
            'Data Management',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 10),
          _SettingTile(
            icon: Icons.restore_outlined,
            title: 'Restore attendance database',
            subtitle: 'Restore attendance_tracker_backup.db from Desktop',
            color: AppColors.yellow,
            onTap: _restoreDatabase,
          ),
          _SettingTile(
            icon: Icons.restart_alt_rounded,
            title: 'Reset attendance',
            subtitle: 'Restore both groups to their starting attendance values',
            color: AppColors.peach,
            onTap: _resetAttendance,
          ),
          _SettingTile(
            icon: Icons.info_outline_rounded,
            title: 'App information',
            subtitle: 'Attendance Tracker • Windows desktop app',
            color: AppColors.blue,
            onTap: () => showAboutDialog(
              context: context,
              applicationName: 'Attendance Tracker',
              applicationVersion: '1.0.0',
              applicationLegalese: 'Personal offline attendance tracker',
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final VoidCallback? onTap;

  const _SettingTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(17),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(19),
          border: Border.all(color: const Color(0xFFF0E5EC)),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: AppColors.purple),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(color: AppColors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: AppColors.grey),
          ],
        ),
      ),
    );
  }
}
