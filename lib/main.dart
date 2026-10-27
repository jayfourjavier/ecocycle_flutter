import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';

import 'about_page.dart';
import 'firebase_options.dart';
import 'login_page.dart';
import 'pin_lock.dart';
import 'settings_page.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Maps the numeric `activity` value in Realtime Database to a display label.
/// Edit this map to match the codes your ESP32 sends.
const Map<int, String> activityMap = {
  0: 'Idle',
  1: 'Grinding Food Waste',
  2: 'Adding Loam Soil',
  3: 'Mixing',
  4: 'Getting Sensor Data',
  5: 'Dispensing',
  6: 'Waiting to Remove Container',
};

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const EcoCycleApp());
}

class EcoCycleApp extends StatelessWidget {
  const EcoCycleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      title: 'ECOCYCLE Dashboard',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF287D46)),
        scaffoldBackgroundColor: const Color(0xFFF4F7F5),
      ),
      home: const AuthGate(),
    );
  }
}

/// Login once (Firebase keeps the session), then unlock with a PIN each time
/// the app is opened or returns from the background.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key});

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final AppLifecycleListener _lifecycle;

  void _onLockChanged() {
    // Drop any pages (settings, etc.) pushed over the dashboard when locking.
    if (AppLock.instance.locked) {
      navigatorKey.currentState?.popUntil((route) => route.isFirst);
    }
  }

  @override
  void initState() {
    super.initState();
    AppLock.instance.addListener(_onLockChanged);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.paused) AppLock.instance.lock();
      },
    );
  }

  @override
  void dispose() {
    AppLock.instance.removeListener(_onLockChanged);
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = snapshot.data;
        if (user == null) return const LoginPage();
        return _PinGate(key: ValueKey(user.uid), user: user);
      },
    );
  }
}

class _PinGate extends StatefulWidget {
  const _PinGate({super.key, required this.user});

  final User user;

  @override
  State<_PinGate> createState() => _PinGateState();
}

class _PinGateState extends State<_PinGate> {
  late Future<PinRecord?> _record = PinService.load(widget.user.uid);
  bool _resetting = false;

  void _reload() {
    setState(() {
      _record = PinService.load(widget.user.uid);
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PinRecord?>(
      future: _record,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Could not load your PIN. Check your connection and the '
                      'database rules, then try again.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _reload,
                      child: const Text('Retry'),
                    ),
                    TextButton(
                      onPressed: signOutUser,
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              ),
            ),
          );
        }
        final record = snapshot.data;
        if (record == null || _resetting) {
          return SetPinPage(
            uid: widget.user.uid,
            onCancel: _resetting
                ? () => setState(() => _resetting = false)
                : null,
            onDone: () {
              AppLock.instance.unlock();
              _resetting = false;
              _reload();
            },
          );
        }
        return ListenableBuilder(
          listenable: AppLock.instance,
          builder: (context, _) => AppLock.instance.locked
              ? UnlockPage(
                  user: widget.user,
                  record: record,
                  onUnlocked: AppLock.instance.unlock,
                  onForgot: () => setState(() => _resetting = true),
                )
              : const DashboardPage(),
        );
      },
    );
  }
}

/// Gauge arc that starts at 7 o'clock and ends at 5 o'clock (300° sweep,
/// clockwise over the top).
class _GaugePainter extends CustomPainter {
  final double value; // 0.0 - 1.0
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  const _GaugePainter({
    required this.value,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  // Canvas angles: 0 = 3 o'clock, positive = clockwise.
  static const double _startAngle = 2 * math.pi / 3; // 7 o'clock
  static const double _sweepAngle = 5 * math.pi / 3; // 300 degrees

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(
      strokeWidth / 2,
      strokeWidth / 2,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      rect,
      _startAngle,
      _sweepAngle,
      false,
      paint..color = trackColor,
    );
    if (value > 0) {
      canvas.drawArc(
        rect,
        _startAngle,
        _sweepAngle * value,
        false,
        paint..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.value != value ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth;
}

class ProductionRecord {
  final String batchNumber;
  final DateTime timestamp;
  final double temperature;
  final double moisture;

  const ProductionRecord({
    required this.batchNumber,
    required this.timestamp,
    required this.temperature,
    required this.moisture,
  });

  String get date =>
      '${timestamp.year}-${timestamp.month.toString().padLeft(2, '0')}-'
      '${timestamp.day.toString().padLeft(2, '0')}';

  String get time {
    final hour12 = timestamp.hour % 12 == 0 ? 12 : timestamp.hour % 12;
    final period = timestamp.hour >= 12 ? 'PM' : 'AM';
    return '${hour12.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')} $period';
  }

  /// Parses "EC-001,1790905290,29.4,58.0" (batch,unixSeconds,temperature,moisture).
  static ProductionRecord? tryParse(Object? raw) {
    if (raw is! String) return null;
    final parts = raw.split(',');
    if (parts.length < 4) return null;
    final seconds = int.tryParse(parts[1].trim());
    final temperature = double.tryParse(parts[2].trim());
    final moisture = double.tryParse(parts[3].trim());
    if (seconds == null || temperature == null || moisture == null) {
      return null;
    }
    return ProductionRecord(
      batchNumber: parts[0].trim(),
      timestamp: DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
      temperature: temperature,
      moisture: moisture,
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  bool isOnline = true;
  int? activityCode;

  double foodWastePercentage = 0;
  double loamSoilPercentage = 0;

  int currentPage = 0;
  String? selectedRecordKey;
  int recordsPerPage = 5;

  List<ProductionRecord> records = [];

  StreamSubscription<DatabaseEvent>? _activitySub;
  StreamSubscription<DatabaseEvent>? _recordsSub;
  StreamSubscription<DatabaseEvent>? _foodLevelSub;
  StreamSubscription<DatabaseEvent>? _soilLevelSub;

  static double? _toDouble(Object? value) {
    if (value is num) return value.toDouble();
    // Tolerate strings such as "45", "45.5" or "45%".
    final match = RegExp(r'-?\d+(\.\d+)?').firstMatch('$value');
    return match == null ? null : double.tryParse(match.group(0)!);
  }

  String? dbError;

  String get currentActivity {
    final code = activityCode;
    if (code == null) return 'Unknown';
    return activityMap[code] ?? 'Unknown ($code)';
  }

  StreamSubscription<DatabaseEvent> _listen(
    String path,
    void Function(Object? value) onValue,
  ) {
    return FirebaseDatabase.instance
        .ref(path)
        .onValue
        .listen(
          (event) {
            final value = event.snapshot.value;
            debugPrint('RTDB /$path = $value');
            if (!mounted) return;
            setState(() {
              dbError = null;
              onValue(value);
            });
          },
          onError: (Object e) {
            debugPrint('RTDB /$path error: $e');
            if (!mounted) return;
            setState(() => dbError = '/$path: $e');
          },
        );
  }

  @override
  void initState() {
    super.initState();

    _activitySub = _listen('activity', (value) {
      activityCode = value is num ? value.toInt() : _toDouble(value)?.toInt();
    });

    _foodLevelSub = _listen('food_level', (value) {
      final level = _toDouble(value);
      if (level != null) foodWastePercentage = level;
    });

    _soilLevelSub = _listen('soil_level', (value) {
      final level = _toDouble(value);
      if (level != null) loamSoilPercentage = level;
    });

    _recordsSub = _listen('records', (value) {
      final parsed = <ProductionRecord>[];
      if (value is Map) {
        for (final raw in value.values) {
          final record = ProductionRecord.tryParse(raw);
          if (record != null) parsed.add(record);
        }
      }
      // Newest first.
      parsed.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      records = parsed;
      if (currentPage >= totalPages) {
        currentPage = totalPages == 0 ? 0 : totalPages - 1;
      }
    });
  }

  @override
  void dispose() {
    _activitySub?.cancel();
    _recordsSub?.cancel();
    _foodLevelSub?.cancel();
    _soilLevelSub?.cancel();
    super.dispose();
  }

  int get totalPages => (records.length / recordsPerPage).ceil();

  List<ProductionRecord> get visibleRecords {
    final start = currentPage * recordsPerPage;
    final end = (start + recordsPerPage).clamp(0, records.length);

    if (start >= records.length) return [];

    return records.sublist(start, end);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      drawer: _buildDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            _buildTitleBar(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1200),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (dbError != null) ...[
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFEAEA),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: const Color(0xFFFF5B5B),
                              ),
                            ),
                            child: Text(
                              'Database error: $dbError',
                              style: const TextStyle(color: Color(0xFFB00020)),
                            ),
                          ),
                          const SizedBox(height: 10),
                        ],
                        _buildActivitySection(),
                        const SizedBox(height: 10),
                        _buildHopperSection(),
                        const SizedBox(height: 10),
                        _buildProductionSection(),
                        const SizedBox(height: 8),
                        _buildFooter(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // HAMBURGER MENU
  Widget _buildDrawer() {
    final email = FirebaseAuth.instance.currentUser?.email;
    return Drawer(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            color: const Color(0xFF205D36),
            padding: EdgeInsets.fromLTRB(
              20,
              MediaQuery.of(context).padding.top + 24,
              20,
              20,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.recycling, color: Colors.white, size: 36),
                const SizedBox(height: 10),
                const Text(
                  'ECOCYCLE',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                if (email != null)
                  Text(email, style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.settings),
            title: const Text('Settings'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('About'),
            onTap: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const AboutPage()),
              );
            },
          ),
          const Spacer(),
          const Divider(height: 1),
          SafeArea(
            top: false,
            child: ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Log out'),
              onTap: () {
                Navigator.of(context).pop();
                signOutUser();
              },
            ),
          ),
        ],
      ),
    );
  }

  // TITLE BAR
  Widget _buildTitleBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(2, 10, 14, 10),
      color: const Color(0xFF205D36),
      child: Row(
        children: [
          Expanded(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Menu',
                  onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                  iconSize: 36,
                  icon: const Icon(Icons.menu, color: Colors.white),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.recycling, color: Colors.white, size: 32),
                const SizedBox(width: 12),
                const Flexible(
                  child: Text(
                    'ECOCYCLE',
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: isOnline
                      ? const Color(0xFF65E58A)
                      : const Color(0xFFFF5B5B),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 9),
              Text(
                isOnline ? 'Online' : 'Offline',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // CURRENT ACTIVITY
  Widget _buildActivitySection() {
    return _sectionCard(
      title: 'Current Activity',
      icon: Icons.settings_suggest,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Activity Name',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.precision_manufacturing),
            ),
            child: Text(currentActivity),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.info_outline, color: Color(0xFF287D46)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'System is currently $currentActivity.',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // HOPPER STATUS
  Widget _buildHopperSection() {
    return _sectionCard(
      title: 'Hopper Status',
      icon: Icons.inventory_2_outlined,
      child: Row(
        children: [
          Expanded(
            child: _buildHopperCard(
              title: 'Food Waste',
              percentage: foodWastePercentage,
              icon: Icons.compost,
              color: const Color(0xFF398451),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _buildHopperCard(
              title: 'Loam Soil',
              percentage: loamSoilPercentage,
              icon: Icons.grass,
              color: const Color(0xFFB17B3B),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHopperCard({
    required String title,
    required double percentage,
    required IconData icon,
    required Color color,
  }) {
    return AspectRatio(
      aspectRatio: 1,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF4F7F5),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFFE0E7E2)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Center(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CustomPaint(
                        painter: _GaugePainter(
                          value: (percentage / 100).clamp(0.0, 1.0),
                          color: color,
                          trackColor: const Color(0xFFDDE6DF),
                          strokeWidth: 10,
                        ),
                      ),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${percentage.toStringAsFixed(0)}%',
                              style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                color: color,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // PRODUCTION RECORDS
  Widget _buildProductionSection() {
    return _sectionCard(
      title: 'Production Records',
      icon: Icons.receipt_long,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Batch, temperature and moisture fill the visible width;
          // date and time sit to the right and require horizontal scrolling.
          LayoutBuilder(
            builder: (context, constraints) {
              final mainWidth = (constraints.maxWidth / 3).clamp(100.0, 400.0);
              const extraWidth = 140.0;

              Widget cell(double width, Widget child) => SizedBox(
                width: width,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: child,
                ),
              );

              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor: WidgetStateProperty.all(
                    const Color(0xFFEAF2EC),
                  ),
                  columnSpacing: 0,
                  horizontalMargin: 0,
                  showCheckboxColumn: false,
                  columns: [
                    DataColumn(
                      label: cell(mainWidth, const Text('Batch Number')),
                    ),
                    DataColumn(
                      label: cell(mainWidth, const Text('Temperature')),
                    ),
                    DataColumn(label: cell(mainWidth, const Text('Moisture'))),
                    DataColumn(label: cell(extraWidth, const Text('Date'))),
                    DataColumn(label: cell(extraWidth, const Text('Time'))),
                  ],
                  rows: visibleRecords.map((record) {
                    final key =
                        '${record.batchNumber}|${record.date}|${record.time}';
                    return DataRow(
                      selected: key == selectedRecordKey,
                      color: WidgetStateProperty.resolveWith((states) {
                        return states.contains(WidgetState.selected)
                            ? const Color(0xFFCDE8D5)
                            : null;
                      }),
                      onSelectChanged: (_) => setState(() {
                        selectedRecordKey = key == selectedRecordKey
                            ? null
                            : key;
                      }),
                      cells: [
                        DataCell(
                          cell(
                            mainWidth,
                            Text(
                              record.batchNumber,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                        DataCell(
                          cell(
                            mainWidth,
                            Text('${record.temperature.toStringAsFixed(1)} °C'),
                          ),
                        ),
                        DataCell(
                          cell(
                            mainWidth,
                            Text('${record.moisture.toStringAsFixed(1)}%'),
                          ),
                        ),
                        DataCell(cell(extraWidth, Text(record.date))),
                        DataCell(cell(extraWidth, Text(record.time))),
                      ],
                    );
                  }).toList(),
                ),
              );
            },
          ),
          const Divider(height: 24),
          _buildPagination(),
        ],
      ),
    );
  }

  Widget _buildPagination() {
    final firstRecord = records.isEmpty ? 0 : currentPage * recordsPerPage + 1;
    final lastRecord = ((currentPage + 1) * recordsPerPage).clamp(
      0,
      records.length,
    );

    return Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 12,
      children: [
        Text(
          records.isEmpty
              ? 'No records'
              : 'Showing $firstRecord–$lastRecord of ${records.length}',
          style: const TextStyle(color: Colors.black54),
        ),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          children: [
            const Text('Records:'),
            SizedBox(
              width: 100,
              child: DropdownButtonFormField<int>(
                initialValue: recordsPerPage,
                isDense: true,
                isExpanded: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: const [
                  DropdownMenuItem(value: 5, child: Text('5')),
                  DropdownMenuItem(value: 10, child: Text('10')),
                  DropdownMenuItem(value: 20, child: Text('20')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      recordsPerPage = value;
                      currentPage = 0;
                    });
                  }
                },
              ),
            ),
            IconButton(
              tooltip: 'Previous page',
              onPressed: currentPage > 0
                  ? () => setState(() => currentPage--)
                  : null,
              icon: const Icon(Icons.chevron_left),
            ),
            Text('${currentPage + 1} / ${totalPages == 0 ? 1 : totalPages}'),
            IconButton(
              tooltip: 'Next page',
              onPressed: currentPage + 1 < totalPages
                  ? () => setState(() => currentPage++)
                  : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ],
    );
  }

  // REUSABLE SECTION CARD
  Widget _sectionCard({
    required String title,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE0E7E2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFF287D46)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _buildFooter() {
    return const Center(
      child: Text(
        'ECOCYCLE • Food Waste Management System',
        style: TextStyle(fontSize: 12, color: Colors.black45),
      ),
    );
  }
}
