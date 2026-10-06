import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:health_workout_sync/health_workout_sync.dart';

import 'local_workout_importer.dart';

// ─── 1. The background importer ──────────────────────────────────────────────
//
// When the app is closed, iOS (HealthKit) or Android (WorkManager) wakes it in
// the background and the package calls this function to get an importer.
// Rules: top-level (not inside a class), and annotated exactly like this.
// In a real app, initialise your backend here (e.g. Firebase.initializeApp(),
// Supabase.initialize(...)) and return null if nobody is signed in.
@pragma('vm:entry-point')
Future<WorkoutImporter?> backgroundImporter() async => LocalWorkoutImporter();

// ─── 2. Start the package once, when the app launches ────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HealthWorkoutSync.instance.initialize(
    backgroundImporter: backgroundImporter,
  );
  // The importer used while the app is open. Pass null after sign-out.
  HealthWorkoutSync.instance.attachImporter(LocalWorkoutImporter());
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'health_workout_sync',
    theme: ThemeData(colorSchemeSeed: Colors.teal),
    home: const HomePage(),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final HealthWorkoutSync _sync = HealthWorkoutSync.instance;
  final LocalWorkoutImporter _store = LocalWorkoutImporter();
  late final AppLifecycleListener _lifecycle;

  HealthSyncStatus? _status;
  HealthAvailability? _availability;
  List<StoredWorkout> _workouts = const <StoredWorkout>[];
  List<FitnessAppStatus> _apps = const <FitnessAppStatus>[];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // ─── 3. Sync whenever the app comes to the foreground ────────────────────
    _lifecycle = AppLifecycleListener(onResume: _syncNow);
    _syncNow();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final HealthSyncStatus status = await _sync.status();
    final HealthAvailability availability = await _sync.availability();
    final List<StoredWorkout> workouts = await _store.all();
    final List<FitnessAppStatus> apps = status.connected
        ? await _sync.fitnessApps()
        : const <FitnessAppStatus>[];
    if (!mounted) return;
    setState(() {
      _status = status;
      _availability = availability;
      _workouts = workouts;
      _apps = apps;
    });
  }

  Future<void> _run(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    String? message;
    try {
      message = await action();
    } catch (e) {
      message = 'Something went wrong: $e';
    }
    await _refresh();
    if (mounted) setState(() => _busy = false);
    if (mounted && message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  // ─── 4. Connect: shows the Apple Health / Health Connect permission sheet ─
  Future<void> _connect() => _run(() async {
    final ConnectResult result = await _sync.connect();
    switch (result) {
      case ConnectResult.connected:
        await _sync.requestNotificationPermission();
        final SyncReport report = await _sync.sync();
        return 'Connected. Imported ${report.imported} workout(s) from today.';
      case ConnectResult.denied:
        return 'Permission denied. You can allow it in health settings.';
      case ConnectResult.unavailable:
        return Platform.isAndroid
            ? 'Health Connect is not installed on this phone.'
            : 'Apple Health is not available on this device.';
    }
  });

  Future<void> _syncNow() => _run(() async {
    final SyncReport report = await _sync.sync();
    if (!report.ran) return null; // not connected yet, or already syncing
    return report.imported == 0
        ? null
        : 'Imported ${report.imported} new workout(s).';
  });

  Future<void> _disconnect() => _run(() async {
    await _sync.disconnect();
    return 'Disconnected. Imported workouts are kept.';
  });

  // Access was switched off in system settings → ask again, keeping progress.
  Future<void> _restoreAccess() => _run(() async {
    final bool granted = await _sync.requestAccess();
    if (!granted) {
      await _sync.openHealthSettings();
      return 'Turn workout access back on, then return here.';
    }
    final SyncReport report = await _sync.sync();
    return 'Access restored. Imported ${report.imported} workout(s).';
  });

  Future<void> _setInterval(Duration? value) async {
    if (value == null) return;
    await _sync.setBackgroundInterval(value);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final HealthSyncStatus? status = _status;
    final bool connected = status?.connected ?? false;
    final String store = Platform.isAndroid ? 'Health Connect' : 'Apple Health';

    return Scaffold(
      appBar: AppBar(title: const Text('Workout sync example')),
      body: RefreshIndicator(
        onRefresh: _syncNow,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            if (_busy) const LinearProgressIndicator(),
            // Android 9–13: Health Connect is a separate Play Store app.
            if (_availability == HealthAvailability.needsInstall)
              FilledButton(
                onPressed: _sync.installHealthConnect,
                child: const Text('Install Health Connect'),
              ),
            if (_availability == HealthAvailability.unsupported)
              Text('$store is not available on this device.'),
            if (status != null && status.available && !connected)
              FilledButton(
                onPressed: _busy ? null : _connect,
                child: Text('Connect $store'),
              ),
            if (connected) ...<Widget>[
              if (!status!.readAuthorized)
                Card(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: ListTile(
                    title: const Text('Workout access is off'),
                    subtitle: Text(
                      'Workouts can\'t sync until you allow '
                      'access in $store again.',
                    ),
                    trailing: TextButton(
                      onPressed: _restoreAccess,
                      child: const Text('Fix'),
                    ),
                  ),
                ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Connected to $store'),
                subtitle: Text(
                  'Last sync: ${status.lastSyncAt?.toLocal() ?? 'never'}',
                ),
                trailing: TextButton(
                  onPressed: _busy ? null : _syncNow,
                  child: const Text('Sync now'),
                ),
              ),
              // ─── 5. Sync frequency (Android only; iOS syncs on HealthKit's
              //        own signal the moment a workout is saved) ────────────
              if (Platform.isAndroid)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Background sync'),
                  trailing: DropdownButton<Duration>(
                    value: status.backgroundInterval,
                    onChanged: _setInterval,
                    items:
                        const <Duration>[
                              Duration(minutes: 15),
                              Duration(minutes: 30),
                              Duration(hours: 1),
                              Duration(hours: 3),
                              Duration(hours: 6),
                            ]
                            .map(
                              (Duration d) => DropdownMenuItem<Duration>(
                                value: d,
                                child: Text(
                                  d.inHours >= 1
                                      ? 'Every ${d.inHours} h'
                                      : 'Every ${d.inMinutes} min',
                                ),
                              ),
                            )
                            .toList(),
                  ),
                ),
              // ─── 6. Remind users to let OTHER apps share with the store ──
              const HealthSharingReminder(),
              const SizedBox(height: 16),
              Text(
                'Your fitness apps',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (_apps.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No other app has shared a workout yet.'),
                ),
              for (final FitnessAppStatus app in _apps) _AppRow(app: app),
              const SizedBox(height: 16),
              Text(
                'Imported workouts (${_workouts.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final StoredWorkout w in _workouts)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('${w.type} · ${w.minutes} min'),
                  subtitle: Text('${w.source} · ${w.start.toLocal()}'),
                ),
              const SizedBox(height: 24),
              OutlinedButton(
                onPressed: _busy ? null : _disconnect,
                child: const Text('Disconnect'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One "Your fitness apps" row: sharing ✓, or how to turn sharing on.
class _AppRow extends StatelessWidget {
  const _AppRow({required this.app});

  final FitnessAppStatus app;

  @override
  Widget build(BuildContext context) {
    final bool android = Platform.isAndroid;
    final FitnessAppGuide? guide = app.guide;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        app.sharing ? Icons.check_circle : Icons.info_outline,
        color: app.sharing ? Colors.green : Colors.orange,
      ),
      title: Text(app.name),
      subtitle: Text(
        app.sharing ? 'Sharing workouts' : 'Installed, not sharing workouts',
      ),
      trailing: guide == null ? null : const Icon(Icons.chevron_right),
      onTap: guide == null
          ? null
          : () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => _GuideSheet(
                guide: guide,
                android: android,
                installedPackage: app.installedPackage,
              ),
            ),
    );
  }
}

/// Step-by-step instructions for one app, from [FitnessAppGuide].
class _GuideSheet extends StatelessWidget {
  const _GuideSheet({
    required this.guide,
    required this.android,
    this.installedPackage,
  });

  final FitnessAppGuide guide;
  final bool android;
  final String? installedPackage;

  @override
  Widget build(BuildContext context) {
    final List<String> steps = guide.steps(android: android);
    final bool supported = guide.support(android: android) != ShareSupport.no;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Share ${guide.appName} workouts',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (!supported)
              Text(
                guide.bridge ??
                    '${guide.appName} can\'t share workouts on this phone.',
              ),
            for (int i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('${i + 1}. ${steps[i]}'),
              ),
            if (guide.limitation != null)
              Text(
                guide.limitation!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            if (installedPackage != null) ...<Widget>[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () =>
                    HealthWorkoutSync.instance.launchPackage(installedPackage!),
                child: Text('Open ${guide.appName}'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
