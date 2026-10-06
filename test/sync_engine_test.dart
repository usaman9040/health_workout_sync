import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_sync/health_workout_sync.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// Scriptable stand-in for the native bridge.
class FakeChannel implements HealthStoreChannel {
  FakeChannel(this.store);

  @override
  final HealthStore store;

  bool available = true;
  WorkoutChanges Function(String? cursor)? onChanges;
  List<HealthWorkout> window = <HealthWorkout>[];
  String initial = 'token-0';
  final List<(DateTime, DateTime)> windowReads = <(DateTime, DateTime)>[];
  int changeCalls = 0;
  bool? lastIncludeOwn;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<WorkoutChanges> changes({
    required String? cursor,
    required DateTime since,
    bool includeOwnWrites = false,
  }) async {
    changeCalls++;
    lastIncludeOwn = includeOwnWrites;
    return onChanges!(cursor);
  }

  @override
  Future<List<HealthWorkout>> readWindow(
    DateTime start,
    DateTime end, {
    bool includeOwnWrites = false,
  }) async {
    windowReads.add((start, end));
    return window;
  }

  @override
  Future<String?> initialCursor() async =>
      store == HealthStore.healthConnect ? initial : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Records calls; decisions scripted per workout id.
class FakeImporter extends WorkoutImporter {
  final Map<String, ImportDecision> decisions = <String, ImportDecision>{};
  final List<String> imported = <String>[];
  final List<String> sweepImports = <String>[];
  final List<String> deleted = <String>[];
  final List<SyncReport> completed = <SyncReport>[];

  @override
  Future<ImportDecision> importWorkout(
    HealthWorkout workout, {
    required bool fromSweep,
  }) async {
    (fromSweep ? sweepImports : imported).add(workout.id);
    return decisions[workout.id] ?? ImportDecision.imported;
  }

  @override
  Future<void> workoutDeleted(String workoutId, HealthStore store) async =>
      deleted.add(workoutId);

  @override
  Future<void> syncCompleted(SyncReport report) async => completed.add(report);
}

HealthWorkout workout(String id, DateTime start, {int minutes = 30}) =>
    HealthWorkout(
      id: id,
      store: HealthStore.appleHealth,
      start: start,
      end: start.add(Duration(minutes: minutes)),
      activityType: 'running',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final DateTime today = DateTime(2026, 9, 25);
  final DateTime now = DateTime(2026, 9, 25, 18);
  late SyncStateStore state;
  late FakeImporter importer;

  setUp(() async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    state = SyncStateStore();
    importer = FakeImporter();
    await state.setConnectedAt(today);
    // Sweep off unless a test wants it.
    await state.setLastSweepAt(now);
  });

  WorkoutSyncEngine engine(FakeChannel channel) => WorkoutSyncEngine(
    channel: channel,
    state: state,
    clock: () => now,
    log: (_) {},
  );

  group('cursor', () {
    test('advances when every workout settles', () async {
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
        ..onChanges = (_) => WorkoutChanges(
          workouts: <HealthWorkout>[
            workout('a', today.add(const Duration(hours: 8))),
          ],
          deletedIds: const <String>['gone'],
          cursor: 'anchor-1',
        );
      final SyncReport r = await engine(
        ch,
      ).sync(importer, trigger: SyncTrigger.foreground);

      expect(r.cursorAdvanced, isTrue);
      expect(r.imported, 1);
      expect(await state.cursor(), 'anchor-1');
      expect(importer.imported, <String>['a']);
      expect(importer.deleted, <String>['gone']);
      expect(importer.completed.single.fetched, 1);
    });

    test(
      'holds while a workout needs a retry, then advances once it settles',
      () async {
        final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
          ..onChanges = (_) => WorkoutChanges(
            workouts: <HealthWorkout>[
              workout('ok', today.add(const Duration(hours: 7))),
              workout('flaky', today.add(const Duration(hours: 9))),
            ],
            deletedIds: const <String>[],
            cursor: 'anchor-2',
          );
        importer.decisions['flaky'] = ImportDecision.retry;
        final SyncReport first = await engine(
          ch,
        ).sync(importer, trigger: SyncTrigger.foreground);
        expect(first.cursorAdvanced, isFalse);
        expect(first.retrying, 1);
        expect(await state.cursor(), isNull);
        expect(await state.stallCounts(), <String, int>{'flaky': 1});

        importer.decisions['flaky'] = ImportDecision.duplicate;
        final SyncReport second = await engine(
          ch,
        ).sync(importer, trigger: SyncTrigger.foreground);
        expect(second.cursorAdvanced, isTrue);
        expect(await state.cursor(), 'anchor-2');
        expect(await state.stallCounts(), isEmpty);
      },
    );

    test('an exception from the importer counts as retry', () async {
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
        ..onChanges = (_) => WorkoutChanges(
          workouts: <HealthWorkout>[
            workout('boom', today.add(const Duration(hours: 1))),
          ],
          deletedIds: const <String>[],
          cursor: 'anchor',
        );
      final _ThrowingImporter throwing = _ThrowingImporter();
      final SyncReport r = await engine(
        ch,
      ).sync(throwing, trigger: SyncTrigger.foreground);
      expect(r.cursorAdvanced, isFalse);
    });

    test('abandons only after every blocker spent its retry budget', () async {
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
        ..onChanges = (_) => WorkoutChanges(
          workouts: <HealthWorkout>[
            workout('stuck', today.add(const Duration(hours: 2))),
          ],
          deletedIds: const <String>[],
          cursor: 'anchor-3',
        );
      importer.decisions['stuck'] = ImportDecision.retry;
      final WorkoutSyncEngine e = engine(ch);
      for (int i = 1; i < 8; i++) {
        final SyncReport r = await e.sync(
          importer,
          trigger: SyncTrigger.foreground,
        );
        expect(r.cursorAdvanced, isFalse, reason: 'attempt $i');
      }
      final SyncReport last = await e.sync(
        importer,
        trigger: SyncTrigger.foreground,
      );
      expect(last.cursorAdvanced, isTrue);
      expect(last.abandoned, <String>['stuck']);
      expect(await state.cursor(), 'anchor-3');
    });

    test('ignores workouts that ended before the connect day', () async {
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
        ..onChanges = (_) => WorkoutChanges(
          workouts: <HealthWorkout>[
            workout('old', today.subtract(const Duration(days: 2))),
          ],
          deletedIds: const <String>[],
          cursor: 'anchor',
        );
      final SyncReport r = await engine(
        ch,
      ).sync(importer, trigger: SyncTrigger.foreground);
      expect(importer.imported, isEmpty);
      expect(r.fetched, 0);
    });
  });

  group('health connect token', () {
    test(
      'first pass primes a token and backfills from the connect day',
      () async {
        final FakeChannel ch = FakeChannel(HealthStore.healthConnect)
          ..window = <HealthWorkout>[
            workout('morning', today.add(const Duration(hours: 6))),
          ]
          ..onChanges = (_) => fail('should not diff without a token');
        final SyncReport r = await engine(
          ch,
        ).sync(importer, trigger: SyncTrigger.foreground);

        expect(ch.changeCalls, 0);
        expect(ch.windowReads.single.$1, today);
        expect(importer.imported, <String>['morning']);
        expect(r.cursorAdvanced, isTrue);
        expect(await state.cursor(), 'token-0');
      },
    );

    test(
      'expired token re-reads the lookback window with a fresh token',
      () async {
        await state.setCursor('stale');
        await state.setConnectedAt(today.subtract(const Duration(days: 90)));
        final FakeChannel ch = FakeChannel(HealthStore.healthConnect)
          ..initial = 'token-fresh'
          ..window = <HealthWorkout>[workout('w', today)]
          ..onChanges = (_) => const WorkoutChanges.expired();
        await engine(ch).sync(importer, trigger: SyncTrigger.periodic);

        expect(
          ch.windowReads.single.$1,
          now.subtract(const Duration(days: 30)),
        );
        expect(await state.cursor(), 'token-fresh');
        expect(await state.lastBackgroundSyncAt(), now);
      },
    );
  });

  group('sweep', () {
    test('re-imports the recent window and counts recoveries', () async {
      await state.setLastSweepAt(null);
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
        ..window = <HealthWorkout>[
          workout('known', today),
          workout('missed', today),
        ]
        ..onChanges = (_) => const WorkoutChanges(
          workouts: <HealthWorkout>[],
          deletedIds: <String>[],
          cursor: 'a',
        );
      importer.decisions['known'] = ImportDecision.duplicate;
      final SyncReport r = await engine(
        ch,
      ).sync(importer, trigger: SyncTrigger.foreground);

      expect(r.swept, isTrue);
      expect(r.recovered, 1);
      expect(importer.sweepImports, <String>['known', 'missed']);
      expect(await state.lastSweepAt(), now);
    });

    test('never runs on an iOS observer wake unless forced', () async {
      await state.setLastSweepAt(null);
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
        ..onChanges = (_) => const WorkoutChanges(
          workouts: <HealthWorkout>[],
          deletedIds: <String>[],
          cursor: 'a',
        );
      final SyncReport r = await engine(
        ch,
      ).sync(importer, trigger: SyncTrigger.healthKitObserver);
      expect(r.swept, isFalse);
      expect(ch.windowReads, isEmpty);
    });

    test('is throttled', () async {
      await state.setLastSweepAt(now.subtract(const Duration(hours: 1)));
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
        ..onChanges = (_) => const WorkoutChanges(
          workouts: <HealthWorkout>[],
          deletedIds: <String>[],
          cursor: 'a',
        );
      final SyncReport r = await engine(
        ch,
      ).sync(importer, trigger: SyncTrigger.foreground);
      expect(r.swept, isFalse);
    });

    test('a retryable drop re-arms the sweep for the next pass', () async {
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
        ..onChanges = (_) => WorkoutChanges(
          workouts: <HealthWorkout>[
            workout('x', today.add(const Duration(hours: 3))),
          ],
          deletedIds: const <String>[],
          cursor: 'a',
        );
      importer.decisions['x'] = ImportDecision.retry;
      await engine(ch).sync(importer, trigger: SyncTrigger.foreground);
      expect(await state.lastSweepAt(), isNull);
      expect(await state.recheckAttempts(), 1);
    });
  });

  test('passes the persisted include-own-writes flag to the store', () async {
    await state.setIncludeOwnWrites(true);
    final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
      ..onChanges = (_) => const WorkoutChanges(
        workouts: <HealthWorkout>[],
        deletedIds: <String>[],
        cursor: 'a',
      );
    await engine(ch).sync(importer, trigger: SyncTrigger.foreground);
    expect(ch.lastIncludeOwn, isTrue);
  });

  group('guards', () {
    test('not connected → skipped, importer untouched', () async {
      await state.setConnectedAt(null);
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth);
      final SyncReport r = await engine(
        ch,
      ).sync(importer, trigger: SyncTrigger.foreground);
      expect(r.skippedReason, 'not_connected');
      expect(importer.completed, isEmpty);
    });

    test('another isolate holding the lease → busy', () async {
      await state.tryAcquireLease(const Duration(minutes: 5));
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth);
      final SyncReport r = await engine(
        ch,
      ).sync(importer, trigger: SyncTrigger.periodic);
      expect(r.skippedReason, 'busy');
    });

    test('a failed read keeps the cursor and releases the lease', () async {
      await state.setCursor('keep');
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
        ..onChanges = (_) =>
            throw PlatformException(code: 'healthkit', message: 'locked');
      final SyncReport r = await engine(
        ch,
      ).sync(importer, trigger: SyncTrigger.foreground);
      expect(r.skippedReason, 'fetch_failed');
      expect(await state.cursor(), 'keep');
      expect(await state.tryAcquireLease(const Duration(minutes: 1)), isTrue);
    });

    test('concurrent calls in one isolate share one pass', () async {
      final FakeChannel ch = FakeChannel(HealthStore.appleHealth)
        ..onChanges = (_) => WorkoutChanges(
          workouts: <HealthWorkout>[
            workout('a', today.add(const Duration(hours: 1))),
          ],
          deletedIds: const <String>[],
          cursor: 'a',
        );
      final WorkoutSyncEngine e = engine(ch);
      final List<SyncReport> both = await Future.wait(<Future<SyncReport>>[
        e.sync(importer, trigger: SyncTrigger.foreground),
        e.sync(importer, trigger: SyncTrigger.manual),
      ]);
      expect(identical(both[0], both[1]), isTrue);
      expect(importer.imported, <String>['a']);
    });
  });

  test('minutes takes the longer of reported duration and wall-clock span', () {
    final HealthWorkout underReported = HealthWorkout(
      id: 'u',
      store: HealthStore.appleHealth,
      start: today,
      end: today.add(const Duration(minutes: 42)),
      activityType: 'running',
      reportedDuration: Duration.zero,
    );
    expect(underReported.minutes, 42);
    final HealthWorkout paused = HealthWorkout(
      id: 'p',
      store: HealthStore.appleHealth,
      start: today,
      end: today.add(const Duration(minutes: 10)),
      activityType: 'running',
      reportedDuration: const Duration(minutes: 12),
    );
    expect(paused.minutes, 12);
  });
}

class _ThrowingImporter extends WorkoutImporter {
  @override
  Future<ImportDecision> importWorkout(
    HealthWorkout workout, {
    required bool fromSweep,
  }) => throw StateError('network');

  @override
  Future<void> workoutDeleted(String workoutId, HealthStore store) async {}
}
