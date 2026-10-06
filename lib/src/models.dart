import 'package:meta/meta.dart';

/// Which health store a workout came from.
enum HealthStore {
  /// Apple Health (HealthKit) on iOS.
  appleHealth,

  /// Health Connect on Android — also where Samsung Health, Google Fit,
  /// Strava etc. land once the user links them to Health Connect.
  healthConnect,
}

/// One workout read from the health store, normalised across platforms.
@immutable
class HealthWorkout {
  const HealthWorkout({
    required this.id,
    required this.store,
    required this.start,
    required this.end,
    required this.activityType,
    this.reportedDuration,
    this.sourceAppId,
    this.sourceName,
    this.title,
    this.userEntered = false,
  });

  /// Stable id in the health store: the HealthKit sample UUID or the Health
  /// Connect record `metadata.id`. Use it as the idempotency key.
  final String id;

  final HealthStore store;
  final DateTime start;
  final DateTime end;

  /// Raw activity type name as the platform reports it:
  /// iOS → `HKWorkoutActivityType` case name (`running`,
  /// `traditionalStrengthTraining`, …); Android → the Health Connect
  /// `EXERCISE_TYPE_*` constant without its prefix (`RUNNING`,
  /// `STRENGTH_TRAINING`, …).
  final String activityType;

  /// Duration the writing app reported (iOS `HKWorkout.duration`). Can be
  /// shorter than the wall-clock span — see [minutes].
  final Duration? reportedDuration;

  /// Bundle id (iOS) / package name (Android) of the app that wrote it.
  final String? sourceAppId;

  /// Human-readable name of the writing app ("Garmin Connect"). On Android
  /// this is the app's label when Android lets this app see it (apps in
  /// [FitnessAppGuide.all] are visible), otherwise the package name.
  final String? sourceName;

  /// The title the writing app gave the workout ("Morning run"), when it set
  /// one. Android only.
  final String? title;

  /// True when the user typed the workout in by hand rather than recording it.
  final bool userEntered;

  /// Whole minutes: the longer of the reported duration and the wall-clock
  /// span. HealthKit's `duration` is derived from activity segments and can
  /// under-report (even 0) for a full session, so the span rescues those.
  int get minutes {
    final int span = (end.difference(start).inSeconds / 60).round();
    final int reported = ((reportedDuration?.inSeconds ?? 0) / 60).round();
    return span > reported ? span : reported;
  }

  factory HealthWorkout.fromMap(Map<Object?, Object?> map, HealthStore store) {
    return HealthWorkout(
      id: map['id']! as String,
      store: store,
      start: DateTime.fromMillisecondsSinceEpoch(
        (map['start']! as num).toInt(),
        isUtc: true,
      ),
      end: DateTime.fromMillisecondsSinceEpoch(
        (map['end']! as num).toInt(),
        isUtc: true,
      ),
      activityType: map['activityType'] as String? ?? 'other',
      reportedDuration: map['durationSeconds'] == null
          ? null
          : Duration(
              milliseconds: ((map['durationSeconds']! as num) * 1000).round(),
            ),
      sourceAppId: map['sourceAppId'] as String?,
      sourceName: map['sourceName'] as String?,
      title: map['title'] as String?,
      userEntered: map['userEntered'] as bool? ?? false,
    );
  }

  @override
  String toString() =>
      'HealthWorkout($id, $activityType, $minutes min, ${sourceAppId ?? '?'})';
}

/// What the importer did with a workout. Decides whether the sync cursor may
/// move past it: everything except [retry] is final.
enum ImportDecision {
  /// Newly stored.
  imported,

  /// Was already stored (idempotent re-delivery).
  duplicate,

  /// Deliberately not stored, for a reason that can never change (e.g. the
  /// day's cap was already full).
  skipped,

  /// Not accounted for (network error, a conflict that may clear later).
  /// The cursor holds so the next sync sees the workout again.
  retry;

  bool get isSettled => this != retry;
}

/// Why a sync ran.
enum SyncTrigger {
  /// App opened / came to the foreground, or the caller asked.
  foreground,

  /// iOS HealthKit background delivery woke the app.
  healthKitObserver,

  /// Android WorkManager periodic job.
  periodic,

  /// User pressed "sync now" / the manage screen opened.
  manual,
}

/// Outcome of one sync pass.
@immutable
class SyncReport {
  const SyncReport({
    required this.trigger,
    this.skippedReason,
    this.fetched = 0,
    this.imported = 0,
    this.settled = 0,
    this.retrying = 0,
    this.deleted = 0,
    this.recovered = 0,
    this.abandoned = const <String>[],
    this.cursorAdvanced = false,
    this.swept = false,
  });

  /// The sync didn't run: `not_connected`, `busy`, `unavailable`,
  /// `no_importer`, `fetch_failed`.
  final String? skippedReason;

  final SyncTrigger trigger;

  /// New / changed workouts the cursor reported.
  final int fetched;

  /// Newly stored this pass (cursor + sweep).
  final int imported;
  final int settled;

  /// Workouts left for the next pass (cursor held).
  final int retrying;

  /// Deletions the store reported.
  final int deleted;

  /// Workouts only the recent-window sweep found — i.e. the cursor had
  /// missed them. Worth alarming on if it's ever non-zero.
  final int recovered;

  /// Ids the cursor gave up on after exhausting their retry budget.
  final List<String> abandoned;

  final bool cursorAdvanced;
  final bool swept;

  bool get ran => skippedReason == null;

  /// Anything new came in (worth refreshing UI / XP).
  bool get sawData => fetched > 0 || deleted > 0 || recovered > 0;

  const SyncReport.skipped(this.trigger, String reason)
    : skippedReason = reason,
      fetched = 0,
      imported = 0,
      settled = 0,
      retrying = 0,
      deleted = 0,
      recovered = 0,
      abandoned = const <String>[],
      cursorAdvanced = false,
      swept = false;

  Map<String, Object?> toMap() => <String, Object?>{
    'trigger': trigger.name,
    'skippedReason': skippedReason,
    'fetched': fetched,
    'imported': imported,
    'settled': settled,
    'retrying': retrying,
    'deleted': deleted,
    'recovered': recovered,
    'abandoned': abandoned,
    'cursorAdvanced': cursorAdvanced,
    'swept': swept,
  };

  @override
  String toString() => 'SyncReport(${toMap()})';
}

/// Whether the health store can be used on this device
/// ([HealthWorkoutSync.availability]).
enum HealthAvailability {
  /// Ready: Apple Health on iPhone, Health Connect on Android.
  available,

  /// Android 13 and lower: the Health Connect app must be installed or
  /// updated from Google Play first — see
  /// [HealthWorkoutSync.installHealthConnect].
  needsInstall,

  /// Not possible on this device (iPad without Health, very old Android).
  unsupported,
}

/// Result of [HealthWorkoutSync.connect].
enum ConnectResult {
  /// Permission flow finished; syncing is on. On iOS this doesn't prove read
  /// access was granted — HealthKit never reveals a read denial — so the
  /// first sync returning data is the only real signal.
  connected,

  /// The user declined (Android) or the request failed.
  denied,

  /// No health store on this device (iPad without Health, Android without
  /// Health Connect).
  unavailable,
}

/// Which screen [HealthWorkoutSync.openHealthSettings] opens.
enum HealthSettingsPage {
  /// This app's own health permissions.
  thisApp,

  /// Every app's sharing (Health Connect's main screen on Android).
  allApps,
}

/// Result of [HealthWorkoutSync.notify].
enum NotifyResult {
  posted,

  /// The user hasn't allowed notifications (or revoked them).
  notAuthorized,
  failed,
}
