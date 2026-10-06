import 'dart:async';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'sources/health_store_channel.dart';
import 'sync_state_store.dart';
import 'workout_importer.dart';

/// Tunables. Defaults mirror the shipped iOS app.
@immutable
class SyncConfig {
  const SyncConfig({
    this.maxImportAttempts = 8,
    this.sweepWindow = const Duration(days: 3),
    this.sweepInterval = const Duration(hours: 6),
    this.maxRecheckAttempts = 3,
    this.expiredLookback = const Duration(days: 30),
    this.leaseTtl = const Duration(minutes: 3),
  });

  /// Passes a workout may hold the cursor before it's abandoned.
  final int maxImportAttempts;

  /// How far back the cursor-free safety sweep re-reads.
  final Duration sweepWindow;

  /// Minimum gap between sweeps (unless forced / re-armed).
  final Duration sweepInterval;

  /// Consecutive sweeps re-armed early by a retryable drop.
  final int maxRecheckAttempts;

  /// Window re-read when a Health Connect token has expired.
  final Duration expiredLookback;

  /// Cross-isolate lock lifetime (covers a crashed holder).
  final Duration leaseTtl;
}

/// The sync algorithm, platform-agnostic:
///
/// 1. **Cursor pass** — everything new since the persisted cursor (HealthKit
///    anchor / Health Connect changes token), windowed to the connect day.
///    The cursor only advances when every workout in the batch settled, so a
///    network error never loses a workout; a bounded retry budget stops one
///    bad workout from pinning it forever.
/// 2. **Deletions** — forwarded to the importer (audit), never blocking.
/// 3. **Sweep** — cursor-free re-read of the last few days, throttled, so a
///    workout dropped for a transient reason gets another chance. Cheap
///    because imports are idempotent.
class WorkoutSyncEngine {
  WorkoutSyncEngine({
    required this.channel,
    required this.state,
    this.config = const SyncConfig(),
    DateTime Function()? clock,
    void Function(String message)? log,
  }) : _now = clock ?? DateTime.now,
       _log = log ?? ((String m) => debugPrint('[HealthWorkoutSync] $m'));

  final HealthStoreChannel channel;
  final SyncStateStore state;
  final SyncConfig config;
  final DateTime Function() _now;
  final void Function(String) _log;

  Future<SyncReport>? _inFlight;

  /// Runs one pass. Concurrent callers in the same isolate share the pass in
  /// flight; another isolate holding the lease makes this a `busy` no-op.
  Future<SyncReport> sync(
    WorkoutImporter importer, {
    required SyncTrigger trigger,
    bool forceSweep = false,
  }) {
    return _inFlight ??= _guarded(
      importer,
      trigger,
      forceSweep,
    ).whenComplete(() => _inFlight = null);
  }

  Future<SyncReport> _guarded(
    WorkoutImporter importer,
    SyncTrigger trigger,
    bool forceSweep,
  ) async {
    final DateTime? connectedAt = await state.connectedAt();
    if (connectedAt == null) {
      return SyncReport.skipped(trigger, 'not_connected');
    }
    if (!await channel.isAvailable()) {
      return SyncReport.skipped(trigger, 'unavailable');
    }
    if (!await state.tryAcquireLease(config.leaseTtl)) {
      return SyncReport.skipped(trigger, 'busy');
    }
    try {
      final SyncReport report = await _run(
        importer,
        trigger,
        forceSweep,
        connectedAt,
      );
      if (report.ran) {
        try {
          await importer.syncCompleted(report);
        } catch (e) {
          _log('syncCompleted threw: $e');
        }
      }
      return report;
    } finally {
      await state.releaseLease();
    }
  }

  Future<SyncReport> _run(
    WorkoutImporter importer,
    SyncTrigger trigger,
    bool forceSweep,
    DateTime connectedAt,
  ) async {
    final DateTime now = _now();
    final bool own = await state.includeOwnWrites();

    // ── 1. Cursor pass ──────────────────────────────────────────────────────
    WorkoutChanges batch;
    try {
      batch = await _fetch(connectedAt, now, own);
    } catch (e) {
      _log('fetch failed ($trigger): $e');
      return SyncReport.skipped(trigger, 'fetch_failed');
    }

    final Map<String, HealthWorkout> unique = <String, HealthWorkout>{
      for (final HealthWorkout w in batch.workouts)
        if (!w.end.isBefore(connectedAt)) w.id: w,
    };

    int imported = 0;
    int settled = 0;
    final List<String> blocking = <String>[];
    for (final HealthWorkout workout in unique.values) {
      final ImportDecision decision = await _import(
        importer,
        workout,
        fromSweep: false,
      );
      if (decision == ImportDecision.imported) imported++;
      if (decision.isSettled) {
        settled++;
      } else {
        blocking.add(workout.id);
      }
    }

    // Deletions after additions: a provider "rewrite" is delete + re-add, and
    // the replacement should already be handled by the time the delete lands.
    for (final String id in batch.deletedIds) {
      try {
        await importer.workoutDeleted(id, channel.store);
      } catch (e) {
        _log('workoutDeleted($id) threw: $e');
      }
    }

    final (bool advanced, List<String> abandoned) = await _commitCursor(
      batch.cursor,
      blocking,
    );

    // ── 2. Sweep ────────────────────────────────────────────────────────────
    int recovered = 0;
    int sweepRetries = 0;
    bool swept = false;
    // Never on an iOS observer wake: that pass has seconds, not minutes.
    final bool sweepAllowed =
        forceSweep || trigger != SyncTrigger.healthKitObserver;
    if (sweepAllowed && await _sweepDue(forceSweep, now)) {
      swept = true;
      final DateTime windowStart = _later(
        now.subtract(config.sweepWindow),
        connectedAt,
      );
      try {
        final List<HealthWorkout> recent = await channel.readWindow(
          windowStart,
          now,
          includeOwnWrites: own,
        );
        for (final HealthWorkout workout in recent) {
          if (unique.containsKey(workout.id)) continue; // just handled above
          final ImportDecision decision = await _import(
            importer,
            workout,
            fromSweep: true,
          );
          if (decision == ImportDecision.imported) recovered++;
          if (!decision.isSettled) sweepRetries++;
        }
        if (sweepRetries == 0) await state.setLastSweepAt(now);
      } catch (e) {
        _log('sweep read failed: $e');
        sweepRetries++;
      }
    }

    // Retryable drops re-arm the sweep for the next pass — bounded, so a
    // permanently conflicting workout can't keep every pass sweeping.
    final int retryable = blocking.length + sweepRetries;
    if (retryable > 0) {
      final int attempts = await state.recheckAttempts();
      if (attempts < config.maxRecheckAttempts) {
        await state.setRecheckAttempts(attempts + 1);
        await state.setLastSweepAt(null);
      }
    } else {
      await state.setRecheckAttempts(0);
    }

    await state.setLastSyncAt(now);
    if (trigger == SyncTrigger.healthKitObserver ||
        trigger == SyncTrigger.periodic) {
      await state.setLastBackgroundSyncAt(now);
    }

    final SyncReport report = SyncReport(
      trigger: trigger,
      fetched: unique.length,
      imported: imported + recovered,
      settled: settled,
      retrying: advanced ? 0 : blocking.length,
      deleted: batch.deletedIds.length,
      recovered: recovered,
      abandoned: abandoned,
      cursorAdvanced: advanced,
      swept: swept,
    );
    if (report.sawData || abandoned.isNotEmpty) _log('$report');
    return report;
  }

  /// Changes since the cursor. A missing Android cursor (never primed) or an
  /// expired one restarts from a fresh cursor plus a window read — safe
  /// because the importer is idempotent.
  Future<WorkoutChanges> _fetch(
    DateTime connectedAt,
    DateTime now,
    bool own,
  ) async {
    final String? cursor = await state.cursor();
    final bool needsPrime =
        cursor == null && channel.store == HealthStore.healthConnect;
    final WorkoutChanges changes = needsPrime
        ? const WorkoutChanges.expired()
        : await channel.changes(
            cursor: cursor,
            since: connectedAt,
            includeOwnWrites: own,
          );
    if (!changes.expired) return changes;

    // Take the new cursor BEFORE reading so nothing written in between is
    // missed (it'd show up in both — harmless).
    final String? fresh = await channel.initialCursor();
    final DateTime from = needsPrime
        ? connectedAt
        : _later(now.subtract(config.expiredLookback), connectedAt);
    final List<HealthWorkout> window = await channel.readWindow(
      from,
      now,
      includeOwnWrites: own,
    );
    _log(
      needsPrime
          ? 'primed cursor, backfilled ${window.length}'
          : 'cursor expired, re-read ${window.length}',
    );
    return WorkoutChanges(
      workouts: window,
      deletedIds: const <String>[],
      cursor: fresh,
    );
  }

  Future<ImportDecision> _import(
    WorkoutImporter importer,
    HealthWorkout workout, {
    required bool fromSweep,
  }) async {
    try {
      return await importer.importWorkout(workout, fromSweep: fromSweep);
    } catch (e) {
      _log('import ${workout.id} threw: $e');
      return ImportDecision.retry;
    }
  }

  /// Saves [cursor] when nothing blocks; otherwise counts a retry for each
  /// blocker and only moves on once EVERY blocker has spent its budget
  /// (advancing earlier would skip the ones with attempts left).
  Future<(bool, List<String>)> _commitCursor(
    String? cursor,
    List<String> blocking,
  ) async {
    if (blocking.isEmpty) {
      if (cursor != null) await state.setCursor(cursor);
      await state.setStallCounts(const <String, int>{});
      return (true, const <String>[]);
    }
    final Map<String, int> previous = await state.stallCounts();
    final Map<String, int> counts = <String, int>{
      for (final String id in blocking) id: (previous[id] ?? 0) + 1,
    };
    final bool exhausted = counts.values.every(
      (int n) => n >= config.maxImportAttempts,
    );
    if (!exhausted) {
      await state.setStallCounts(counts);
      _log('${blocking.length} workout(s) unsettled — cursor held');
      return (false, const <String>[]);
    }
    if (cursor != null) await state.setCursor(cursor);
    await state.setStallCounts(const <String, int>{});
    _log(
      'abandoned ${blocking.length} workout(s) after ${config.maxImportAttempts} attempts',
    );
    return (true, List<String>.unmodifiable(blocking));
  }

  Future<bool> _sweepDue(bool force, DateTime now) async {
    if (force) return true;
    final DateTime? last = await state.lastSweepAt();
    return last == null || now.difference(last) >= config.sweepInterval;
  }

  static DateTime _later(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
}
