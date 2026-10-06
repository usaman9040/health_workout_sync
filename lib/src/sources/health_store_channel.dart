import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import '../models.dart';

/// A page of changes since a cursor.
class WorkoutChanges {
  const WorkoutChanges({
    required this.workouts,
    required this.deletedIds,
    required this.cursor,
    this.expired = false,
  });

  const WorkoutChanges.expired()
    : workouts = const <HealthWorkout>[],
      deletedIds = const <String>[],
      cursor = null,
      expired = true;

  final List<HealthWorkout> workouts;
  final List<String> deletedIds;

  /// Cursor to persist once every workout above has settled.
  final String? cursor;

  /// The cursor is too old (Health Connect tokens expire after ~30 days
  /// unused). Start a fresh cursor and re-read a window instead.
  final bool expired;
}

/// Permission request outcome.
class HealthAuthorization {
  const HealthAuthorization({
    required this.granted,
    required this.backgroundGranted,
  });

  /// iOS: the sheet was handled (read denial is never revealed).
  /// Android: exercise read was granted.
  final bool granted;

  /// Android: background read granted (Android 15+ / newer Health Connect).
  /// iOS: always true once [granted].
  final bool backgroundGranted;
}

/// The native HealthKit / Health Connect bridge. Both platforms implement
/// the same channel contract, so this class has no platform branches beyond
/// [store].
class HealthStoreChannel {
  const HealthStoreChannel([
    this._channel = const MethodChannel('health_workout_sync'),
  ]);

  final MethodChannel _channel;

  HealthStore get store =>
      Platform.isIOS ? HealthStore.appleHealth : HealthStore.healthConnect;

  Future<bool> isAvailable() async {
    try {
      return await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<HealthAvailability> availability() async {
    try {
      final String? raw = await _channel.invokeMethod<String>('availability');
      return switch (raw) {
        'available' => HealthAvailability.available,
        'needs_install' => HealthAvailability.needsInstall,
        _ => HealthAvailability.unsupported,
      };
    } on MissingPluginException {
      return HealthAvailability.unsupported;
    }
  }

  Future<bool> installHealthConnect() async {
    try {
      return await _channel.invokeMethod<bool>('installHealthConnect') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<HealthAuthorization> requestAuthorization({
    required bool background,
  }) async {
    final Map<Object?, Object?>? raw = await _channel
        .invokeMethod<Map<Object?, Object?>>(
          'requestAuthorization',
          <String, Object?>{'background': background},
        );
    return HealthAuthorization(
      granted: raw?['granted'] as bool? ?? false,
      backgroundGranted: raw?['backgroundGranted'] as bool? ?? false,
    );
  }

  Future<bool> hasAuthorization() async =>
      await _channel.invokeMethod<bool>('hasAuthorization') ?? false;

  Future<bool> isBackgroundAuthorized() async =>
      await _channel.invokeMethod<bool>('isBackgroundAuthorized') ?? false;

  /// A cursor positioned at "now" (Android changes token). iOS returns null:
  /// a nil HealthKit anchor already means "everything matching the window".
  Future<String?> initialCursor() =>
      _channel.invokeMethod<String>('initialCursor');

  Future<WorkoutChanges> changes({
    required String? cursor,
    required DateTime since,
    bool includeOwnWrites = false,
  }) async {
    // Android needs a token to diff against; there is nothing to diff yet.
    if (cursor == null && Platform.isAndroid) {
      return const WorkoutChanges(
        workouts: <HealthWorkout>[],
        deletedIds: <String>[],
        cursor: null,
      );
    }
    final Map<Object?, Object?> raw =
        await _channel
            .invokeMethod<Map<Object?, Object?>>('changes', <String, Object?>{
              'cursor': cursor,
              'since': since.millisecondsSinceEpoch,
              'includeSelf': includeOwnWrites,
            }) ??
        const <Object?, Object?>{};
    if (raw['expired'] == true) return const WorkoutChanges.expired();
    return WorkoutChanges(
      workouts: _workouts(raw['workouts']),
      deletedIds: (raw['deleted'] as List<Object?>? ?? const <Object?>[])
          .whereType<String>()
          .toList(),
      cursor: raw['cursor'] as String?,
    );
  }

  Future<List<HealthWorkout>> readWindow(
    DateTime start,
    DateTime end, {
    bool includeOwnWrites = false,
  }) async {
    final List<Object?>? raw = await _channel
        .invokeMethod<List<Object?>>('readWindow', <String, Object?>{
          'start': start.millisecondsSinceEpoch,
          'end': end.millisecondsSinceEpoch,
          'includeSelf': includeOwnWrites,
        });
    return _workouts(raw);
  }

  Future<bool> openHealthSettings({String page = 'app'}) async =>
      await _channel.invokeMethod<bool>('openHealthSettings', <String, Object?>{
        'page': page,
      }) ??
      false;

  /// Which of [packages] are installed (Android; the host app must list them
  /// under `<queries>`). Always empty on iOS.
  Future<List<String>> installedPackages(List<String> packages) async {
    if (packages.isEmpty) return const <String>[];
    try {
      final List<Object?>? raw = await _channel.invokeMethod<List<Object?>>(
        'installedPackages',
        <String, Object?>{'packages': packages},
      );
      return (raw ?? const <Object?>[]).whereType<String>().toList();
    } on PlatformException {
      return const <String>[];
    } on MissingPluginException {
      return const <String>[];
    }
  }

  /// Opens another app by package (Android). False on iOS / not installed.
  Future<bool> launchPackage(String package) async {
    try {
      return await _channel.invokeMethod<bool>(
            'launchPackage',
            <String, Object?>{'package': package},
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// iOS only: arms / disarms HKObserverQuery background delivery and
  /// records the Dart entrypoint for headless wakes.
  Future<void> setBackgroundDelivery({
    required bool enabled,
    int? dispatcherHandle,
  }) async {
    if (!Platform.isIOS) return;
    await _channel.invokeMethod<void>(
      'setBackgroundDelivery',
      <String, Object?>{
        'enabled': enabled,
        'dispatcherHandle': ?dispatcherHandle,
      },
    );
  }

  /// iOS diagnostics: `{enabled, observing, delivery, lastWakeAt}`.
  Future<Map<String, Object?>> backgroundDeliveryState() async {
    if (!Platform.isIOS) return const <String, Object?>{};
    final Map<Object?, Object?>? raw = await _channel
        .invokeMethod<Map<Object?, Object?>>('backgroundDeliveryState');
    return raw?.map((Object? k, Object? v) => MapEntry(k! as String, v)) ??
        const <String, Object?>{};
  }

  /// Whether this app may currently show notifications.
  Future<bool> notificationsEnabled() async {
    try {
      return await _channel.invokeMethod<bool>('notificationsEnabled') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Shows the system notification prompt (iOS; Android 13+). Returns
  /// whether notifications are allowed afterwards.
  Future<bool> requestNotificationPermission() async {
    try {
      return await _channel.invokeMethod<bool>(
            'requestNotificationPermission',
          ) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Immediate local notification (works in background isolates).
  Future<NotifyResult> notify({
    required String id,
    required String title,
    required String body,
    String? androidChannelId,
    String? androidChannelName,
  }) async {
    try {
      final String? raw = await _channel
          .invokeMethod<String>('notify', <String, Object?>{
            'id': id,
            'title': title,
            'body': body,
            'channelId': ?androidChannelId,
            'channelName': ?androidChannelName,
          });
      return switch (raw) {
        'posted' => NotifyResult.posted,
        'not_authorized' => NotifyResult.notAuthorized,
        _ => NotifyResult.failed,
      };
    } on PlatformException {
      return NotifyResult.failed;
    } on MissingPluginException {
      return NotifyResult.failed;
    }
  }

  void setMethodCallHandler(
    Future<Object?> Function(MethodCall call)? handler,
  ) => _channel.setMethodCallHandler(handler);

  List<HealthWorkout> _workouts(Object? raw) =>
      (raw as List<Object?>? ?? const <Object?>[])
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> m) => HealthWorkout.fromMap(m, store))
          .toList();
}
