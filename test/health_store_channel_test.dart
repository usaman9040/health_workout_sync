import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:health_workout_sync/health_workout_sync.dart';

/// The Dart side of the channel contract both native sides implement.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const MethodChannel raw = MethodChannel('health_workout_sync');
  const HealthStoreChannel channel = HealthStoreChannel();
  final List<MethodCall> calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(raw, (MethodCall call) async {
          calls.add(call);
          return handler(call);
        });
  }

  setUp(calls.clear);

  final Map<String, Object?> nativeWorkout = <String, Object?>{
    'id': 'ABC-123',
    'start': DateTime.utc(2026, 9, 25, 7).millisecondsSinceEpoch,
    'end': DateTime.utc(2026, 9, 25, 7, 45).millisecondsSinceEpoch,
    'durationSeconds': 1800.0,
    'activityType': 'running',
    'sourceAppId': 'com.strava',
    'sourceName': 'Strava',
    'userEntered': false,
  };

  test(
    'changes: sends cursor/since/includeSelf and parses the payload',
    () async {
      answer(
        (_) => <String, Object?>{
          'workouts': <Object?>[nativeWorkout],
          'deleted': <Object?>['GONE-1'],
          'cursor': 'next',
          'expired': false,
        },
      );
      final WorkoutChanges changes = await channel.changes(
        cursor: 'prev',
        since: DateTime.utc(2026, 9, 25),
        includeOwnWrites: true,
      );

      expect(calls.single.method, 'changes');
      expect(calls.single.arguments, <String, Object?>{
        'cursor': 'prev',
        'since': DateTime.utc(2026, 9, 25).millisecondsSinceEpoch,
        'includeSelf': true,
      });
      final HealthWorkout w = changes.workouts.single;
      expect(w.id, 'ABC-123');
      expect(w.start, DateTime.utc(2026, 9, 25, 7));
      expect(
        w.minutes,
        45,
        reason: 'wall-clock span beats the 30 min reported',
      );
      expect(w.sourceAppId, 'com.strava');
      expect(changes.deletedIds, <String>['GONE-1']);
      expect(changes.cursor, 'next');
      expect(changes.expired, isFalse);
    },
  );

  test('changes: an expired token is surfaced, not parsed', () async {
    answer((_) => <String, Object?>{'expired': true});
    final WorkoutChanges changes = await channel.changes(
      cursor: 'old',
      since: DateTime.utc(2026),
    );
    expect(changes.expired, isTrue);
    expect(changes.workouts, isEmpty);
  });

  test('readWindow parses a list of workouts', () async {
    answer((_) => <Object?>[nativeWorkout, nativeWorkout]);
    final List<HealthWorkout> list = await channel.readWindow(
      DateTime.utc(2026, 9, 22),
      DateTime.utc(2026, 9, 25),
    );
    expect(list, hasLength(2));
    expect(calls.single.arguments, containsPair('includeSelf', false));
  });

  test('requestAuthorization maps granted flags', () async {
    answer(
      (_) => <String, Object?>{'granted': true, 'backgroundGranted': false},
    );
    final HealthAuthorization auth = await channel.requestAuthorization(
      background: true,
    );
    expect(auth.granted, isTrue);
    expect(auth.backgroundGranted, isFalse);
    expect(calls.single.arguments, <String, Object?>{'background': true});
  });

  test('isAvailable is false when the plugin is missing', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(raw, null);
    expect(await channel.isAvailable(), isFalse);
  });

  test('a native error propagates as PlatformException', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(raw, (MethodCall call) async {
          throw PlatformException(code: 'healthkit', message: 'locked');
        });
    expect(
      () => channel.readWindow(DateTime.utc(2026), DateTime.utc(2026, 2)),
      throwsA(isA<PlatformException>()),
    );
  });

  test('availability maps the native answers', () async {
    for (final (String? raw, HealthAvailability want)
        in <(String?, HealthAvailability)>[
          ('available', HealthAvailability.available),
          ('needs_install', HealthAvailability.needsInstall),
          ('unsupported', HealthAvailability.unsupported),
          (null, HealthAvailability.unsupported),
        ]) {
      answer((_) => raw);
      expect(await channel.availability(), want, reason: '$raw');
    }
  });

  test('openHealthSettings sends the page', () async {
    answer((_) => true);
    expect(await channel.openHealthSettings(page: 'home'), isTrue);
    expect(calls.single.method, 'openHealthSettings');
    expect(calls.single.arguments, <String, Object?>{'page': 'home'});
  });

  test('notification permission calls never throw', () async {
    answer((_) => throw PlatformException(code: 'no_activity'));
    expect(await channel.requestNotificationPermission(), isFalse);
    expect(await channel.notificationsEnabled(), isFalse);
    answer((_) => true);
    expect(await channel.requestNotificationPermission(), isTrue);
  });
}
