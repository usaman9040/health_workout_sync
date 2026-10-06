import 'package:flutter/foundation.dart';

import '../models.dart';
import 'fitness_app_guide.dart';

/// One third-party fitness app as seen from this device: is it sharing
/// workouts into the health store, and (Android) is it installed.
///
/// Returned by `HealthWorkoutSync.fitnessApps()`. Typical use is a
/// "Your fitness apps" list:
///
/// * [sharing] → "✓ Garmin Connect — last workout 2 days ago"
/// * not sharing but installed → "Samsung Health isn't sharing workouts —
///   here's how" (show [guide]'s steps, offer "Open Samsung Health" via
///   [installedPackage]).
@immutable
class FitnessAppStatus {
  const FitnessAppStatus({
    required this.name,
    this.guide,
    this.installedPackage,
    this.lastWorkoutAt,
  });

  /// The guide's app name, or the raw source (name / package) when the app
  /// isn't in [FitnessAppGuide.all].
  final String name;

  /// Setup instructions, or null for an app we have no guide for.
  final FitnessAppGuide? guide;

  /// Android: the installed package for this app, for
  /// `HealthWorkoutSync.launchPackage`. Null when not installed (or on iOS).
  final String? installedPackage;

  /// End of the newest workout this app shared in the window.
  final DateTime? lastWorkoutAt;

  /// The app wrote at least one workout in the window.
  bool get sharing => lastWorkoutAt != null;

  @override
  String toString() =>
      'FitnessAppStatus($name, sharing: $sharing, '
      'installed: ${installedPackage ?? '-'})';
}

/// Builds the rows: apps that shared workouts (newest first), then — on
/// Android — guide apps installed but not sharing yet (guide order).
List<FitnessAppStatus> buildFitnessAppStatuses({
  required List<String> installed,
  required List<HealthWorkout> workouts,
}) {
  final Set<String> installedSet = installed.toSet();
  String? installedFor(FitnessAppGuide g) {
    for (final String p in g.androidPackages) {
      if (installedSet.contains(p)) return p;
    }
    return null;
  }

  final Map<String, FitnessAppStatus> byKey = <String, FitnessAppStatus>{};
  for (final HealthWorkout w in workouts) {
    final FitnessAppGuide? guide = guideForWorkout(w);
    final String raw = (w.sourceName?.trim().isNotEmpty ?? false)
        ? w.sourceName!.trim()
        : (w.sourceAppId ?? '').trim();
    if (guide == null && raw.isEmpty) continue;
    final String key = guide != null ? 'guide:${guide.id}' : 'raw:$raw';
    final FitnessAppStatus? prev = byKey[key];
    if (prev != null && !w.end.isAfter(prev.lastWorkoutAt!)) continue;
    byKey[key] = FitnessAppStatus(
      name: guide?.appName ?? raw,
      guide: guide,
      installedPackage: guide == null ? null : installedFor(guide),
      lastWorkoutAt: w.end,
    );
  }

  final List<FitnessAppStatus> sharing = byKey.values.toList()
    ..sort(
      (FitnessAppStatus a, FitnessAppStatus b) =>
          b.lastWorkoutAt!.compareTo(a.lastWorkoutAt!),
    );
  final List<FitnessAppStatus> notSharing = <FitnessAppStatus>[
    for (final FitnessAppGuide g in FitnessAppGuide.all)
      if (!byKey.containsKey('guide:${g.id}') && installedFor(g) != null)
        FitnessAppStatus(
          name: g.appName,
          guide: g,
          installedPackage: installedFor(g),
        ),
  ];
  return <FitnessAppStatus>[...sharing, ...notSharing];
}

/// The guide for the app that wrote [w]: its id first, then its name.
/// Apple's own sources (Apple Watch, Fitness, Health) never match a guide.
FitnessAppGuide? guideForWorkout(HealthWorkout w) {
  final String id = (w.sourceAppId ?? '').toLowerCase();
  if (id.startsWith('com.apple.')) return null;
  return FitnessAppGuide.forSource(w.sourceAppId) ??
      FitnessAppGuide.forSource(w.sourceName);
}
