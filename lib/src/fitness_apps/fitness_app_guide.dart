import 'package:flutter/foundation.dart';

import '../models.dart';

/// How well a source app gets workouts into the phone's health store.
enum ShareSupport {
  /// Writes workouts once the user turns sharing on.
  yes,

  /// Writes some workouts (see [FitnessAppGuide.limitation]).
  partial,

  /// Doesn't write workouts — needs a bridge app or isn't possible.
  no,
}

/// Per-app instructions for getting workouts from a third-party fitness app
/// into Health Connect (Android) / Apple Health (iOS), so your app can import
/// them.
///
/// Third-party apps (Samsung Health, Garmin, Oura, …) only write workouts to
/// the phone's health store once the user turns sharing on *inside that
/// app*. Use [all] to show the user what to tap, [forSource] to name the app
/// that wrote a [HealthWorkout], and `HealthWorkoutSync.fitnessApps()` to
/// find which ones are installed or already sharing.
///
/// Sourced from vendor support pages (October 2026). Paths marked
/// `// unverified` came from secondary sources; vendors move menus, so treat
/// the steps as guidance.
@immutable
class FitnessAppGuide {
  const FitnessAppGuide({
    required this.id,
    required this.appName,
    required this.healthConnect,
    required this.appleHealth,
    this.androidPackages = const <String>[],
    this.sourceKeywords = const <String>[],
    this.healthConnectSteps = const <String>[],
    this.appleHealthSteps = const <String>[],
    this.limitation,
    this.bridge,
  });

  final String id;

  /// The companion app the user opens ("Samsung Health", "Garmin Connect").
  final String appName;

  /// Android package names, for "is it installed" checks and opening the
  /// app. Must also be listed under `<queries>` in AndroidManifest.xml.
  final List<String> androidPackages;

  /// Lower-case fragments matched against a workout's source (package on
  /// Android, bundle id / app name on iOS) to tell which app wrote it.
  final List<String> sourceKeywords;

  final ShareSupport healthConnect;
  final ShareSupport appleHealth;

  /// Menu path inside the companion app, one step per entry.
  final List<String> healthConnectSteps;
  final List<String> appleHealthSteps;

  /// Caveat worth showing ("Only GPS activities are shared").
  final String? limitation;

  /// What to use instead when the app can't share workouts directly.
  final String? bridge;

  ShareSupport support({required bool android}) =>
      android ? healthConnect : appleHealth;

  List<String> steps({required bool android}) =>
      android ? healthConnectSteps : appleHealthSteps;

  bool matchesSource(String source) {
    final String s = source.toLowerCase();
    return sourceKeywords.any(s.contains) ||
        androidPackages.any((String p) => s == p.toLowerCase());
  }

  static FitnessAppGuide? byId(String id) {
    for (final FitnessAppGuide g in all) {
      if (g.id == id) return g;
    }
    return null;
  }

  /// The guide whose app wrote a workout from [source], if known.
  static FitnessAppGuide? forSource(String? source) {
    if (source == null || source.isEmpty) return null;
    for (final FitnessAppGuide g in all) {
      if (g.matchesSource(source)) return g;
    }
    return null;
  }

  static const List<FitnessAppGuide> all = <FitnessAppGuide>[
    FitnessAppGuide(
      id: 'samsung',
      appName: 'Samsung Health',
      androidPackages: <String>['com.sec.android.app.shealth'],
      sourceKeywords: <String>['shealth', 'samsung'],
      healthConnect: ShareSupport.yes,
      healthConnectSteps: <String>[
        'Open Samsung Health and tap ⋮ → Settings.',
        'Tap Health Connect.',
        'Allow Exercise (or tap Allow all).',
      ],
      appleHealth: ShareSupport.no,
      limitation:
          'Galaxy Watch workouts arrive after the watch syncs to your phone — '
          'open Samsung Health to sync sooner.',
    ),
    FitnessAppGuide(
      id: 'garmin',
      appName: 'Garmin Connect',
      androidPackages: <String>['com.garmin.android.apps.connectmobile'],
      sourceKeywords: <String>['garmin'],
      healthConnect: ShareSupport.yes,
      healthConnectSteps: <String>[
        'Open Garmin Connect and go to Settings.',
        'Tap Connected Apps → Health Connect.', // unverified
        'Turn on Exercise and allow access.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Garmin Connect and tap More → Settings.',
        'Tap Connected Apps → Apple Health → Connect.',
        'Turn on Workouts.',
      ],
    ),
    FitnessAppGuide(
      id: 'oura',
      appName: 'Oura',
      androidPackages: <String>['com.ouraring.oura'],
      sourceKeywords: <String>['oura'],
      healthConnect: ShareSupport.yes,
      healthConnectSteps: <String>[
        'Open Oura and tap the menu (top left) → Settings.',
        'Tap Data Sharing → Health Connect.',
        'Turn on Exercise and allow access.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Oura and go to Settings.',
        'Tap Data Sharing → Apple Health.', // unverified
        'Turn on Workouts.',
      ],
    ),
    FitnessAppGuide(
      id: 'whoop',
      appName: 'WHOOP',
      androidPackages: <String>['com.whoop.android'],
      sourceKeywords: <String>['whoop'],
      healthConnect: ShareSupport.yes,
      healthConnectSteps: <String>[
        'Open WHOOP and tap More → Account & Settings.',
        'Tap Integrations → Health Connect.',
        'Allow Exercise.',
      ],
      appleHealth: ShareSupport.yes, // unverified
      appleHealthSteps: <String>[
        'Open WHOOP and tap More → Account & Settings.',
        'Tap Integrations → Apple Health.',
        'Turn on Workouts.',
      ],
    ),
    FitnessAppGuide(
      id: 'fitbit',
      appName: 'Google Health (Fitbit)',
      androidPackages: <String>['com.fitbit.FitbitMobile'],
      sourceKeywords: <String>['fitbit', 'google health'],
      healthConnect: ShareSupport.yes,
      healthConnectSteps: <String>[
        'Open the Google Health (Fitbit) app and tap Connections.',
        'Tap Partner apps → Sync your favorite health apps → Set up.',
        'Choose Exercise and allow access.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Update the Google Health (Fitbit) app, then tap Connections.',
        'Tap Apps and services → Apple Health → Get started.',
        'Allow Workouts.',
      ],
      limitation:
          'Apple Health sharing needs Google Health 5.05 (Aug 2026) or newer.',
    ),
    FitnessAppGuide(
      id: 'strava',
      appName: 'Strava',
      androidPackages: <String>['com.strava'],
      sourceKeywords: <String>['strava'],
      healthConnect: ShareSupport.partial,
      healthConnectSteps: <String>[
        'Open Strava and tap You → ⚙ Settings.',
        'Tap Manage Apps and Devices → Health Connect.',
        'Allow access.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Strava and tap You → ⚙ Settings.',
        'Tap Manage Apps and Devices → Health → Connect.',
        'Allow Workouts, then turn on Send to Health.',
      ],
      limitation:
          'On Android, Strava only shares GPS activities (runs, rides, '
          'walks).',
    ),
    FitnessAppGuide(
      id: 'polar',
      appName: 'Polar Flow',
      androidPackages: <String>['com.polar.polarflow'],
      sourceKeywords: <String>['polar'],
      healthConnect: ShareSupport.yes,
      healthConnectSteps: <String>[
        'Open Polar Flow and go to General settings.',
        'Tap Health Connect.',
        'Choose Exercise and tap Allow.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Polar Flow and tap More → General settings.',
        'Turn on Apple Health.',
        'Tap Turn All Categories On → Allow.',
      ],
      limitation: 'Only workouts recorded after you turn this on are shared.',
    ),
    FitnessAppGuide(
      id: 'coros',
      appName: 'COROS',
      androidPackages: <String>['com.coros.coros'],
      sourceKeywords: <String>['coros'],
      healthConnect: ShareSupport.yes, // unverified
      healthConnectSteps: <String>[
        'Open COROS and tap Profile → Settings.',
        'Tap 3rd Party Apps → Data Sync → Health Connect.',
        'Allow Exercise.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open COROS and tap Profile → Settings.',
        'Tap 3rd Party Apps → Data Sync → Apple Health.',
        'Allow Workouts.',
      ],
    ),
    FitnessAppGuide(
      id: 'suunto',
      appName: 'Suunto',
      androidPackages: <String>['com.stt.android.suunto'],
      sourceKeywords: <String>['suunto'],
      healthConnect: ShareSupport.no,
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Suunto and go to Profile.',
        'Tap Partner services → Apple Health.', // unverified
        'Allow Workouts.',
      ],
      bridge:
          'Connect Suunto to Strava, then turn on Strava\'s health sharing.',
    ),
    FitnessAppGuide(
      id: 'zepp',
      appName: 'Zepp (Amazfit)',
      androidPackages: <String>['com.huami.watch.hmwatchmanager'],
      sourceKeywords: <String>['zepp', 'amazfit', 'huami'],
      healthConnect: ShareSupport.yes, // unverified
      healthConnectSteps: <String>[
        'Open Zepp and tap Profile.',
        'Tap Add accounts → Health Connect.',
        'Allow Exercise.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Zepp and tap Profile.',
        'Tap Add accounts → Apple Health.',
        'Turn on Workouts.',
      ],
    ),
    FitnessAppGuide(
      id: 'huawei',
      appName: 'Huawei Health',
      androidPackages: <String>['com.huawei.health'],
      sourceKeywords: <String>['huawei'],
      healthConnect: ShareSupport.no,
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Huawei Health and tap Me → Settings.', // unverified
        'Turn on Health app data sharing.',
        'Tap Turn All Categories On → Allow.',
      ],
      bridge:
          'Huawei Health doesn\'t share with Health Connect. A third-party '
          'bridge app such as Health Sync can copy your workouts across.',
    ),
    FitnessAppGuide(
      id: 'xiaomi',
      appName: 'Mi Fitness',
      androidPackages: <String>['com.xiaomi.wearable'],
      sourceKeywords: <String>['xiaomi', 'mi fitness'],
      healthConnect: ShareSupport.yes,
      healthConnectSteps: <String>[
        'Open Mi Fitness and go to Settings.',
        'Tap Health Connect.',
        'Turn on Exercise and allow access.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Mi Fitness and tap Profile.',
        'Tap Third-party data → Health.',
        'Select Workouts.',
      ],
    ),
    FitnessAppGuide(
      id: 'withings',
      appName: 'Withings',
      androidPackages: <String>['com.withings.wiscale2'],
      sourceKeywords: <String>['withings'],
      healthConnect: ShareSupport.yes, // unverified
      healthConnectSteps: <String>[
        'Open Withings and tap Profile → ⚙ Settings.',
        'Tap Export health data to Health Connect.',
        'Allow Exercise.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Withings and go to Partner apps.', // unverified
        'Tap Apple Health and connect.',
        'Turn on Workouts.',
      ],
      limitation:
          'Withings can take a while to share — open the Withings app to '
          'sync sooner.',
    ),
    FitnessAppGuide(
      id: 'peloton',
      appName: 'Peloton',
      androidPackages: <String>['com.onepeloton.callisto'],
      sourceKeywords: <String>['peloton'],
      healthConnect: ShareSupport.yes,
      healthConnectSteps: <String>[
        'Open Peloton and go to Settings → Connected apps.', // unverified
        'Tap Health Connect.',
        'Allow Exercise.',
      ],
      appleHealth: ShareSupport.yes, // unverified
      appleHealthSteps: <String>[
        'Open Peloton and go to Settings → Connected apps.',
        'Tap Apple Health.',
        'Allow Workouts.',
      ],
    ),
    FitnessAppGuide(
      id: 'hevy',
      appName: 'Hevy',
      androidPackages: <String>['com.hevy'],
      sourceKeywords: <String>['hevy'],
      healthConnect: ShareSupport.yes,
      healthConnectSteps: <String>[
        'Open Hevy and go to Settings → Integrations.',
        'Tap Health Connect and allow Exercise.',
        'Keep "Sync with Health Connect" on when you save a workout.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Hevy and go to Settings → Integrations.',
        'Tap Apple Health.',
        'Allow Workouts.',
      ],
    ),
    FitnessAppGuide(
      id: 'strong',
      appName: 'Strong',
      androidPackages: <String>['io.strongapp.strong'],
      sourceKeywords: <String>['strong'],
      healthConnect: ShareSupport.yes,
      healthConnectSteps: <String>[
        'Open Strong and go to Settings.',
        'Tap Health Connect.', // unverified
        'Allow Exercise.',
      ],
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Strong and go to Settings.',
        'Tap Apple Health.',
        'Allow Workouts.',
      ],
    ),
    FitnessAppGuide(
      id: 'nike',
      appName: 'Nike Run Club',
      androidPackages: <String>['com.nike.plusgps', 'com.nike.ntc'],
      sourceKeywords: <String>['nike'],
      healthConnect: ShareSupport.no,
      appleHealth: ShareSupport.yes,
      appleHealthSteps: <String>[
        'Open Nike Run Club and go to Settings.',
        'Turn on Health.',
        'Allow Workouts.',
      ],
      bridge: 'Nike apps don\'t share workouts with Health Connect yet.',
    ),
    FitnessAppGuide(
      id: 'myfitnesspal',
      appName: 'MyFitnessPal',
      androidPackages: <String>['com.myfitnesspal.android'],
      sourceKeywords: <String>['myfitnesspal'],
      healthConnect: ShareSupport.partial,
      healthConnectSteps: <String>[
        'Open MyFitnessPal and tap Menu → Apps & Devices.', // unverified
        'Tap Health Connect.',
        'Allow Exercise.',
      ],
      appleHealth: ShareSupport.partial,
      appleHealthSteps: <String>[
        'Open MyFitnessPal and tap More → Apps & Devices.', // unverified
        'Tap Apple Health → Connect.',
        'Allow Workouts.',
      ],
      limitation:
          'Only exercise you log in MyFitnessPal itself is shared — not '
          'workouts it received from other apps.',
    ),
  ];
}
