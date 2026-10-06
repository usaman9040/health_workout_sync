/// Workout import from Apple Health (HealthKit) and Android Health Connect.
///
/// * Cursor-based sync (HealthKit anchors / Health Connect changes tokens)
///   that never advances past an unsettled workout.
/// * iOS background delivery (HKObserverQuery → headless engine).
/// * Android periodic WorkManager sync with a user-settable interval.
/// * Storage is yours: implement [WorkoutImporter].
/// * Third-party app guidance: [FitnessAppGuide], [HealthWorkoutSync.fitnessApps]
///   and the ready-made [HealthSharingReminder] card.
library;

export 'src/background.dart'
    show
        BackgroundImporterFactory,
        healthWorkoutSyncCallbackDispatcher,
        healthWorkoutSyncIosBackgroundMain,
        runBackgroundSync;
export 'src/fitness_apps/fitness_app_guide.dart';
export 'src/fitness_apps/fitness_app_status.dart';
export 'src/health_workout_sync.dart';
export 'src/models.dart';
export 'src/sources/health_store_channel.dart';
export 'src/sync_engine.dart' show SyncConfig, WorkoutSyncEngine;
export 'src/sync_state_store.dart';
export 'src/widgets/health_sharing_reminder.dart';
export 'src/workout_importer.dart';
