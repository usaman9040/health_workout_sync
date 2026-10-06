# Changelog

All notable changes to this package are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the package uses
[Semantic Versioning](https://semver.org/) (see [RELEASING.md](RELEASING.md)).

## 0.1.0

First public release.

* Workout sync from Apple Health (HealthKit anchored queries) and Health
  Connect (changes tokens). The sync position only advances once every
  workout is settled by your `WorkoutImporter`, so failures never lose a
  workout; a recent-window safety sweep catches anything missed.
* Background sync: HealthKit background delivery into a headless Flutter
  engine on iOS; a WorkManager periodic job on Android with a user-settable
  interval (default 1 hour, minimum 15 minutes).
* Cross-isolate lock so foreground and background syncs never overlap.
* `availability()` / `installHealthConnect()` for Android 9–13, where Health
  Connect is a Play Store app.
* `requestNotificationPermission()`, `notificationsEnabled()` and `notify()`
  for local notifications from background syncs.
* Third-party app guidance: `FitnessAppGuide` (18 apps, Health Connect and
  Apple Health steps), `fitnessApps()` (which apps share / are installed) and
  the ready-made `HealthSharingReminder` card.
* `openHealthSettings(page:)` — this app's permissions or every app's sharing.
* Android: Health Connect's required privacy-policy screen, permissions and
  package-visibility queries are merged into the host app; the host only adds
  a `health_workout_sync.privacy_policy_url` meta-data entry.
