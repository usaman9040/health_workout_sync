import Flutter
import UIKit
import health_workout_sync

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // health_workout_sync: when HealthKit wakes the app in the background,
    // the sync runs in a separate Flutter engine that needs your plugins.
    HealthWorkoutSyncPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    // Re-arm HealthKit's background observer. Must run on EVERY launch
    // (background launches too) or background delivery stops.
    HealthWorkoutSyncPlugin.startBackgroundDelivery()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
