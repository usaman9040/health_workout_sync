import 'models.dart';

/// Where imported workouts go — implemented by the host app (a backend RPC,
/// a local database, …). The sync engine owns *when* and *what*; the importer
/// owns *how* a workout is stored.
///
/// Imports must be idempotent on [HealthWorkout.id]: the engine re-delivers a
/// workout whenever it can't prove the previous delivery settled (cursor
/// held, recent-window sweep). A unique key on `(store, id)` on the receiving
/// side is what makes that free.
abstract class WorkoutImporter {
  /// Stores one workout. Return [ImportDecision.retry] only for outcomes that
  /// may change on a later attempt; anything final must be settled
  /// (`imported` / `duplicate` / `skipped`) or it will pin the cursor
  /// (bounded by the engine's retry budget). Throwing counts as `retry`.
  ///
  /// [fromSweep] is true when the workout came from the recent-window safety
  /// sweep rather than the cursor — a "duplicate" answer is expected there.
  Future<ImportDecision> importWorkout(
    HealthWorkout workout, {
    required bool fromSweep,
  });

  /// The health store reported this workout id as deleted. Deletions are
  /// often half of a rewrite (delete + re-add with a new id), so a
  /// conservative importer just records them. Errors are ignored.
  Future<void> workoutDeleted(String workoutId, HealthStore store);

  /// Called once after every pass that ran (also in background isolates),
  /// after the cursor has been saved. Use for follow-up work: refreshing
  /// derived state, analytics, notifications.
  Future<void> syncCompleted(SyncReport report) async {}
}
