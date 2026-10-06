import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../health_workout_sync.dart';
import '../models.dart';

/// A ready-made card reminding the user that workouts recorded by *other*
/// apps (Samsung Health, Garmin, Oura, Strava, a smartwatch app…) only reach
/// your app when that app shares them with Health Connect / Apple Health —
/// with a button that opens the health settings so they can check.
///
/// Show it right after [HealthWorkoutSync.connect] succeeds, and on your
/// "health settings" screen. It uses the ambient [Theme]; pass your own
/// texts to match your app's voice.
///
/// ```dart
/// const HealthSharingReminder()
/// ```
class HealthSharingReminder extends StatelessWidget {
  const HealthSharingReminder({
    super.key,
    this.title,
    this.message,
    this.buttonLabel,
    this.onOpenSettings,
    this.padding = const EdgeInsets.all(16),
  });

  /// Default: "Make sure your workouts sync".
  final String? title;

  /// Default: a platform-specific explanation naming Health Connect or
  /// Apple Health.
  final String? message;

  /// Default: "Open Health Connect settings" / "Open Health".
  final String? buttonLabel;

  /// Default: [HealthWorkoutSync.openHealthSettings] with
  /// [HealthSettingsPage.allApps].
  final VoidCallback? onOpenSettings;

  final EdgeInsetsGeometry padding;

  static bool get _android => Platform.isAndroid;

  static String get _store => _android ? 'Health Connect' : 'Apple Health';

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              title ?? 'Make sure your workouts sync',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              message ??
                  'Workouts from other apps and devices (like Garmin, Oura, '
                      'Strava or your smartwatch) only reach this app when '
                      'that app shares them with $_store. Open settings to '
                      'check sharing is turned on.',
              style: theme.textTheme.bodyMedium,
            ),
            if (!_android && message == null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                'Settings → Health → Data Access & Devices',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed:
                  onOpenSettings ??
                  () => HealthWorkoutSync.instance.openHealthSettings(
                    page: HealthSettingsPage.allApps,
                  ),
              child: Text(
                buttonLabel ??
                    (_android ? 'Open Health Connect settings' : 'Open Health'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
