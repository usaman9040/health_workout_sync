import 'dart:io' show Platform;
import 'dart:ui' show CallbackHandle, PluginUtilities;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:workmanager/workmanager.dart';

import 'background.dart';
import 'fitness_apps/fitness_app_guide.dart';
import 'fitness_apps/fitness_app_status.dart';
import 'models.dart';
import 'sources/health_store_channel.dart';
import 'sync_engine.dart';
import 'sync_state_store.dart';
import 'workout_importer.dart';

/// Snapshot for settings / status UI.
@immutable
class HealthSyncStatus {
  const HealthSyncStatus({
    required this.store,
    required this.available,
    required this.connected,
    required this.backgroundInterval,
    this.connectedAt,
    this.lastSyncAt,
    this.lastBackgroundSyncAt,
    this.backgroundAuthorized = false,
    this.readAuthorized = true,
  });

  final HealthStore store;
  final bool available;
  final bool connected;
  final DateTime? connectedAt;
  final DateTime? lastSyncAt;
  final DateTime? lastBackgroundSyncAt;

  /// Android: Health Connect background-read permission granted. Without it
  /// only foreground syncs run. iOS: always true.
  final bool backgroundAuthorized;

  /// Android: the user still grants workout read access. Health Connect
  /// access can be switched off in system settings (or auto-removed) while
  /// the app still thinks it's connected — every sync then fails. iOS never
  /// reveals read denials, so it's always true there.
  final bool readAuthorized;

  /// Android WorkManager period. iOS syncs on HealthKit's own signal instead.
  final Duration backgroundInterval;
}

/// Imports workouts from Apple Health / Health Connect.
///
/// ```dart
/// // main isolate, once at startup
/// await HealthWorkoutSync.instance.initialize(
///   backgroundImporter: buildBackgroundImporter, // top-level, vm:entry-point
/// );
/// HealthWorkoutSync.instance.attachImporter(myImporter); // after sign-in
///
/// await HealthWorkoutSync.instance.connect();   // permission sheet
/// await HealthWorkoutSync.instance.sync();      // on resume
/// ```
///
/// Background: iOS wakes on HealthKit's observer (native, see the plugin's
/// AppDelegate hooks); Android runs a WorkManager job every
/// [backgroundInterval] (default 1 h, min 15 min).
class HealthWorkoutSync {
  HealthWorkoutSync._({
    this._channel = const HealthStoreChannel(),
    SyncStateStore? state,
    this._config = const SyncConfig(),
  }) : _state = state ?? SyncStateStore();

  /// Process-wide instance (one per isolate).
  static final HealthWorkoutSync instance = HealthWorkoutSync._();

  /// For tests / custom wiring.
  @visibleForTesting
  factory HealthWorkoutSync.custom({
    required HealthStoreChannel channel,
    required SyncStateStore state,
    SyncConfig config = const SyncConfig(),
  }) => HealthWorkoutSync._(channel: channel, state: state, config: config);

  static const Duration defaultInterval = Duration(hours: 1);

  /// WorkManager's floor for periodic work.
  static const Duration minInterval = Duration(minutes: 15);

  static const String periodicTaskName = 'health_workout_sync.periodic';

  final HealthStoreChannel _channel;
  final SyncStateStore _state;
  final SyncConfig _config;

  late final WorkoutSyncEngine _engine = WorkoutSyncEngine(
    channel: _channel,
    state: _state,
    config: _config,
  );

  WorkoutImporter? _importer;
  bool _initialized = false;

  HealthStore get store => _channel.store;

  // ── Setup ─────────────────────────────────────────────────────────────────

  /// Call once from the main isolate at startup. Registers the background
  /// entrypoints and re-arms background work for an existing connection.
  Future<void> initialize({
    required BackgroundImporterFactory backgroundImporter,
  }) async {
    final CallbackHandle? handle = PluginUtilities.getCallbackHandle(
      backgroundImporter,
    );
    if (handle == null) {
      throw ArgumentError(
        'backgroundImporter must be a top-level or static function annotated '
        "@pragma('vm:entry-point')",
      );
    }
    await _state.setBackgroundSetupHandle(handle.toRawHandle());
    // iOS routes HealthKit wakes to this engine while it's alive.
    _channel.setMethodCallHandler(_onNativeCall);
    if (Platform.isAndroid) {
      await Workmanager().initialize(healthWorkoutSyncCallbackDispatcher);
    }
    _initialized = true;
    if (await isConnected()) await _armBackground(replace: false);
  }

  /// The importer foreground syncs use (typically bound to the signed-in
  /// user). Pass null on sign-out.
  void attachImporter(WorkoutImporter? importer) => _importer = importer;

  // ── Connection ────────────────────────────────────────────────────────────

  /// True when the health store can be used right now. See [availability]
  /// to tell "install Health Connect first" apart from "not supported".
  Future<bool> isAvailable() => _channel.isAvailable();

  /// Whether the health store is ready, needs installing (Android 13 and
  /// lower, where Health Connect is a Play Store app) or isn't supported.
  Future<HealthAvailability> availability() => _channel.availability();

  /// Android: opens Google Play on Health Connect so the user can install
  /// or update it. Returns false on iOS (nothing to install).
  Future<bool> installHealthConnect() => _channel.installHealthConnect();

  Future<bool> isConnected() => _state.isConnected();

  /// Shows the platform permission sheet and, if granted, starts syncing
  /// from the start of today (no retroactive history). On Android the
  /// background-read permission is requested alongside when the device
  /// supports it.
  Future<ConnectResult> connect({bool requestBackground = true}) async {
    if (!await _channel.isAvailable()) return ConnectResult.unavailable;
    final HealthAuthorization auth;
    try {
      auth = await _channel.requestAuthorization(background: requestBackground);
    } on PlatformException catch (e) {
      debugPrint(
        '[HealthWorkoutSync] authorization failed: ${e.code} ${e.message}',
      );
      return ConnectResult.denied;
    }
    if (!auth.granted) return ConnectResult.denied;

    final DateTime now = DateTime.now();
    await _state.resetCursor();
    await _state.setConnectedAt(DateTime(now.year, now.month, now.day));
    await _state.setDisconnectedAt(null);
    if (await _state.firstConnectedAt() == null) {
      await _state.setFirstConnectedAt(now);
    }
    await _armBackground(replace: true);
    return ConnectResult.connected;
  }

  /// Re-asks for access WITHOUT resetting the connection: the cursor and the
  /// connect day stay, so workouts written while access was off still import
  /// on the next pass. Use when [HealthSyncStatus.readAuthorized] is false.
  Future<bool> requestAccess() async {
    if (!await _channel.isAvailable()) return false;
    try {
      final HealthAuthorization auth = await _channel.requestAuthorization(
        background: true,
      );
      if (auth.granted) await _armBackground(replace: false);
      return auth.granted;
    } on PlatformException {
      return false;
    }
  }

  /// Stops syncing and forgets the cursor. Already-imported workouts are the
  /// importer's business and stay. Platform permissions can only be revoked
  /// by the user (see [openHealthSettings]).
  Future<void> disconnect() async {
    await _channel.setBackgroundDelivery(enabled: false);
    if (Platform.isAndroid) {
      await Workmanager().cancelByUniqueName(periodicTaskName);
    }
    await _state.clearConnection();
    await _state.setDisconnectedAt(DateTime.now());
  }

  /// True when the user explicitly disconnected (don't auto-reconnect).
  Future<bool> wasDisconnected() async => await _state.disconnectedAt() != null;

  /// The permission sheet has been answered before (iOS) / exercise read is
  /// granted (Android). Useful to repair a connection flag after reinstall.
  Future<bool> hasAuthorization() async {
    try {
      return await _channel.hasAuthorization();
    } on PlatformException {
      return false;
    }
  }

  // ── Sync ──────────────────────────────────────────────────────────────────

  /// Runs one pass with [importer] (default: the attached one).
  Future<SyncReport> sync({
    SyncTrigger trigger = SyncTrigger.foreground,
    bool forceSweep = false,
    WorkoutImporter? importer,
  }) async {
    final WorkoutImporter? target = importer ?? _importer;
    if (target == null) return SyncReport.skipped(trigger, 'no_importer');
    return _engine.sync(target, trigger: trigger, forceSweep: forceSweep);
  }

  /// Testing aid: also import workouts this app wrote itself (normally
  /// skipped so an app that writes its own workouts never re-imports them).
  /// Persisted, so background passes honour it too.
  Future<void> setIncludeOwnWrites(bool value) =>
      _state.setIncludeOwnWrites(value);

  /// Forgets the cursor so the next pass re-reads everything since connect.
  Future<void> resetCursor() => _state.resetCursor();

  // ── Background ────────────────────────────────────────────────────────────

  Future<Duration> backgroundInterval() async {
    final int? minutes = await _state.intervalMinutes();
    return minutes == null ? defaultInterval : Duration(minutes: minutes);
  }

  /// Android: how often the WorkManager job runs (clamped to ≥ 15 min). The
  /// OS may run it later than asked (Doze, app standby buckets). iOS ignores
  /// it — HealthKit wakes the app when a workout is saved.
  Future<void> setBackgroundInterval(Duration interval) async {
    final Duration clamped = interval < minInterval ? minInterval : interval;
    await _state.setIntervalMinutes(clamped.inMinutes);
    if (await isConnected()) await _armBackground(replace: true);
  }

  /// Android WorkManager task handler — for apps with their own dispatcher.
  static Future<bool> handleWorkmanagerTask(String task) async {
    if (task != periodicTaskName) return true;
    try {
      final SyncReport report = await runBackgroundSync(SyncTrigger.periodic);
      debugPrint('[HealthWorkoutSync] periodic job: $report');
    } catch (e) {
      debugPrint('[HealthWorkoutSync] periodic sync threw: $e');
    }
    // Always "success": the next period retries anyway, and a failure result
    // would stack WorkManager's backoff on top of the schedule.
    return true;
  }

  Future<void> _armBackground({required bool replace}) async {
    if (!_initialized) return;
    if (Platform.isIOS) {
      final CallbackHandle? dispatcher = PluginUtilities.getCallbackHandle(
        healthWorkoutSyncIosBackgroundMain,
      );
      await _channel.setBackgroundDelivery(
        enabled: true,
        dispatcherHandle: dispatcher?.toRawHandle(),
      );
    } else if (Platform.isAndroid) {
      await Workmanager().registerPeriodicTask(
        periodicTaskName,
        periodicTaskName,
        frequency: await backgroundInterval(),
        constraints: Constraints(networkType: NetworkType.connected),
        existingWorkPolicy: replace
            ? ExistingPeriodicWorkPolicy.update
            : ExistingPeriodicWorkPolicy.keep,
      );
    }
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method != 'runSync') throw MissingPluginException(call.method);
    // No importer attached yet (e.g. still signing in) → build one the way a
    // background isolate would.
    final SyncReport report = _importer != null
        ? await sync(trigger: SyncTrigger.healthKitObserver)
        : await runBackgroundSync(SyncTrigger.healthKitObserver, state: _state);
    return report.toMap();
  }

  // ── Status ────────────────────────────────────────────────────────────────

  Future<HealthSyncStatus> status() async {
    final bool available = await _channel.isAvailable();
    final bool connected = await isConnected();
    bool background = Platform.isIOS;
    bool read = true;
    if (available && connected && Platform.isAndroid) {
      try {
        read = await _channel.hasAuthorization();
        background = read && await _channel.isBackgroundAuthorized();
      } on PlatformException {
        background = false;
      }
    }
    return HealthSyncStatus(
      store: store,
      available: available,
      connected: connected,
      connectedAt: await _state.connectedAt(),
      lastSyncAt: await _state.lastSyncAt(),
      lastBackgroundSyncAt: await _state.lastBackgroundSyncAt(),
      backgroundAuthorized: background,
      readAuthorized: read,
      backgroundInterval: await backgroundInterval(),
    );
  }

  /// Opens the system health settings.
  ///
  /// * [HealthSettingsPage.thisApp] (default) — where the user manages *this*
  ///   app's access. Use it when access was switched off.
  /// * [HealthSettingsPage.allApps] — Health Connect's main screen (Android),
  ///   listing every app's sharing. Use it to let the user check that their
  ///   fitness apps (Samsung Health, Garmin, …) are allowed to write workouts.
  ///
  /// iOS has no deep link to either: both open the Health app (or this app's
  /// Settings page when Health can't be opened).
  Future<bool> openHealthSettings({
    HealthSettingsPage page = HealthSettingsPage.thisApp,
  }) async {
    try {
      return await _channel.openHealthSettings(
        page: page == HealthSettingsPage.allApps ? 'home' : 'app',
      );
    } on PlatformException {
      return false;
    }
  }

  /// Whether this app may currently show notifications (see [notify]).
  Future<bool> notificationsEnabled() => _channel.notificationsEnabled();

  /// Asks the user to allow notifications — the system prompt on iOS and
  /// Android 13+. Call it from the UI (e.g. right after [connect]) so
  /// [notify] works later from background syncs. Returns whether
  /// notifications are allowed. Once the user has answered, the system won't
  /// ask again: send them to settings instead.
  Future<bool> requestNotificationPermission() =>
      _channel.requestNotificationPermission();

  /// Posts an immediate local notification — from any isolate, including the
  /// iOS background engine and the Android WorkManager job, so an importer
  /// can tell the user what a background pass found. A fixed [id] replaces
  /// the previous notification with that id.
  Future<NotifyResult> notify({
    required String id,
    required String title,
    required String body,
    String? androidChannelId,
    String? androidChannelName,
  }) => _channel.notify(
    id: id,
    title: title,
    body: body,
    androidChannelId: androidChannelId,
    androidChannelName: androidChannelName,
  );

  /// Which of [packages] are installed (Android only; see
  /// [HealthStoreChannel.installedPackages]).
  Future<List<String>> installedPackages(List<String> packages) =>
      _channel.installedPackages(packages);

  /// Opens another app (Android only), e.g. to turn on its sharing.
  Future<bool> launchPackage(String package) => _channel.launchPackage(package);

  /// Workouts in the store for a window, from every source (this app's own
  /// writes excluded) — for "which apps are sharing" status screens.
  Future<List<HealthWorkout>> recentWorkouts(Duration window) async {
    if (!await _channel.isAvailable()) return const <HealthWorkout>[];
    final DateTime now = DateTime.now();
    try {
      return await _channel.readWindow(now.subtract(window), now);
    } on PlatformException {
      return const <HealthWorkout>[];
    }
  }

  /// Third-party fitness apps (Samsung Health, Garmin, Oura, …) as seen from
  /// this device: which ones shared workouts in the last [window] (newest
  /// first) and — Android only — which known ones are installed but not
  /// sharing yet. Use it to build a "Your fitness apps" screen that tells the
  /// user what to switch on (see [FitnessAppGuide]).
  ///
  /// Never throws; returns what it could read.
  Future<List<FitnessAppStatus>> fitnessApps({
    Duration window = const Duration(days: 30),
  }) async {
    final List<String> packages = <String>[
      if (Platform.isAndroid)
        for (final FitnessAppGuide g in FitnessAppGuide.all)
          ...g.androidPackages,
    ];
    List<String> installed = const <String>[];
    try {
      installed = await installedPackages(packages);
    } catch (_) {}
    final List<HealthWorkout> workouts = await recentWorkouts(window);
    return buildFitnessAppStatuses(installed: installed, workouts: workouts);
  }

  /// iOS background-delivery diagnostics (dev menus).
  Future<Map<String, Object?>> diagnostics() =>
      _channel.backgroundDeliveryState();
}
