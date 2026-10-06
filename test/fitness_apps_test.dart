import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_sync/health_workout_sync.dart';

HealthWorkout _workout({String? appId, String? name, required DateTime end}) =>
    HealthWorkout(
      id: '${appId ?? name}-${end.millisecondsSinceEpoch}',
      store: HealthStore.healthConnect,
      start: end.subtract(const Duration(minutes: 30)),
      end: end,
      activityType: 'RUNNING',
      sourceAppId: appId,
      sourceName: name,
    );

void main() {
  test('statuses: newest sharing first, then installed not sharing', () {
    final DateTime now = DateTime(2026, 10, 5, 12);
    final List<FitnessAppStatus> rows = buildFitnessAppStatuses(
      installed: <String>['com.whoop.android', 'com.strava'],
      workouts: <HealthWorkout>[
        _workout(
          appId: 'com.strava',
          end: now.subtract(const Duration(days: 4)),
        ),
        _workout(
          appId: 'com.strava',
          end: now.subtract(const Duration(days: 1)),
        ),
        _workout(appId: 'com.ouraring.oura', end: now),
      ],
    );
    expect(rows.map((FitnessAppStatus r) => r.name), <String>[
      'Oura',
      'Strava',
      'WHOOP',
    ]);
    expect(rows[1].lastWorkoutAt, now.subtract(const Duration(days: 1)));
    expect(rows[1].installedPackage, 'com.strava');
    expect(rows[2].sharing, isFalse);
    expect(rows[2].guide?.id, 'whoop');
  });

  test('unknown sources keep their raw name', () {
    final List<FitnessAppStatus> rows = buildFitnessAppStatuses(
      installed: const <String>[],
      workouts: <HealthWorkout>[
        _workout(appId: 'com.example.rower', end: DateTime(2026)),
      ],
    );
    expect(rows.single.name, 'com.example.rower');
    expect(rows.single.guide, isNull);
    expect(rows.single.sharing, isTrue);
  });

  test('Apple sources never match a guide', () {
    final HealthWorkout w = _workout(
      appId: 'com.apple.health.123',
      name: "Laura's Apple Watch",
      end: DateTime(2026),
    );
    expect(guideForWorkout(w), isNull);
    expect(FitnessAppGuide.forSource('com.whoop.android')?.id, 'whoop');
  });

  test('every guide is complete for the platforms it supports', () {
    final Set<String> ids = <String>{};
    for (final FitnessAppGuide g in FitnessAppGuide.all) {
      expect(ids.add(g.id), isTrue, reason: 'duplicate id ${g.id}');
      if (g.healthConnect != ShareSupport.no) {
        expect(g.healthConnectSteps, isNotEmpty, reason: g.id);
      }
      if (g.appleHealth != ShareSupport.no) {
        expect(g.appleHealthSteps, isNotEmpty, reason: g.id);
      }
      expect(FitnessAppGuide.byId(g.id), same(g));
    }
  });
}
