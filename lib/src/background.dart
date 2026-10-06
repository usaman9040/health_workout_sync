import 'dart:ui' show CallbackHandle, PluginUtilities;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'health_workout_sync.dart';
import 'models.dart';
import 'sync_state_store.dart';
import 'workout_importer.dart';

/// Builds the importer inside a background isolate, where none of the app's
/// startup has run: initialise whatever the importer needs (backend client,
/// session) and return null when there's nobody to import for (signed out).
///
/// Must be a top-level or static function annotated
/// `@pragma('vm:entry-point')` so it survives tree-shaking and can be looked
/// up by callback handle.
typedef BackgroundImporterFactory = Future<WorkoutImporter?> Function();

/// Android WorkManager entrypoint. Registered by
/// [HealthWorkoutSync.initialize]. If the host app already uses WorkManager
/// with its own dispatcher, call [HealthWorkoutSync.handleWorkmanagerTask]
/// from it instead.
@pragma('vm:entry-point')
void healthWorkoutSyncCallbackDispatcher() {
  Workmanager().executeTask(
    (String task, Map<String, dynamic>? input) =>
        HealthWorkoutSync.handleWorkmanagerTask(task),
  );
}

/// iOS headless-engine entrypoint, started natively when HealthKit wakes the
/// app in the background and no Flutter engine is running.
@pragma('vm:entry-point')
Future<void> healthWorkoutSyncIosBackgroundMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('health_workout_sync/background');
  channel.setMethodCallHandler((MethodCall call) async {
    if (call.method != 'runSync') return null;
    final SyncReport report = await runBackgroundSync(
      SyncTrigger.healthKitObserver,
    );
    return report.toMap();
  });
  await channel.invokeMethod<void>('backgroundReady');
}

/// Resolves the host app's [BackgroundImporterFactory] from its stored
/// callback handle and runs one pass with it.
Future<SyncReport> runBackgroundSync(
  SyncTrigger trigger, {
  SyncStateStore? state,
}) async {
  final SyncStateStore store = state ?? SyncStateStore();
  final int? raw = await store.backgroundSetupHandle();
  final Function? callback = raw == null
      ? null
      : PluginUtilities.getCallbackFromHandle(
          CallbackHandle.fromRawHandle(raw),
        );
  if (callback is! BackgroundImporterFactory) {
    return SyncReport.skipped(trigger, 'no_importer');
  }
  WorkoutImporter? importer;
  try {
    importer = await callback();
  } catch (e) {
    debugPrint('[HealthWorkoutSync] background importer factory threw: $e');
  }
  if (importer == null) return SyncReport.skipped(trigger, 'no_importer');
  return HealthWorkoutSync.instance.sync(trigger: trigger, importer: importer);
}
