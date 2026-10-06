import 'dart:convert';

import 'package:health_workout_sync/health_workout_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where this example "stores" workouts: a JSON map on the device, keyed by
/// the workout id. In a real app this is your backend / database call.
///
/// Notice the pattern every importer follows:
/// * already stored? → [ImportDecision.duplicate]
/// * stored now      → [ImportDecision.imported]
/// * deliberately not stored (too short) → [ImportDecision.skipped]
/// * failed, try again later → [ImportDecision.retry] (or just throw)
class LocalWorkoutImporter extends WorkoutImporter {
  static const String _key = 'example.imported_workouts';

  // SharedPreferencesAsync reads straight from disk, so the background sync
  // (a separate isolate) and the UI always see the same data.
  final SharedPreferencesAsync _prefs = SharedPreferencesAsync();

  /// Everything imported so far, newest first.
  Future<List<StoredWorkout>> all() async {
    final Map<String, dynamic> map = await _read();
    final List<StoredWorkout> list =
        map.values
            .map(
              (dynamic v) => StoredWorkout.fromJson(v as Map<String, dynamic>),
            )
            .toList()
          ..sort(
            (StoredWorkout a, StoredWorkout b) => b.start.compareTo(a.start),
          );
    return list;
  }

  Future<void> clear() => _prefs.remove(_key);

  @override
  Future<ImportDecision> importWorkout(
    HealthWorkout workout, {
    required bool fromSweep,
  }) async {
    // Your business rules go here. Example: ignore anything under a minute.
    if (workout.minutes < 1) return ImportDecision.skipped;

    final Map<String, dynamic> map = await _read();
    if (map.containsKey(workout.id)) return ImportDecision.duplicate;

    map[workout.id] = StoredWorkout(
      id: workout.id,
      type: workout.activityType,
      start: workout.start,
      minutes: workout.minutes,
      source: workout.sourceName ?? workout.sourceAppId ?? 'Unknown app',
    ).toJson();
    await _prefs.setString(_key, jsonEncode(map));
    return ImportDecision.imported;
  }

  @override
  Future<void> workoutDeleted(String workoutId, HealthStore store) async {
    // A workout was deleted in Apple Health / Health Connect. Most apps keep
    // what they already imported; remove it here if yours shouldn't.
  }

  @override
  Future<void> syncCompleted(SyncReport report) async {
    // Runs after every sync — including background ones while the app is
    // closed. Tell the user when a background sync found something.
    final bool background =
        report.trigger == SyncTrigger.healthKitObserver ||
        report.trigger == SyncTrigger.periodic;
    if (background && report.imported > 0) {
      await HealthWorkoutSync.instance.notify(
        id: 'workouts-imported',
        title: 'Workouts imported',
        body: '${report.imported} new workout(s) from your health app.',
      );
    }
  }

  Future<Map<String, dynamic>> _read() async {
    final String? raw = await _prefs.getString(_key);
    if (raw == null) return <String, dynamic>{};
    return jsonDecode(raw) as Map<String, dynamic>;
  }
}

class StoredWorkout {
  const StoredWorkout({
    required this.id,
    required this.type,
    required this.start,
    required this.minutes,
    required this.source,
  });

  factory StoredWorkout.fromJson(Map<String, dynamic> json) => StoredWorkout(
    id: json['id'] as String,
    type: json['type'] as String,
    start: DateTime.parse(json['start'] as String),
    minutes: json['minutes'] as int,
    source: json['source'] as String,
  );

  final String id;
  final String type;
  final DateTime start;
  final int minutes;
  final String source;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'type': type,
    'start': start.toIso8601String(),
    'minutes': minutes,
    'source': source,
  };
}
