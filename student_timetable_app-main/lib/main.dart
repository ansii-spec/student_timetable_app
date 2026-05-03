import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

// --- Design tokens (60 / 30 / 10) -------------------------------------------------
const Color kBg = Color(0xFFFAFAFA);
const Color kFastBlue = Color(0xFF0D47A1);
const Color kAccentGold = Color(0xFFFFC107);
/// Phase 2 dark scaffold (“Cool Charcoal”).
const Color kDarkBg = Color(0xFF2D3436);
const Color kDarkSurface = Color(0xFF363E47);

String get kApiBaseUrl {
  // If running in a web browser on your PC
  if (kIsWeb) {
    return 'http://localhost:8000';
  }
  
  // If running on an Android device (Emulator or Physical phone)
  if (!kIsWeb && Platform.isAndroid) {
    // ⚠️ Replace 10.0.2.2 with your computer's exact Local Wi-Fi IP address
    return 'http://192.168.18.105:8000';
  }
  
  return 'http://localhost:8000';
}

/// Hosted domain for Google Sign-In (must match sign-out configuration).
const String kAllowedGoogleDomain = 'pwr.nu.edu.pk';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

GoogleSignIn createAppGoogleSignIn() => GoogleSignIn(
      scopes: <String>['email'],
      hostedDomain: kAllowedGoogleDomain,
    );

// --- Session persistence (SharedPreferences) -------------------------------------
const String kPrefLoggedIn = 'is_logged_in';
const String kPrefUserName = 'user_name';
const String kPrefUserEmail = 'user_email';
const String kPrefUserRoll = 'user_roll';
const String kPrefUserPic = 'user_pic';
const String kPrefLocalPicPath = 'user_pic_local_path';

/// Persists Bright White vs Cool Charcoal theme (SharedPreferences).
class ThemeService extends ChangeNotifier {
  ThemeService._();
  static final ThemeService instance = ThemeService._();

  ThemeMode _mode = ThemeMode.light;

  ThemeMode get mode => _mode;

  bool get isDark => _mode == ThemeMode.dark;

  Future<void> load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool dark = prefs.getBool('theme_dark') ?? false;
    _mode = dark ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
  }

  Future<void> setDark(bool value) async {
    _mode = value ? ThemeMode.dark : ThemeMode.light;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('theme_dark', value);
  }
}

final ThemeService themeService = ThemeService.instance;

ThemeData buildAppLightTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: kFastBlue,
    brightness: Brightness.light,
    primary: kFastBlue,
    surface: kBg,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: kFastBlue,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
  );
}

ThemeData buildAppDarkTheme() {
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: kFastBlue,
    brightness: Brightness.dark,
    primary: kFastBlue,
    surface: kDarkSurface,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kDarkBg,
    appBarTheme: const AppBarTheme(
      backgroundColor: kDarkBg,
      foregroundColor: Colors.white,
      elevation: 0,
    ),
    cardTheme: CardThemeData(color: kDarkSurface.withValues(alpha: 0.95)),
  );
}

/// Timetable JSON cache per roll number (SharedPreferences).
String timetableCacheKey(String rollNumber) => 'cached_timetable_$rollNumber';
String theoryExamsCacheKey(String rollNumber) =>
    'cached_theory_exams_$rollNumber';

TimetablePayload? parseTimetablePayloadFromJsonString(String raw) {
  try {
    final dynamic decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    return TimetablePayload.fromJson(decoded);
  } catch (_) {
    return null;
  }
}

Future<void> persistLoginSession(StudentProfile profile) async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.setBool(kPrefLoggedIn, true);
  await prefs.setString(kPrefUserName, profile.displayName);
  await prefs.setString(kPrefUserEmail, profile.email);
  await prefs.setString(kPrefUserRoll, profile.rollNumber);
  await prefs.setString(kPrefUserPic, profile.photoUrl ?? '');
  if (profile.localPhotoPath != null && profile.localPhotoPath!.isNotEmpty) {
    await prefs.setString(kPrefLocalPicPath, profile.localPhotoPath!);
  } else {
    await prefs.remove(kPrefLocalPicPath);
  }
}

Future<StudentProfile?> loadSavedSessionProfile() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(kPrefLoggedIn) != true) {
    return null;
  }
  final String? email = prefs.getString(kPrefUserEmail);
  final String? roll = prefs.getString(kPrefUserRoll);
  if (email == null || email.isEmpty || roll == null || roll.isEmpty) {
    return null;
  }
  final String? picRaw = prefs.getString(kPrefUserPic);
  final String? rawName = prefs.getString(kPrefUserName);
  final String displayName =
      (rawName != null && rawName.trim().isNotEmpty) ? rawName.trim() : 'Student';
  final String? localPath = prefs.getString(kPrefLocalPicPath);
  return StudentProfile(
    displayName: displayName,
    email: email.trim(),
    rollNumber: roll.trim(),
    photoUrl: (picRaw != null && picRaw.isNotEmpty) ? picRaw : null,
    localPhotoPath:
        (localPath != null && localPath.isNotEmpty) ? localPath : null,
  );
}

/// Signs out of Google, clears all local preferences, and resets navigation to [AuthGate].
Future<void> performSignOutAndNavigateToLogin() async {
  final GoogleSignIn googleSignIn = createAppGoogleSignIn();
  await googleSignIn.signOut();
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.clear();
  await themeService.load();
  final NavigatorState? nav = rootNavigatorKey.currentState;
  if (nav == null) {
    return;
  }
  nav.pushAndRemoveUntil(
    MaterialPageRoute<void>(builder: (_) => const AuthGate()),
    (Route<dynamic> route) => false,
  );
}

// --- Models -----------------------------------------------------------------------
class StudentProfile {
  const StudentProfile({
    required this.displayName,
    required this.rollNumber,
    required this.email,
    this.photoUrl,
    this.localPhotoPath,
  });

  final String displayName;
  final String rollNumber;
  final String email;
  final String? photoUrl;
  final String? localPhotoPath;
}

class ScheduleEntry {
  const ScheduleEntry({
    required this.day,
    required this.location,
    required this.timeSlot,
    required this.courseCode,
    required this.subject,
    required this.teacher,
    required this.batch,
  });

  factory ScheduleEntry.fromJson(Map<String, dynamic> json) {
    return ScheduleEntry(
      day: json['day'] as String,
      location: json['location'] as String,
      timeSlot: json['time_slot'] as String,
      courseCode: json['course_code'] as String,
      subject: json['subject'] as String,
      teacher: json['teacher'] as String,
      batch: json['batch'] as String,
    );
  }

  final String day;
  final String location;
  final String timeSlot;
  final String courseCode;
  final String subject;
  final String teacher;
  final String batch;
}

class TimetablePayload {
  const TimetablePayload({required this.rollnumber, required this.schedule});

  factory TimetablePayload.fromJson(Map<String, dynamic> json) {
    final raw = json['schedule'] as List<dynamic>? ?? <dynamic>[];
    final List<ScheduleEntry> list = raw
        .map((e) => ScheduleEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    list.sort((ScheduleEntry a, ScheduleEntry b) {
      final int dayCmp =
          weekdaySortKey(a.day).compareTo(weekdaySortKey(b.day));
      if (dayCmp != 0) {
        return dayCmp;
      }
      return startMinutesFromTimeSlot(a.timeSlot)
          .compareTo(startMinutesFromTimeSlot(b.timeSlot));
    });
    return TimetablePayload(
      rollnumber: json['rollnumber'] as String,
      schedule: list,
    );
  }

  final String rollnumber;
  final List<ScheduleEntry> schedule;
}

class ExamEntry {
  const ExamEntry({
    required this.date,
    required this.venue,
    required this.time,
    required this.courseCode,
    required this.batch,
    required this.subject,
    required this.teacher,
    this.codeWithSection,
    this.extendedTime,
  });

  factory ExamEntry.fromJson(Map<String, dynamic> json) {
    return ExamEntry(
      date: (json['date'] as String? ?? '').trim(),
      venue: (json['venue'] as String? ?? '').trim(),
      time: (json['time'] as String? ?? '').trim(),
      courseCode: (json['course_code'] as String? ?? '').trim(),
      batch: (json['batch'] as String? ?? '').trim(),
      subject: (json['subject'] as String? ?? '').trim(),
      teacher: (json['teacher'] as String? ?? '').trim(),
      codeWithSection: (json['code_with_section'] as String?)?.trim(),
      extendedTime: (json['extended_time'] as String?)?.trim(),
    );
  }

  final String date;
  final String venue;
  final String time;
  final String courseCode;
  final String batch;
  final String subject;
  final String teacher;
  final String? codeWithSection;
  final String? extendedTime;
}

class ExamsPayload {
  const ExamsPayload({required this.labExams, required this.theoryExams});

  final List<ExamEntry> labExams;
  final List<TheoryExamEntry> theoryExams;
}

class TheoryExamEntry {
  const TheoryExamEntry({
    required this.courseCode,
    required this.courseName,
    required this.examDate,
    required this.startTime,
    required this.endTime,
  });

  factory TheoryExamEntry.fromJson(Map<String, dynamic> json) {
    return TheoryExamEntry(
      courseCode: (json['course_code'] as String? ?? '').trim(),
      courseName: (json['course_name'] as String? ?? '').trim(),
      examDate: (json['exam_date'] as String? ?? '').trim(),
      startTime: (json['start_time'] as String? ?? '').trim(),
      endTime: (json['end_time'] as String? ?? '').trim(),
    );
  }

  final String courseCode;
  final String courseName;
  final String examDate;
  final String startTime;
  final String endTime;
}

// --- Time helpers -----------------------------------------------------------------
const List<String> kWeekdays = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
];

int _minutesNow(DateTime t) => t.hour * 60 + t.minute;

TimeOfDay? _parse12h(String part) {
  final RegExp rx = RegExp(
    r'^(\d{1,2}):(\d{2})\s*(AM|PM)$',
    caseSensitive: false,
  );
  final RegExpMatch? m = rx.firstMatch(part.trim());
  if (m == null) {
    return null;
  }
  int hour = int.parse(m.group(1)!);
  final int minute = int.parse(m.group(2)!);
  final String ap = m.group(3)!.toUpperCase();
  if (ap == 'AM') {
    if (hour == 12) {
      hour = 0;
    }
  } else {
    if (hour != 12) {
      hour += 12;
    }
  }
  return TimeOfDay(hour: hour, minute: minute);
}

({int start, int end})? parseTimeSlotRange(String timeSlot) {
  final List<String> parts = timeSlot.split('-').map((e) => e.trim()).toList();
  if (parts.length != 2) {
    return null;
  }
  final TimeOfDay? a = _parse12h(parts[0]);
  final TimeOfDay? b = _parse12h(parts[1]);
  if (a == null || b == null) {
    return null;
  }
  return (start: a.hour * 60 + a.minute, end: b.hour * 60 + b.minute);
}

/// Minutes from midnight for the start of [timeSlot] (text before the first '-').
/// Used for chronological ordering; unparseable slots sort last.
int startMinutesFromTimeSlot(String timeSlot) {
  final String startPart = timeSlot.split('-').first.trim();
  final TimeOfDay? t = _parse12h(startPart);
  if (t == null) {
    return 24 * 60 + 1;
  }
  return t.hour * 60 + t.minute;
}

int weekdaySortKey(String dayName) {
  final int i = kWeekdays.indexOf(dayName);
  return i >= 0 ? i : 99;
}

const Map<int, String> kLabSlotToExtendedLabel = <int, String>{
  0: '08:00 AM - 11:00 AM',
  1: '09:30 AM - 12:30 PM',
  2: '11:00 AM - 02:00 PM',
  3: '12:30 PM - 03:30 PM',
  4: '02:00 PM - 05:00 PM',
  5: '03:30 PM - 06:30 PM',
};

const Map<String, int> kRegularSlotLabelToIndex = <String, int>{
  '08:00 AM - 09:30 AM': 0,
  '09:30 AM - 11:00 AM': 1,
  '11:00 AM - 12:30 PM': 2,
  '12:30 PM - 02:00 PM': 3,
  '02:00 PM - 03:30 PM': 4,
  '03:30 PM - 05:00 PM': 5,
  '05:00 PM - 06:30 PM': 6,
};

bool isLabCodeWithSection(String codeWithSection) {
  final List<String> parts = codeWithSection.split(',');
  if (parts.isEmpty) {
    return false;
  }
  final String baseCode = parts[0].trim();
  return baseCode.length >= 2 && baseCode[1].toUpperCase() == 'L';
}

String? sectionFromCodeWithSection(String codeWithSection) {
  final List<String> parts = codeWithSection.split(',');
  if (parts.length < 2) {
    return null;
  }
  final String section = parts[1].trim();
  return section.isEmpty ? null : section;
}

String extendedLabTimeFromRaw(String raw) {
  final String value = raw.trim();
  if (value.isEmpty) {
    return value;
  }
  final int? maybeSlot = int.tryParse(value);
  if (maybeSlot != null) {
    return kLabSlotToExtendedLabel[maybeSlot] ?? value;
  }
  final int? labelSlot = kRegularSlotLabelToIndex[value];
  if (labelSlot != null) {
    return kLabSlotToExtendedLabel[labelSlot] ?? value;
  }
  final RegExpMatch? m = RegExp(r'\d+').firstMatch(value);
  if (m != null) {
    final int? extracted = int.tryParse(m.group(0)!);
    if (extracted != null && kLabSlotToExtendedLabel.containsKey(extracted)) {
      return kLabSlotToExtendedLabel[extracted]!;
    }
  }
  return value;
}

bool isDuringSlot(DateTime now, String timeSlot) {
  final ({int start, int end})? range = parseTimeSlotRange(timeSlot);
  if (range == null) {
    return false;
  }
  final int n = _minutesNow(now);
  return n >= range.start && n < range.end;
}

String weekdayName(DateTime d) {
  const names = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  return names[d.weekday - 1];
}

int weekdayTabIndex(DateTime d) {
  final int idx = d.weekday - 1;
  if (idx < 0 || idx > 4) {
    return 0;
  }
  return idx;
}

// --- Phase 2: scheduled class reminders -----------------------------------------
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _channel = AndroidNotificationChannel(
    'class_reminders',
    'Class reminders',
    description: 'Alerts 10 minutes before each class slot starts.',
    importance: Importance.high,
  );

  Future<void> initialize() async {
    try {
      tzdata.initializeTimeZones();
      tz.setLocalLocation(tz.getLocation('Asia/Karachi'));

      const AndroidInitializationSettings androidInit =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const DarwinInitializationSettings iosInit =
          DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      await _plugin.initialize(
        const InitializationSettings(android: androidInit, iOS: iosInit),
      );

      final AndroidFlutterLocalNotificationsPlugin? androidPlugin =
          _plugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.createNotificationChannel(_channel);
      await androidPlugin?.requestNotificationsPermission();

      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {
      // Tests / desktop without full plugin support.
    }
  }

  /// Schedules weekly reminders 10 minutes before each class start.
  Future<void> scheduleClassReminders(List<ScheduleEntry> entries) async {
    try {
      await _plugin.cancelAll();
      if (entries.isEmpty) {
        return;
      }

      final NotificationDetails details = NotificationDetails(
        android: AndroidNotificationDetails(
          _channel.id,
          _channel.name,
          channelDescription: _channel.description,
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: const DarwinNotificationDetails(),
      );

      int scheduled = 0;
      for (final ScheduleEntry e in entries) {
        final ({int h, int m})? hm = _reminderHourMinute(e.timeSlot);
        if (hm == null) {
          continue;
        }
        final tz.TZDateTime next =
            _nextInstanceOfWeekdayTime(e.day, hm.h, hm.m);
        final int id = _notificationId(e);

        await _plugin.zonedSchedule(
          id,
          'Class starting soon',
          '${e.subject} · ${e.location}',
          next,
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation:
              UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        );
        scheduled++;
        if (scheduled >= 64) {
          break;
        }
      }
    } catch (_) {
      // Ignore scheduling failures (permissions / platform).
    }
  }

  ({int h, int m})? _reminderHourMinute(String timeSlot) {
    final String startPart = timeSlot.split('-').first.trim();
    final TimeOfDay? t = _parse12h(startPart);
    if (t == null) {
      return null;
    }
    final int mins = t.hour * 60 + t.minute - 10;
    if (mins < 0) {
      return null;
    }
    return (h: mins ~/ 60, m: mins % 60);
  }

  tz.TZDateTime _nextInstanceOfWeekdayTime(
    String dayName,
    int hour,
    int minute,
  ) {
    final int targetWd = _weekdayNumber(dayName);
    final tz.TZDateTime now = tz.TZDateTime.now(tz.local);
    tz.TZDateTime scheduled =
        tz.TZDateTime(tz.local, now.year, now.month, now.day, hour, minute);
    while (scheduled.weekday != targetWd) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    if (!scheduled.isAfter(now)) {
      scheduled = scheduled.add(const Duration(days: 7));
    }
    return scheduled;
  }

  int _weekdayNumber(String dayName) {
    switch (dayName) {
      case 'Monday':
        return DateTime.monday;
      case 'Tuesday':
        return DateTime.tuesday;
      case 'Wednesday':
        return DateTime.wednesday;
      case 'Thursday':
        return DateTime.thursday;
      case 'Friday':
        return DateTime.friday;
      default:
        return DateTime.monday;
    }
  }

  int _notificationId(ScheduleEntry e) {
    final int h =
        Object.hash(e.day, e.timeSlot, e.subject, e.location, e.courseCode);
    return h.abs() % 2147483646 + 1;
  }
}

// --- Phase 2: empty-room heuristic ----------------------------------------------
class RoomService {
  RoomService._();

  /// Representative FAST-NUCES venue labels (extend as needed).
  static const List<String> kAllCampusRooms = <String>[
    'Room 1',
    'Room 2',
    'Room 3',
    'Room 4',
    'Room 5',
    'Room 6',
    'Lab A',
    'Lab B',
    'Computer Lab 1',
    'Physics Lab',
    'Auditorium',
    'Seminar Hall',
    'Tutorial Room 1',
    'Tutorial Room 2',
    'Library Study Hall',
    'Faculty Lab',
  ];

  static Set<String> _busyNormalized(
    String weekday,
    String timeSlot,
    List<ScheduleEntry> schedule,
  ) {
    final Set<String> busy = <String>{};
    for (final ScheduleEntry e in schedule) {
      if (e.day == weekday && e.timeSlot == timeSlot) {
        busy.add(e.location.trim().toLowerCase());
      }
    }
    return busy;
  }

  /// Rooms in [kAllCampusRooms] not occupied in [schedule] for this slot.
  static List<String> availableRooms(
    String weekday,
    String timeSlot,
    List<ScheduleEntry> schedule,
  ) {
    final Set<String> busy = _busyNormalized(weekday, timeSlot, schedule);
    final List<String> free = <String>[];
    for (final String room in kAllCampusRooms) {
      final String key = room.trim().toLowerCase();
      bool taken = false;
      for (final String b in busy) {
        if (b == key || b.contains(key) || key.contains(b)) {
          taken = true;
          break;
        }
      }
      if (!taken) {
        free.add(room);
      }
    }
    return free;
  }
}

/// Saves Google profile photo to app documents for offline display.
Future<String?> cacheImageLocally(String? photoUrl) async {
  if (photoUrl == null || photoUrl.isEmpty || kIsWeb) {
    return null;
  }
  try {
    final http.Response res = await http
        .get(Uri.parse(photoUrl))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) {
      return null;
    }
    final Directory dir = await getApplicationDocumentsDirectory();
    final File file = File('${dir.path}/profile_avatar_cache.jpg');
    await file.writeAsBytes(res.bodyBytes, flush: true);
    return file.path;
  } catch (_) {
    return null;
  }
}

// --- API (network refresh used with local cache in MainShell._load) -------------

// --- App entry --------------------------------------------------------------------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.instance.initialize();
  await themeService.load();
  final StudentProfile? restoredProfile = await loadSavedSessionProfile();
  runApp(StudentTimetableApp(restoredProfile: restoredProfile));
}

class StudentTimetableApp extends StatelessWidget {
  const StudentTimetableApp({super.key, this.restoredProfile});

  final StudentProfile? restoredProfile;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeService,
      builder: (BuildContext context, Widget? _) {
        return MaterialApp(
          navigatorKey: rootNavigatorKey,
          title: 'Student Timetable',
          debugShowCheckedModeBanner: false,
          themeMode: themeService.mode,
          theme: buildAppLightTheme(),
          darkTheme: buildAppDarkTheme(),
          home: restoredProfile != null
              ? MainShell(
                  profile: restoredProfile!,
                  onLogout: performSignOutAndNavigateToLogin,
                )
              : const AuthGate(),
        );
      },
    );
  }
}

// --- Auth -------------------------------------------------------------------------
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final GoogleSignIn _googleSignIn = createAppGoogleSignIn();

  bool _busy = false;

  String _extractRollNumber(String email) {
    final String localPart = email.split('@').first.trim().toLowerCase();
    final RegExp formattedPattern = RegExp(r'^\d{2}[a-z]-\d{4}$');
    if (formattedPattern.hasMatch(localPart)) {
      return localPart.toUpperCase();
    }
    final RegExp fastEmailPattern = RegExp(r'^p(\d{6})$');
    final RegExpMatch? match = fastEmailPattern.firstMatch(localPart);
    if (match != null) {
      final String digits = match.group(1)!;
      final String batch = digits.substring(0, 2);
      final String serial = digits.substring(2, 6);
      return '${batch}P-$serial';
    }
    return localPart.toUpperCase();
  }

  Future<void> _continueWithGoogle() async {
    setState(() => _busy = true);
    try {
      final GoogleSignInAccount? account = await _googleSignIn.signIn();
      if (!mounted || account == null) {
        return;
      }
      final String email = account.email.toLowerCase().trim();
      if (!email.endsWith('@$kAllowedGoogleDomain')) {
        await _googleSignIn.signOut();
        if (!mounted) {
          return;
        }
        _toast(
          'Only @$kAllowedGoogleDomain accounts are allowed. You selected $email.',
          error: true,
        );
        return;
      }
      final String userName = (account.displayName ?? '').trim().isNotEmpty
          ? account.displayName!.trim()
          : 'Student';
      final String? localPath = await cacheImageLocally(account.photoUrl);
      if (!mounted) {
        return;
      }
      final StudentProfile profile = StudentProfile(
        displayName: userName,
        rollNumber: _extractRollNumber(email),
        email: email,
        photoUrl: account.photoUrl,
        localPhotoPath: localPath,
      );
      if (!mounted) {
        return;
      }
      await persistLoginSession(profile);
      if (!mounted) {
        return;
      }
      await Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => MainShell(
            profile: profile,
            onLogout: performSignOutAndNavigateToLogin,
          ),
        ),
      );
    } on PlatformException catch (e) {
      if (!mounted) {
        return;
      }
      _toast(
        'Google sign-in failed (${e.code}): ${e.message ?? 'No details'}',
        error: true,
      );
    } catch (e) {
      if (!mounted) {
        return;
      }
      _toast('Google sign-in failed: $e', error: true);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  void _toast(String message, {bool error = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: error ? Colors.red : Colors.green,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surface,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                const Icon(Icons.calendar_month, size: 72, color: kFastBlue),
                const SizedBox(height: 16),
                Text(
                  'Student Timetable',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: kFastBlue,
                      ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Sign in with your university Google account',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: kFastBlue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _busy ? null : _continueWithGoogle,
                    icon: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.login),
                    label: Text(_busy ? 'Signing in...' : 'Continue with Google'),
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

// --- Main shell (3 tabs) ----------------------------------------------------------
class MainShell extends StatefulWidget {
  const MainShell({super.key, required this.profile, required this.onLogout});

  final StudentProfile profile;
  final Future<void> Function() onLogout;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  TimetablePayload? _payload;
  String? _error;
  bool _loading = false;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String cacheKey = timetableCacheKey(widget.profile.rollNumber);
    final String? cachedJson = prefs.getString(cacheKey);

    TimetablePayload? cachedPayload;
    if (cachedJson != null && cachedJson.isNotEmpty) {
      cachedPayload = parseTimetablePayloadFromJsonString(cachedJson);
    }

    TimetablePayload? latest = cachedPayload;

    if (cachedPayload != null) {
      setState(() {
        _payload = cachedPayload;
        _error = null;
        _loading = true;
      });
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final Uri uri = Uri.parse(
      '$kApiBaseUrl/api/v1/timetable/${Uri.encodeComponent(widget.profile.rollNumber)}',
    );

    try {
      final http.Response res = await http
          .get(uri)
          .timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        try {
          await prefs.setString(cacheKey, res.body);
          final TimetablePayload data = TimetablePayload.fromJson(
            jsonDecode(res.body) as Map<String, dynamic>,
          );
          latest = data;
          if (!mounted) {
            return;
          }
          setState(() {
            _payload = data;
            _loading = false;
            _error = null;
          });
        } catch (_) {
          if (!mounted) {
            return;
          }
          setState(() {
            _loading = false;
          });
        }
      }
    } catch (_) {
      // Offline / timeout / HTTP error: keep showing cached timetable; no error banner.
    }

    if (!mounted) {
      return;
    }
    setState(() {
      _loading = false;
    });

    if (latest != null) {
      await NotificationService.instance.scheduleClassReminders(latest.schedule);
    }
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(
          profile: widget.profile,
          apiBase: kApiBaseUrl,
          onLogout: widget.onLogout,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: <Widget>[
          HomeTab(
            profile: widget.profile,
            payload: _payload,
            loading: _loading,
            error: _error,
            onRefresh: _load,
            onOpenSettings: _openSettings,
            onOpenFreeRooms: _openFreeRooms,
            onSignOut: widget.onLogout,
          ),
          TimetableTab(
            profile: widget.profile,
            payload: _payload,
            loading: _loading,
            error: _error,
            onRefresh: _load,
          ),
          ExamsScreen(profile: widget.profile),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (int i) => setState(() => _index = i),
        type: BottomNavigationBarType.fixed,
        selectedItemColor: kFastBlue,
        unselectedItemColor: Colors.black54,
        backgroundColor: Theme.of(context).colorScheme.surface,
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.calendar_view_week_outlined),
            activeIcon: Icon(Icons.calendar_view_week),
            label: 'Timetable',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.assignment_outlined),
            activeIcon: Icon(Icons.assignment),
            label: 'Exams',
          ),
        ],
      ),
    );
  }

  void _openFreeRooms(BuildContext context, String? activeSlotLabel) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FreeRoomsPage(
          activeSlotLabel: activeSlotLabel,
          schedule: _payload?.schedule ?? <ScheduleEntry>[],
        ),
      ),
    );
  }
}

// --- Home -------------------------------------------------------------------------
class HomeTab extends StatelessWidget {
  const HomeTab({
    super.key,
    required this.profile,
    required this.payload,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onOpenSettings,
    required this.onOpenFreeRooms,
    required this.onSignOut,
  });

  final StudentProfile profile;
  final TimetablePayload? payload;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final Future<void> Function() onOpenSettings;
  final void Function(BuildContext context, String? slot) onOpenFreeRooms;
  final Future<void> Function() onSignOut;

  ScheduleEntry? _currentClass(DateTime now) {
    if (payload == null) {
      return null;
    }
    final String today = weekdayName(now);
    for (final ScheduleEntry e in payload!.schedule) {
      if (e.day == today && isDuringSlot(now, e.timeSlot)) {
        return e;
      }
    }
    return null;
  }

  String? _activeSlotLabel(DateTime now) {
    final ScheduleEntry? current = _currentClass(now);
    if (current != null) {
      return current.timeSlot;
    }
    if (payload == null) {
      return null;
    }
    final String today = weekdayName(now);
    for (final ScheduleEntry e in payload!.schedule) {
      if (e.day != today) {
        continue;
      }
      final ({int start, int end})? r = parseTimeSlotRange(e.timeSlot);
      if (r == null) {
        continue;
      }
      final int n = _minutesNow(now);
      if (n < r.start) {
        return e.timeSlot;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final ScheduleEntry? current = _currentClass(now);
    final String? slotHint = _activeSlotLabel(now);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Settings',
            onPressed: () => onOpenSettings(),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: kFastBlue,
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            _ProfileCard(profile: profile, onSignOut: onSignOut),
            const SizedBox(height: 14),
            if (loading) const LinearProgressIndicator(minHeight: 3),
            if (error != null)
              Card(
                color: Colors.red.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    'Could not load timetable: $error',
                    style: TextStyle(color: Colors.red.shade900),
                  ),
                ),
              ),
            const SizedBox(height: 8),
            _NowCard(current: current, now: now),
            const SizedBox(height: 14),
            _QuickActionCard(
              activeSlot: current?.timeSlot ?? slotHint,
              onTap: () => onOpenFreeRooms(context, current?.timeSlot ?? slotHint),
            ),
          ],
        ),
      ),
    );
  }
}

ImageProvider? _resolveProfileImage(StudentProfile profile) {
  if (!kIsWeb && profile.localPhotoPath != null) {
    final File file = File(profile.localPhotoPath!);
    if (file.existsSync()) {
      return FileImage(file);
    }
  }
  if (profile.photoUrl != null && profile.photoUrl!.isNotEmpty) {
    return NetworkImage(profile.photoUrl!);
  }
  return null;
}

class _ProfileCard extends StatelessWidget {
  const _ProfileCard({required this.profile, required this.onSignOut});

  final StudentProfile profile;
  final Future<void> Function() onSignOut;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                CircleAvatar(
                  radius: 40,
                  backgroundColor: kFastBlue.withValues(alpha: 0.12),
                  backgroundImage: _resolveProfileImage(profile),
                  child: _resolveProfileImage(profile) != null
                      ? null
                      : const Icon(Icons.person, size: 40, color: kFastBlue),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        profile.displayName,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              color: kFastBlue,
                            ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Roll: ${profile.rollNumber}',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        profile.email,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.black54,
                            ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
              style: FilledButton.styleFrom(
                foregroundColor: Colors.red.shade900,
                backgroundColor: Colors.red.shade50,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: () async {
                await onSignOut();
              },
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(Icons.logout),
                  SizedBox(width: 8),
                  Text('Sign out', style: TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NowCard extends StatelessWidget {
  const _NowCard({required this.current, required this.now});

  final ScheduleEntry? current;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: kAccentGold, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: kAccentGold.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'RIGHT NOW',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.6,
                      fontSize: 11,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (current == null)
              Text(
                weekdayName(now) == 'Saturday' || weekdayName(now) == 'Sunday'
                    ? 'Weekend — no weekday class window.'
                    : 'No class scheduled for this time slot.',
                style: Theme.of(context).textTheme.bodyLarge,
              )
            else ...<Widget>[
              Text(
                current!.subject,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 6),
              Text('${current!.timeSlot} · ${current!.location}'),
              const SizedBox(height: 4),
              Text('${current!.courseCode} · ${current!.teacher}'),
            ],
          ],
        ),
      ),
    );
  }
}

class _QuickActionCard extends StatelessWidget {
  const _QuickActionCard({required this.activeSlot, required this.onTap});

  final String? activeSlot;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: kFastBlue.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: const Icon(Icons.meeting_room_outlined, color: kFastBlue),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Find free rooms',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      activeSlot == null
                          ? 'We will filter by your next or current slot in Phase 2.'
                          : 'Explore rooms that may be free during $activeSlot.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

// --- Timetable (Mon–Fri tabs) ----------------------------------------------------
class TimetableTab extends StatefulWidget {
  const TimetableTab({
    super.key,
    required this.profile,
    required this.payload,
    required this.loading,
    required this.error,
    required this.onRefresh,
  });

  final StudentProfile profile;
  final TimetablePayload? payload;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;

  @override
  State<TimetableTab> createState() => _TimetableTabState();
}

class _TimetableTabState extends State<TimetableTab> {
  static const int _kPageViewAnchor = 1000;

  late final PageController _pageController;
  late int _activePageIndex;

  static int _initialPageForToday() {
    final int today = weekdayTabIndex(DateTime.now());
    return _kPageViewAnchor - (_kPageViewAnchor % kWeekdays.length) + today;
  }

  @override
  void initState() {
    super.initState();
    final int initial = _initialPageForToday();
    _activePageIndex = initial;
    _pageController = PageController(initialPage: initial);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToWeekdayIndex(int targetDayIndex) {
    final int cur = _pageController.hasClients
        ? _pageController.page!.round()
        : _activePageIndex;
    final int curDay = cur % kWeekdays.length;
    if (curDay == targetDayIndex) {
      return;
    }
    final int forward = (targetDayIndex - curDay + kWeekdays.length) %
        kWeekdays.length;
    final int backward = (curDay - targetDayIndex + kWeekdays.length) %
        kWeekdays.length;
    final int nextPage =
        forward <= backward ? cur + forward : cur - backward;
    _pageController.animateToPage(
      nextPage,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  List<ScheduleEntry> _forDay(String day) {
    if (widget.payload == null) {
      return <ScheduleEntry>[];
    }
    return widget.payload!.schedule.where((e) => e.day == day).toList();
  }

  void _sortChronologically(List<ScheduleEntry> items) {
    items.sort(
      (ScheduleEntry a, ScheduleEntry b) => startMinutesFromTimeSlot(a.timeSlot)
          .compareTo(startMinutesFromTimeSlot(b.timeSlot)),
    );
  }

  List<ScheduleEntry> _sortedForDay(String day, DateTime now) {
    final List<ScheduleEntry> items = _forDay(day);
    final bool isToday = weekdayName(now) == day;
    if (!isToday) {
      _sortChronologically(items);
      return items;
    }
    bool active(ScheduleEntry e) => isDuringSlot(now, e.timeSlot);
    items.sort((ScheduleEntry a, ScheduleEntry b) {
      final bool aa = active(a);
      final bool bb = active(b);
      if (aa != bb) {
        return aa ? -1 : 1;
      }
      return startMinutesFromTimeSlot(a.timeSlot)
          .compareTo(startMinutesFromTimeSlot(b.timeSlot));
    });
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final int todayDayIndex = weekdayTabIndex(now);
    final int activeDayIndex = _activePageIndex % kWeekdays.length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Timetable'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(46),
          child: _WeekdayStrip(
            activeDayIndex: activeDayIndex,
            todayDayIndex: todayDayIndex,
            onDaySelected: _goToWeekdayIndex,
          ),
        ),
      ),
      body: Column(
        children: <Widget>[
          if (widget.loading) const LinearProgressIndicator(minHeight: 3),
          if (widget.error != null)
            Material(
              color: Colors.red.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text('Could not load: ${widget.error}'),
              ),
            ),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (int index) {
                setState(() => _activePageIndex = index);
              },
              itemBuilder: (BuildContext context, int index) {
                final int dayIndex = index % kWeekdays.length;
                final String day = kWeekdays[dayIndex];
                final List<ScheduleEntry> rows = _sortedForDay(day, now);
                return RefreshIndicator(
                  color: kFastBlue,
                  onRefresh: widget.onRefresh,
                  child: rows.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const <Widget>[
                            SizedBox(height: 120),
                            Center(child: Text('No classes on this day.')),
                          ],
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: rows.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 10),
                          itemBuilder: (BuildContext context, int i) {
                            final ScheduleEntry e = rows[i];
                            final bool pin = weekdayName(now) == day &&
                                isDuringSlot(now, e.timeSlot);
                            return _SessionCard(entry: e, pinned: pin);
                          },
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _WeekdayStrip extends StatelessWidget {
  const _WeekdayStrip({
    required this.activeDayIndex,
    required this.todayDayIndex,
    required this.onDaySelected,
  });

  final int activeDayIndex;
  final int todayDayIndex;
  final ValueChanged<int> onDaySelected;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kFastBlue,
      child: SizedBox(
        height: 46,
        child: Row(
          children: List<Widget>.generate(kWeekdays.length, (int i) {
            final bool selected = activeDayIndex == i;
            final bool isToday = todayDayIndex == i;
            return Expanded(
              child: InkWell(
                onTap: () => onDaySelected(i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          if (isToday)
                            Container(
                              width: 7,
                              height: 7,
                              margin: const EdgeInsets.only(right: 5),
                              decoration: const BoxDecoration(
                                color: kAccentGold,
                                shape: BoxShape.circle,
                              ),
                            ),
                          Text(
                            kWeekdays[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight:
                                  selected ? FontWeight.w800 : FontWeight.w500,
                              fontSize: 13,
                              color: selected ? Colors.white : Colors.white70,
                              decoration: selected
                                  ? TextDecoration.underline
                                  : TextDecoration.none,
                              decorationColor: kAccentGold,
                              decorationThickness: 2,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  const _SessionCard({required this.entry, required this.pinned});

  final ScheduleEntry entry;
  final bool pinned;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: pinned ? 3 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(
          color: pinned ? kAccentGold : Colors.transparent,
          width: 2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (pinned)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: kAccentGold.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'Happening now',
                    style: TextStyle(fontWeight: FontWeight.w800, fontSize: 11),
                  ),
                ),
              ),
            Text(
              entry.subject,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: kFastBlue,
                  ),
            ),
            const SizedBox(height: 6),
            Text(entry.timeSlot),
            const SizedBox(height: 4),
            Text('${entry.location} · ${entry.batch}'),
            const SizedBox(height: 4),
            Text('${entry.courseCode} · ${entry.teacher}'),
          ],
        ),
      ),
    );
  }
}

// --- Exams ------------------------------------------------------------------------
class ExamsScreen extends StatefulWidget {
  const ExamsScreen({super.key, required this.profile});

  final StudentProfile profile;

  @override
  State<ExamsScreen> createState() => _ExamsScreenState();
}

class _ExamsScreenState extends State<ExamsScreen> {
  bool _loading = true;
  String? _error;
  ExamsPayload _payload = const ExamsPayload(
    labExams: <ExamEntry>[],
    theoryExams: <TheoryExamEntry>[],
  );

  @override
  void initState() {
    super.initState();
    unawaited(_loadExams());
  }

  Future<void> _loadExams() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String theoryCacheKey = theoryExamsCacheKey(widget.profile.rollNumber);
    final String? cachedTheoryRaw = prefs.getString(theoryCacheKey);
    final List<TheoryExamEntry> cachedTheory = <TheoryExamEntry>[];
    if (cachedTheoryRaw != null && cachedTheoryRaw.isNotEmpty) {
      try {
        final dynamic decoded = jsonDecode(cachedTheoryRaw);
        if (decoded is List<dynamic>) {
          cachedTheory.addAll(
            decoded.map(
              (dynamic e) => TheoryExamEntry.fromJson(
                e as Map<String, dynamic>,
              ),
            ),
          );
        }
      } catch (_) {
        // Ignore bad cache and fetch from network.
      }
    }

    setState(() {
      _loading = true;
      _error = null;
      if (cachedTheory.isNotEmpty) {
        _payload = ExamsPayload(
          labExams: _payload.labExams,
          theoryExams: cachedTheory,
        );
      }
    });

    final String encodedRoll = Uri.encodeComponent(widget.profile.rollNumber);
    final Uri labUri = Uri.parse('$kApiBaseUrl/api/v1/student/lab-exams/$encodedRoll');
    final Uri theoryUri = Uri.parse(
      '$kApiBaseUrl/api/v1/student/theory-exams/$encodedRoll',
    );

    try {
      final List<http.Response> responses = await Future.wait(<Future<http.Response>>[
        http.get(labUri).timeout(const Duration(seconds: 6)),
        http.get(theoryUri).timeout(const Duration(seconds: 6)),
      ]);

      final http.Response labRes = responses[0];
      final http.Response theoryRes = responses[1];
      final List<ExamEntry> parsedLabs = <ExamEntry>[];
      List<TheoryExamEntry> parsedTheory = cachedTheory;

      if (labRes.statusCode == 200) {
        final Map<String, dynamic> json =
            jsonDecode(labRes.body) as Map<String, dynamic>;
        final List<dynamic> raw = json['lab_exams'] as List<dynamic>? ?? <dynamic>[];
        for (final dynamic e in raw) {
          final ExamEntry entry = ExamEntry.fromJson(e as Map<String, dynamic>);
          final String codeWithSection = entry.codeWithSection ??
              '${entry.courseCode},${entry.batch}';
          final String? section = sectionFromCodeWithSection(codeWithSection);
          if (!isLabCodeWithSection(codeWithSection) || section == null) {
            continue;
          }
          parsedLabs.add(entry);
        }
      }

      if (theoryRes.statusCode == 200) {
        final Map<String, dynamic> json =
            jsonDecode(theoryRes.body) as Map<String, dynamic>;
        final List<dynamic> raw =
            json['theory_exams'] as List<dynamic>? ?? <dynamic>[];
        parsedTheory = raw
            .map(
              (dynamic e) => TheoryExamEntry.fromJson(
                e as Map<String, dynamic>,
              ),
            )
            .toList();
        await prefs.setString(
          theoryCacheKey,
          jsonEncode(
            parsedTheory
                .map(
                  (TheoryExamEntry e) => <String, String>{
                    'course_code': e.courseCode,
                    'course_name': e.courseName,
                    'exam_date': e.examDate,
                    'start_time': e.startTime,
                    'end_time': e.endTime,
                  },
                )
                .toList(),
          ),
        );
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _payload = ExamsPayload(labExams: parsedLabs, theoryExams: parsedTheory);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loading = false;
        _error = 'Could not fetch exams right now. Pull down to retry.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Exams')),
      body: RefreshIndicator(
        color: kFastBlue,
        onRefresh: _loadExams,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            if (_loading) const LinearProgressIndicator(minHeight: 3),
            if (_error != null)
              Card(
                color: Colors.red.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(
                    _error!,
                    style: TextStyle(color: Colors.red.shade900),
                  ),
                ),
              ),
            _ExamSectionHeader(
              title: 'Lab Exams',
              icon: Icons.science_outlined,
              subtitle: 'Lab mapping uses code + section (e.g., AL2002,BCS-4B).',
            ),
            const SizedBox(height: 8),
            if (_payload.labExams.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.info_outline, color: kFastBlue),
                  title: Text('No lab exams found'),
                  subtitle: Text('Upload lab datesheet or verify registered lab sections.'),
                ),
              )
            else
              ..._payload.labExams.map(
                (ExamEntry e) => _LabExamCard(entry: e),
              ),
            const SizedBox(height: 16),
            const _ExamSectionHeader(
              title: 'Theory Exams',
              icon: Icons.menu_book_outlined,
              subtitle: 'Theory schedule for your registered course codes.',
            ),
            const SizedBox(height: 8),
            if (_payload.theoryExams.isEmpty)
              const Card(
                child: ListTile(
                  leading: Icon(Icons.info_outline, color: kFastBlue),
                  title: Text('No theory exams found'),
                ),
              )
            else
              ..._payload.theoryExams.map(
                (TheoryExamEntry e) => _TheoryExamCard(entry: e),
              ),
          ],
        ),
      ),
    );
  }
}

class _ExamSectionHeader extends StatelessWidget {
  const _ExamSectionHeader({
    required this.title,
    required this.icon,
    required this.subtitle,
  });

  final String title;
  final IconData icon;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, color: kFastBlue),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: kFastBlue,
                    ),
              ),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

class _LabExamCard extends StatelessWidget {
  const _LabExamCard({required this.entry});

  final ExamEntry entry;

  @override
  Widget build(BuildContext context) {
    final String codeWithSection = entry.codeWithSection ??
        '${entry.courseCode},${entry.batch}';
    final String? section = sectionFromCodeWithSection(codeWithSection);
    final String extended = (entry.extendedTime != null && entry.extendedTime!.isNotEmpty)
        ? entry.extendedTime!
        : extendedLabTimeFromRaw(entry.time);

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: const BorderSide(color: kAccentGold, width: 1.2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              entry.subject,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: kFastBlue,
                  ),
            ),
            const SizedBox(height: 6),
            Text('${entry.date} · ${entry.venue}'),
            const SizedBox(height: 4),
            Text('Duration (Lab 2-slot): $extended'),
            const SizedBox(height: 4),
            Text('${entry.courseCode} · ${section ?? entry.batch} · ${entry.teacher}'),
          ],
        ),
      ),
    );
  }
}

class _TheoryExamCard extends StatelessWidget {
  const _TheoryExamCard({required this.entry});

  final TheoryExamEntry entry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.description_outlined, color: kFastBlue),
        title: Text(entry.courseName),
        subtitle: Text(
          '${entry.examDate}\n${entry.startTime} - ${entry.endTime}\n${entry.courseCode}',
        ),
      ),
    );
  }
}

// --- Settings ---------------------------------------------------------------------
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.profile,
    required this.apiBase,
    required this.onLogout,
  });

  final StudentProfile profile;
  final String apiBase;
  final Future<void> Function() onLogout;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeService,
      builder: (BuildContext context, Widget? _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            children: <Widget>[
              Card(
                child: SwitchListTile(
                  secondary: Icon(
                    themeService.isDark ? Icons.dark_mode : Icons.light_mode,
                    color: kFastBlue,
                  ),
                  title: const Text('Dark mode'),
                  subtitle: const Text(
                    'Cool Charcoal theme · Off uses Bright White',
                  ),
                  value: themeService.isDark,
                  onChanged: (bool v) {
                    unawaited(themeService.setDark(v));
                  },
                ),
              ),
              const SizedBox(height: 8),
          Card(
            elevation: 2,
            color: Colors.red.shade50,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Session',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.red.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: () async {
                      await onLogout();
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text(
                      'Sign out',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Clears saved login and returns to the sign-in screen.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.black54,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('API base'),
            subtitle: Text(apiBase),
          ),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('Roll number'),
            subtitle: Text(profile.rollNumber),
          ),
            ],
          ),
        );
      },
    );
  }
}

class FreeRoomsPage extends StatelessWidget {
  const FreeRoomsPage({
    super.key,
    required this.activeSlotLabel,
    required this.schedule,
  });

  final String? activeSlotLabel;
  final List<ScheduleEntry> schedule;

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final String today = weekdayName(now);

    String? slot = activeSlotLabel;
    if (slot == null) {
      final List<String> slots = schedule
          .where((ScheduleEntry e) => e.day == today)
          .map((ScheduleEntry e) => e.timeSlot)
          .toSet()
          .toList();
      slots.sort(
        (String a, String b) => startMinutesFromTimeSlot(a)
            .compareTo(startMinutesFromTimeSlot(b)),
      );
      if (slots.isNotEmpty) {
        slot = slots.first;
      }
    }

    final List<String> free = slot == null
        ? <String>[]
        : RoomService.availableRooms(today, slot, schedule);

    return Scaffold(
      appBar: AppBar(title: const Text('Free rooms')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(
            slot == null
                ? 'Open this screen during a weekday with timetable data to pick a slot.'
                : '$today · $slot',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: kFastBlue,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            'Rooms on campus minus locations occupied in your timetable dataset for this slot.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          if (slot == null)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No slot selected.'),
              ),
            )
          else if (free.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No rooms appear free against the static campus list.'),
              ),
            )
          else
            ...free.map(
              (String room) => Card(
                child: ListTile(
                  leading: const Icon(Icons.meeting_room_outlined),
                  title: Text(room),
                  subtitle: const Text('Likely available'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
