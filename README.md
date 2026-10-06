# health_workout_sync

[![pub version](https://img.shields.io/pub/v/health_workout_sync.svg)](https://pub.dev/packages/health_workout_sync)
[![pub points](https://img.shields.io/pub/points/health_workout_sync)](https://pub.dev/packages/health_workout_sync/score)
[![CI](https://github.com/usaman9040/health_workout_sync/actions/workflows/ci.yml/badge.svg)](https://github.com/usaman9040/health_workout_sync/actions/workflows/ci.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Get your users' workouts from Apple Health (iPhone) and Health Connect (Android) into your app — automatically, in the background, with nothing lost and nothing counted twice.**

Your users record workouts with all kinds of apps and watches: Apple Watch, Garmin, Samsung Galaxy Watch, Fitbit, Oura, WHOOP, Strava… Those apps don't talk to your app. They all write to the phone's health store — **Apple Health** on iPhone, **Health Connect** on Android. This package reads new workouts from there and hands each one to *your* code exactly once.

```
Apple Watch, Garmin, Samsung, Fitbit, Strava …
            │ (they write workouts)
            ▼
 Apple Health (iOS)  /  Health Connect (Android)
            │ (this package reads only what's new)
            ▼
   your importer  →  your backend / database
```

## What you get

| Feature | |
|---|---|
| Permission sheet for Apple Health / Health Connect | `connect()` |
| Only **new** workouts each time (remembers where it stopped) | built in |
| **Never imports the same workout twice** (stable id per workout) | built in |
| **Never loses a workout** (if your save fails, it's offered again) | built in |
| Runs while the app is **closed** — iOS: the moment a workout is saved; Android: on a schedule | built in |
| Background schedule on Android, **user-adjustable** (default 1 hour) | `setBackgroundInterval()` |
| Local notifications from background syncs | `notify()` |
| "Which of my apps are sharing?" + step-by-step guides for 18 fitness apps | `fitnessApps()`, `FitnessAppGuide` |
| Ready-made "make sure your workouts sync" card | `HealthSharingReminder` |
| Android privacy-policy screen Health Connect requires | built in (one line of config) |

It does **not** draw your screens (except the optional card), decide your business rules, or write data to the health store. It only reads **workouts** — no steps, heart rate, sleep, etc.

It talks to HealthKit and Health Connect directly through its own native code (it doesn't wrap the `health` package).

---

## Contents

1. [Install](#1-install)
2. [iOS setup](#2-ios-setup-5-minutes)
3. [Android setup](#3-android-setup-2-minutes)
4. [Write your importer](#4-write-your-importer)
5. [Start the package in `main.dart`](#5-start-the-package-in-maindart)
6. [Connect button](#6-connect-button)
7. [Sync when the app opens](#7-sync-when-the-app-opens)
8. [Every scenario, handled](#8-every-scenario-handled)
9. [Third-party apps: help users turn sharing on](#9-third-party-apps-help-users-turn-sharing-on)
10. [Testing](#10-testing)
11. [Troubleshooting](#11-troubleshooting)
12. [API reference](#12-api-reference)
13. [How it works](#13-how-it-works)

A complete working app lives in [`example/`](example/) — the fastest way to learn is to run it.

---

## 1. Install

```bash
flutter pub add health_workout_sync
```

Requirements: Flutter 3.44+, **iOS 16+**, **Android 8.0+ (API 26)**.

## 2. iOS setup (5 minutes)

### 2.1 Turn on HealthKit in Xcode

1. Open `ios/Runner.xcworkspace` in Xcode.
2. Click **Runner** (left sidebar) → target **Runner** → **Signing & Capabilities**.
3. Click **+ Capability** → add **HealthKit**.
4. Under HealthKit, tick **Background Delivery**.

This creates `ios/Runner/Runner.entitlements`. It should contain:

```xml
<key>com.apple.developer.healthkit</key>
<true/>
<key>com.apple.developer.healthkit.access</key>
<array/>
<key>com.apple.developer.healthkit.background-delivery</key>
<true/>
```

### 2.2 Explain why you need Health data

In `ios/Runner/Info.plist`, inside the top `<dict>`:

```xml
<key>NSHealthShareUsageDescription</key>
<string>We read your workouts from Apple Health to track your training.</string>
```

iOS shows this text in the permission sheet. Without it, the app **crashes** when asking for permission.

### 2.3 Minimum iOS version

In `ios/Podfile` (if you have one) set `platform :ios, '16.0'`, and in Xcode → Runner target → **General** → **Minimum Deployments** → **16.0**.

### 2.4 AppDelegate (for background syncs)

Open `ios/Runner/AppDelegate.swift` and add the three marked lines:

```swift
import Flutter
import UIKit
import health_workout_sync                                   // ← 1

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    HealthWorkoutSyncPlugin.setPluginRegistrantCallback { registry in   // ← 2
      GeneratedPluginRegistrant.register(with: registry)
    }
    HealthWorkoutSyncPlugin.startBackgroundDelivery()                   // ← 3

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
```

Why: when HealthKit wakes your closed app, the sync runs in a separate Flutter engine that needs your plugins (line 2), and HealthKit's watcher must be re-armed on **every** launch or background delivery silently stops (line 3).

> Newer Flutter templates register plugins in `didInitializeImplicitFlutterEngine` instead of calling `GeneratedPluginRegistrant.register(with: self)`. Keep whatever your template has — just add lines 1–3. See [`example/ios/Runner/AppDelegate.swift`](example/ios/Runner/AppDelegate.swift).

## 3. Android setup (2 minutes)

### 3.1 Minimum SDK

`android/app/build.gradle.kts` (or `build.gradle`):

```kotlin
android {
    defaultConfig {
        minSdk = 26
    }
}
```

### 3.2 Your privacy policy link

Health Connect **refuses to show its permission screen** unless your app links to a privacy policy. The package provides the screen; you provide the URL. In `android/app/src/main/AndroidManifest.xml`, inside `<application>`:

```xml
<meta-data
    android:name="health_workout_sync.privacy_policy_url"
    android:value="https://your-site.com/privacy" />
```

That's all. Permissions (`READ_EXERCISE`, `READ_HEALTH_DATA_IN_BACKGROUND`, `POST_NOTIFICATIONS`), the privacy-policy screen and the package-visibility `<queries>` are added to your app automatically.

> Your `MainActivity` can stay a plain `FlutterActivity`.

### 3.3 Google Play

When you publish, Google Play asks you to declare Health Connect usage (Play Console → App content → Health apps). Declare **read access to Exercise** and explain what you use it for.

## 4. Write your importer

The importer is the one piece you write: *"what do I do with a workout?"* The package calls it once per new workout.

```dart
// lib/workout_importer.dart
import 'package:health_workout_sync/health_workout_sync.dart';

class MyWorkoutImporter extends WorkoutImporter {
  @override
  Future<ImportDecision> importWorkout(
    HealthWorkout workout, {
    required bool fromSweep,
  }) async {
    try {
      final bool created = await myApi.saveWorkout(
        externalId: workout.id,          // ← make this UNIQUE in your database
        type: workout.activityType,      // "running", "STRENGTH_TRAINING", …
        start: workout.start,
        end: workout.end,
        minutes: workout.minutes,
        app: workout.sourceName,         // "Garmin Connect", "Samsung Health", …
      );
      return created ? ImportDecision.imported : ImportDecision.duplicate;
    } catch (e) {
      return ImportDecision.retry;       // offline? server down? try next sync
    }
  }

  @override
  Future<void> workoutDeleted(String workoutId, HealthStore store) async {
    // The user deleted it in Apple Health / Health Connect.
    // Most apps keep what they imported. Remove it here if yours shouldn't.
  }
}
```

### The four answers

| Return | Means | The package… |
|---|---|---|
| `ImportDecision.imported` | Saved it now | moves on |
| `ImportDecision.duplicate` | I already had it | moves on |
| `ImportDecision.skipped` | I don't want it, ever (e.g. under a minute) | moves on |
| `ImportDecision.retry` | Couldn't save **right now** | offers it again next sync |

Throwing an exception counts as `retry`. A workout that keeps failing is given up after 8 syncs (listed in `SyncReport.abandoned`) so it can't block everything behind it.

### The one rule: make `workout.id` unique on your side

The package may hand you the same workout again (after a retry, after a reinstall, from the safety re-check). That's by design. Store `workout.id` with a **unique constraint** and answer `duplicate` when it's already there — then repeats are harmless.

<details>
<summary>Examples: REST API, Firebase Firestore, Supabase, local storage</summary>

**REST API**

```dart
final res = await http.post(
  Uri.parse('https://api.example.com/workouts'),
  headers: {'Authorization': 'Bearer $token', 'Content-Type': 'application/json'},
  body: jsonEncode({
    'external_id': workout.id,
    'type': workout.activityType,
    'start': workout.start.toIso8601String(),
    'minutes': workout.minutes,
  }),
);
if (res.statusCode == 201) return ImportDecision.imported;
if (res.statusCode == 409) return ImportDecision.duplicate; // unique conflict
return ImportDecision.retry;
```

**Firebase Firestore** — use the workout id as the document id:

```dart
final doc = FirebaseFirestore.instance
    .collection('users/$uid/workouts')
    .doc(workout.id);
final created = await FirebaseFirestore.instance.runTransaction((tx) async {
  if ((await tx.get(doc)).exists) return false;
  tx.set(doc, {'type': workout.activityType, 'start': workout.start, 'minutes': workout.minutes});
  return true;
});
return created ? ImportDecision.imported : ImportDecision.duplicate;
```

**Supabase** — unique index on `(user_id, external_id)`:

```dart
final rows = await Supabase.instance.client
    .from('workouts')
    .upsert({
      'user_id': userId,
      'external_id': workout.id,
      'type': workout.activityType,
      'start_time': workout.start.toIso8601String(),
      'minutes': workout.minutes,
    }, onConflict: 'user_id,external_id', ignoreDuplicates: true)
    .select();
return rows.isEmpty ? ImportDecision.duplicate : ImportDecision.imported;
```

**On the device only** — see [`example/lib/local_workout_importer.dart`](example/lib/local_workout_importer.dart).

</details>

### What's in a `HealthWorkout`

| Field | Example | Notes |
|---|---|---|
| `id` | `"9F2C…"` | Stable id from the health store. **Your unique key.** |
| `store` | `HealthStore.healthConnect` | `appleHealth` or `healthConnect` |
| `start`, `end` | `DateTime` (UTC) | |
| `minutes` | `30` | Rounded; the longer of reported duration and start→end |
| `activityType` | iOS `"running"`, Android `"RUNNING"` | iOS: `HKWorkoutActivityType` name. Android: Health Connect `EXERCISE_TYPE_*` without the prefix |
| `sourceName` | `"Garmin Connect"` | App that recorded it (Android falls back to the package name) |
| `sourceAppId` | `"com.garmin.android.apps.connectmobile"` | Bundle id / package name |
| `title` | `"Morning run"` | Android only, when the app set one |
| `userEntered` | `true` | Typed in by hand rather than recorded |

## 5. Start the package in `main.dart`

```dart
import 'package:flutter/material.dart';
import 'package:health_workout_sync/health_workout_sync.dart';

import 'workout_importer.dart';

// Called when the app is woken in the BACKGROUND (app closed).
// Must be a top-level function (not inside a class) with this exact annotation.
@pragma('vm:entry-point')
Future<WorkoutImporter?> backgroundImporter() async {
  // Nothing from main() has run here. Initialise what your importer needs:
  // await Firebase.initializeApp();
  // await Supabase.initialize(url: …, anonKey: …);
  final bool signedIn = await isUserSignedIn();   // your own check
  return signedIn ? MyWorkoutImporter() : null;   // null = skip this time
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await HealthWorkoutSync.instance.initialize(
    backgroundImporter: backgroundImporter,
  );

  // The importer used while the app is OPEN. (null while signed out.)
  if (await isUserSignedIn()) {
    HealthWorkoutSync.instance.attachImporter(MyWorkoutImporter());
  }

  runApp(const MyApp());
}
```

## 6. Connect button

```dart
ElevatedButton(
  onPressed: () async {
    final sync = HealthWorkoutSync.instance;

    // Android 9–13: Health Connect is a separate app from Google Play.
    if (await sync.availability() == HealthAvailability.needsInstall) {
      await sync.installHealthConnect();
      return;
    }

    switch (await sync.connect()) {           // shows the permission sheet
      case ConnectResult.connected:
        await sync.requestNotificationPermission(); // optional, see 8.7
        await sync.sync();                          // import today's workouts
      case ConnectResult.denied:
        // Show: "Allow workout access to sync" + a button → sync.openHealthSettings()
        break;
      case ConnectResult.unavailable:
        // iPad, or a phone without Health Connect support
        break;
    }
  },
  child: const Text('Connect Apple Health / Health Connect'),
)
```

**Import starts from the beginning of the day the user connects** — older history isn't imported (so users can't backfill weeks of workouts in one go).

> **iOS hides "denied".** Apple never tells apps whether the user refused *read* access, so on iPhone `connect()` returns `connected` either way. If no workouts ever arrive, point the user to *Settings → Health → Data Access & Devices → your app*.

## 7. Sync when the app opens

Background syncs happen on their own. Also sync whenever the app comes to the foreground so the user sees fresh data immediately:

```dart
class _HomeState extends State<Home> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _sync);
    _sync();
  }

  Future<void> _sync() async {
    final SyncReport report = await HealthWorkoutSync.instance.sync();
    if (report.imported > 0) {
      // refresh your UI
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }
  // …
}
```

`sync()` is safe to call any time: if not connected, signed out, or a sync is already running, it returns immediately (`report.ran == false`, see `report.skippedReason`).

---

## 8. Every scenario, handled

### 8.1 The app is closed and the user finishes a workout

- **iPhone:** HealthKit wakes your app within seconds/minutes, the package runs `backgroundImporter()` and imports it. Nothing to do beyond [2.4](#24-appdelegate-for-background-syncs).
- **Android:** Health Connect can't wake apps, so the package runs a background job **every hour** (default). The workout arrives at the next run, or immediately when the user opens the app.

### 8.2 Let the user choose how often Android syncs

```dart
// Settings screen
await HealthWorkoutSync.instance.setBackgroundInterval(const Duration(minutes: 30));

// Read the current value
final Duration every = await HealthWorkoutSync.instance.backgroundInterval();
```

Minimum is **15 minutes** (Android's limit). Android may run it later than asked to save battery (Doze). The job only runs with an internet connection. iOS ignores this setting — it syncs the moment a workout is saved.

A ready-made picker is in the [example](example/lib/main.dart) (search for `Background sync`).

### 8.3 Network error / server down

Return `ImportDecision.retry` (or throw). The package keeps its place and offers the same workout next sync. Nothing is lost.

### 8.4 The same workout arrives twice

Expected and harmless: answer `ImportDecision.duplicate` (see [the one rule](#the-one-rule-make-workoutid-unique-on-your-side)).

> Different apps recording the **same** session (e.g. Garmin *and* Strava both writing your run) are two different workouts with two ids. If that matters for you, also dedupe on overlapping start/end times on your server.

### 8.5 The user turns access off later

Android lets users revoke access in system settings. Check and offer a fix:

```dart
final HealthSyncStatus status = await HealthWorkoutSync.instance.status();
if (status.connected && !status.readAuthorized) {
  // Show: "Workout access is off" + a Fix button:
  final bool ok = await HealthWorkoutSync.instance.requestAccess();
  if (!ok) await HealthWorkoutSync.instance.openHealthSettings();
}
```

`requestAccess()` keeps the sync position, so workouts recorded while access was off still import afterwards.

### 8.6 Sign-out, sign-in, switching accounts

```dart
// Sign-out
HealthWorkoutSync.instance.attachImporter(null);
await HealthWorkoutSync.instance.disconnect(); // recommended if another person may sign in

// Sign-in
HealthWorkoutSync.instance.attachImporter(MyWorkoutImporter());
// if they had disconnected: show your Connect button again (connect())
```

Your `backgroundImporter()` must return `null` while nobody is signed in — then background syncs skip without losing their place.

### 8.7 Notify the user from a background sync

Override `syncCompleted` in your importer. It runs after every sync, including background ones:

```dart
@override
Future<void> syncCompleted(SyncReport report) async {
  final bool background = report.trigger == SyncTrigger.healthKitObserver ||
      report.trigger == SyncTrigger.periodic;
  if (background && report.imported > 0) {
    await HealthWorkoutSync.instance.notify(
      id: 'workouts-imported',       // same id replaces the previous one
      title: 'Workout synced',
      body: '${report.imported} new workout(s) imported.',
    );
  }
}
```

Ask for permission once, from your UI (e.g. right after connecting): `await HealthWorkoutSync.instance.requestNotificationPermission();`. If you already use another notifications package, you can use it instead of `notify()`.

### 8.8 Uninstall and reinstall

Uninstalling removes the app's health permission and the package's saved position. After reinstalling, the user taps Connect again and import restarts **from the start of that day**. Workouts from today that you already have come back as `duplicate` (your unique id). Nothing is doubled.

> **Android Auto Backup** may restore the package's saved state on reinstall. The package then shows `status.readAuthorized == false` (access is gone) — handle it as in [8.5](#85-the-user-turns-access-off-later), or make every reinstall start fresh like iOS:

<details>
<summary>Exclude the sync state from Android backup</summary>

The package stores its state in `files/datastore/FlutterSharedPreferences.preferences_pb` (the `shared_preferences` async store). Excluding that file also excludes any values **your** app saves with `SharedPreferencesAsync` / `SharedPreferencesWithCache` — check that's fine for you.

`android/app/src/main/res/xml/data_extraction_rules.xml` (Android 12+):

```xml
<?xml version="1.0" encoding="utf-8"?>
<data-extraction-rules>
    <cloud-backup>
        <exclude domain="file" path="datastore/FlutterSharedPreferences.preferences_pb" />
    </cloud-backup>
    <device-transfer>
        <exclude domain="file" path="datastore/FlutterSharedPreferences.preferences_pb" />
    </device-transfer>
</data-extraction-rules>
```

`android/app/src/main/res/xml/backup_rules.xml` (Android 11 and lower):

```xml
<?xml version="1.0" encoding="utf-8"?>
<full-backup-content>
    <exclude domain="file" path="datastore/FlutterSharedPreferences.preferences_pb" />
</full-backup-content>
```

Then on `<application>` in `AndroidManifest.xml`:

```xml
<application
    android:dataExtractionRules="@xml/data_extraction_rules"
    android:fullBackupContent="@xml/backup_rules"
    ...>
```

</details>

**New phone:** same as a reinstall — import starts from the connect day; your server rejects anything it already has.

### 8.9 Health Connect isn't installed (Android 9–13)

```dart
switch (await HealthWorkoutSync.instance.availability()) {
  case HealthAvailability.available:    // show Connect
  case HealthAvailability.needsInstall: // show "Install Health Connect" → installHealthConnect()
  case HealthAvailability.unsupported:  // hide the feature
}
```

On Android 14+, Health Connect is built in.

### 8.10 Disconnect

```dart
await HealthWorkoutSync.instance.disconnect();
```

Stops syncing (foreground and background). Already-imported workouts stay in your database. Only the user can revoke the system permission — offer `openHealthSettings()`.

### 8.11 Your app already uses `workmanager`

`workmanager` allows one dispatcher per app. If you have your own, don't let the package register its own — route its task from yours:

```dart
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, input) async {
    if (task == HealthWorkoutSync.periodicTaskName) {
      return HealthWorkoutSync.handleWorkmanagerTask(task);
    }
    // … your own tasks
    return true;
  });
}
```

### 8.12 Showing workouts the user already has

The package only delivers workouts to your importer; show them from your own database. To peek at the health store directly (e.g. a debug screen): `HealthWorkoutSync.instance.recentWorkouts(const Duration(days: 7))`.

---

## 9. Third-party apps: help users turn sharing on

**This is the #1 reason "my workouts don't show up".** Garmin, Samsung Health, Oura, Strava etc. only write workouts to Apple Health / Health Connect after the user **turns sharing on inside that app**. Connecting *your* app is only half of it. Always tell your users.

### 9.1 The ready-made reminder card

Show it right after a successful connect, and on your health settings screen:

```dart
const HealthSharingReminder()
```

It says *"Workouts from other apps and devices (like Garmin, Oura, Strava or your smartwatch) only reach this app when that app shares them with Health Connect / Apple Health"* and has an **Open Health Connect settings / Open Health** button. Change any text:

```dart
HealthSharingReminder(
  title: 'Sync your watch',
  message: 'Turn on Health Connect sharing in your watch app.',
  buttonLabel: 'Check settings',
)
```

Or build your own button:

```dart
// Android: Health Connect's main screen, listing every app's sharing.
// iOS: opens the Health app.
await HealthWorkoutSync.instance.openHealthSettings(
  page: HealthSettingsPage.allApps,
);
```

### 9.2 "Your fitness apps" list

```dart
final List<FitnessAppStatus> apps = await HealthWorkoutSync.instance.fitnessApps();

for (final app in apps) {
  app.name;              // "Samsung Health"
  app.sharing;           // true = shared a workout in the last 30 days
  app.lastWorkoutAt;     // when
  app.installedPackage;  // Android: installed → you can open it
  app.guide;             // step-by-step instructions (or null)
}
```

It lists apps that shared workouts recently, then (Android) known apps that are **installed but not sharing yet** — exactly the ones to nudge.

### 9.3 Step-by-step guides

```dart
final FitnessAppGuide? garmin = FitnessAppGuide.byId('garmin');
final bool android = Platform.isAndroid;

garmin!.support(android: android); // ShareSupport.yes / partial / no
garmin.steps(android: android);    // ["Open Garmin Connect and go to Settings.", …]
garmin.limitation;                 // caveat to show, or null
garmin.bridge;                     // what to do when it can't share, or null

// Android: open the app so they can do it now
if (app.installedPackage != null) {
  await HealthWorkoutSync.instance.launchPackage(app.installedPackage!);
}
```

Included: Samsung Health, Garmin Connect, Oura, WHOOP, Google Health (Fitbit), Strava, Polar Flow, COROS, Suunto, Zepp (Amazfit), Huawei Health, Mi Fitness, Withings, Peloton, Hevy, Strong, Nike Run Club / Training Club, MyFitnessPal. `FitnessAppGuide.all` has the list. Menus change — treat steps as guidance.

A full "Your fitness apps" screen with guide sheets is in the [example](example/lib/main.dart).

> **Samsung Health:** Samsung Health → ⋮ → Settings → Health Connect → allow Exercise. Galaxy Watch workouts arrive after the watch syncs to the phone, and Samsung writes to Health Connect in batches — it can take a while.

---

## 10. Testing

### iPhone / iOS Simulator

1. Run your app, tap Connect, allow.
2. Open the **Health** app → Browse → Activity → Workouts → **Add Data** (or record a workout on an Apple Watch).
3. Come back to your app (foreground sync) — or leave it closed to test the background wake.

Real devices are the reference for background behaviour. HealthKit data is unreadable while the phone is **locked**; a sync then fails quietly and retries next time.

### Android emulator / phone

1. Install **Health Connect Toolbox** (Google's developer tool) or any fitness app (Fitbit, Samsung Health…).
2. Write an Exercise session in it.
3. Open your app (foreground sync) or wait for the background job.

Speed up the background job while testing:

```dart
await HealthWorkoutSync.instance.setBackgroundInterval(HealthWorkoutSync.minInterval);
```

### Workouts written by your own app

Workouts your app writes itself are skipped (so an app that also *writes* workouts never re-imports them). To test with your own sample writes: `await HealthWorkoutSync.instance.setIncludeOwnWrites(true);` — turn it off again for release.

---

## 11. Troubleshooting

| Problem | Fix |
|---|---|
| iOS crash when tapping Connect | Add `NSHealthShareUsageDescription` to Info.plist ([2.2](#22-explain-why-you-need-health-data)) |
| iOS: connected but no workouts | Settings → Health → Data Access & Devices → your app → turn on Workouts. Check the HealthKit capability ([2.1](#21-turn-on-healthkit-in-xcode)) |
| iOS: nothing arrives while the app is closed | AppDelegate lines ([2.4](#24-appdelegate-for-background-syncs)); Background Delivery ticked; test on a real device |
| Android: permission screen never appears | Add the privacy-policy `<meta-data>` ([3.2](#32-your-privacy-policy-link)). Android 9–13: is Health Connect installed? ([8.9](#89-health-connect-isnt-installed-android-913)) |
| Android: `connect()` returns `unavailable` | Health Connect missing or outdated → `installHealthConnect()` |
| Android: background sync never runs | User allowed "access in the background"? (`status().backgroundAuthorized`). Battery saver / Doze delays jobs; no internet = no run |
| Workouts from Garmin/Samsung/… don't show | That app isn't sharing with the health store ([section 9](#9-third-party-apps-help-users-turn-sharing-on)) |
| "Only today's workouts imported" | By design: import starts at the connect day |
| `ArgumentError: backgroundImporter must be a top-level…` | Move the function out of any class and add `@pragma('vm:entry-point')` |
| `report.skippedReason == 'no_importer'` | Call `attachImporter(...)` after sign-in |
| `report.skippedReason == 'busy'` | Another sync (often the background one) is running — try again shortly |

Logs are printed with the `[HealthWorkoutSync]` prefix.

---

## 12. API reference

All methods are on `HealthWorkoutSync.instance`.

| Method | What it does |
|---|---|
| `initialize(backgroundImporter:)` | Call once in `main()` |
| `attachImporter(importer?)` | Importer for foreground syncs (null when signed out) |
| `availability()` | `available` / `needsInstall` / `unsupported` |
| `installHealthConnect()` | Android: open Google Play on Health Connect |
| `connect()` | Permission sheet → `connected` / `denied` / `unavailable` |
| `requestAccess()` | Ask again after access was turned off (keeps progress) |
| `disconnect()` | Stop syncing |
| `isConnected()` / `status()` | Connection state, last sync, permissions, interval |
| `sync()` | Run a sync now → `SyncReport` |
| `setBackgroundInterval(d)` / `backgroundInterval()` | Android background frequency (default 1 h, min 15 min) |
| `openHealthSettings(page:)` | `thisApp` (default) or `allApps` |
| `fitnessApps()` | Which fitness apps share / are installed |
| `launchPackage(pkg)` | Android: open another app |
| `requestNotificationPermission()` / `notificationsEnabled()` | Notification permission |
| `notify(id:, title:, body:)` | Show a local notification (works in background) |
| `recentWorkouts(window)` | Read the health store directly (no import) |
| `setIncludeOwnWrites(bool)` | Testing aid |

`SyncReport`: `imported`, `fetched`, `retrying`, `deleted`, `abandoned`, `trigger`, `ran`, `skippedReason`.

---

## 13. How it works

```
 trigger: app opened · iOS HealthKit wake · Android WorkManager job
                              │
                              ▼
   1. lock (one sync at a time, across foreground + background)
   2. ask the store "what changed since my bookmark?"
        iOS: HKAnchoredObjectQuery anchor · Android: changes token
   3. hand each new workout to your importer
   4. move the bookmark ONLY if every workout was settled
        (imported / duplicate / skipped); a retry holds it
   5. every 6 h: re-check the last 3 days as a safety net
   6. call your importer's syncCompleted(report)
```

- **Dependencies:** `shared_preferences` (the bookmark, shared with background isolates), `workmanager` (Android scheduling). Native: Apple HealthKit, Google's `androidx.health.connect:connect-client`.
- **Data stays on the device** until your importer sends it somewhere. The package has no server and no analytics.

## License

MIT — see [LICENSE](LICENSE).
