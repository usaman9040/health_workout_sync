# health_workout_sync example

A complete app using `health_workout_sync`. It stores imported workouts on
the device (no backend needed) and shows:

* Connect / Install Health Connect / access-off recovery
* Sync on app open, pull to refresh, background sync with a frequency picker
* The `HealthSharingReminder` card and a "Your fitness apps" list with
  per-app guides
* A notification when a background sync imports something

```bash
cd example
flutter run
```

iOS: open `ios/Runner.xcworkspace`, pick your team under Signing &
Capabilities (HealthKit needs a signed build on a device). Android: add a
workout in Health Connect Toolbox, Fitbit or Samsung Health, then reopen the
app.

Native setup to copy into your own app: `ios/Runner/AppDelegate.swift`,
`ios/Runner/Info.plist`, `ios/Runner/Runner.entitlements`,
`android/app/src/main/AndroidManifest.xml` (the `privacy_policy_url`
meta-data) and `android/app/build.gradle.kts` (`minSdk = 26`).
