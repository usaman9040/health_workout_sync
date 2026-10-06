import Flutter
import HealthKit
import UIKit
import UserNotifications

/// iOS side of health_workout_sync: HealthKit workouts.
///
/// Reads are anchored queries (new + deleted samples since a cursor the Dart
/// side persists). Background delivery is an `HKObserverQuery` with
/// `enableBackgroundDelivery(.immediate)`: when HealthKit wakes the app for a
/// new workout, the sync runs in the main Flutter engine if one is alive,
/// otherwise in a headless engine started from a Dart callback handle.
///
/// Host app setup (AppDelegate):
///
///     HealthWorkoutSyncPlugin.setPluginRegistrantCallback { registry in
///       GeneratedPluginRegistrant.register(with: registry)
///     }
///     HealthWorkoutSyncPlugin.startBackgroundDelivery() // in didFinishLaunching
///
/// Channel contract (shared with Android):
///  isAvailable                         → Bool
///  requestAuthorization {background}   → {granted, backgroundGranted}
///  hasAuthorization                    → Bool (the permission sheet was answered)
///  isBackgroundAuthorized              → Bool
///  initialCursor                       → nil (a nil anchor means "from the start")
///  changes {cursor, since}             → {workouts, deleted, cursor, expired}
///  readWindow {start, end}             → [workout]
///  openHealthSettings                  → Bool
///  setBackgroundDelivery {enabled, dispatcherHandle}
///  backgroundDeliveryState             → String?
///  notify {id, title, body}            → "posted" | "not_authorized" | "failed"
public final class HealthWorkoutSyncPlugin: NSObject, FlutterPlugin {
  static let store = HKHealthStore()

  private static let workoutType = HKObjectType.workoutType()

  /// What the permission sheet lists. Only workouts are ever queried; the
  /// quantity types are requested so the sheet matches the app's "what we
  /// read" copy (steps / active energy / exercise minutes).
  private static var readTypes: Set<HKObjectType> {
    var types: Set<HKObjectType> = [workoutType]
    for id in [
      HKQuantityTypeIdentifier.stepCount,
      .activeEnergyBurned,
      .appleExerciseTime,
    ] {
      if let type = HKObjectType.quantityType(forIdentifier: id) { types.insert(type) }
    }
    return types
  }

  // MARK: Persistent keys (UserDefaults — survives relaunch, read at launch)

  private enum Key {
    static let backgroundEnabled = "health_workout_sync.native.backgroundEnabled"
    static let dispatcherHandle = "health_workout_sync.native.dispatcherHandle"
    static let deliveryState = "health_workout_sync.native.backgroundDeliveryState"
    static let lastWakeAt = "health_workout_sync.native.lastObserverWakeAt"
  }

  // MARK: Process-wide state

  private static var registrantCallback: ((FlutterPluginRegistry) -> Void)?
  private static var mainChannel: FlutterMethodChannel?
  private static var registeringHeadless = false
  private static var observer: HKObserverQuery?
  private static var headless: HeadlessRunner?
  private static var syncInFlight = false
  private static var rerunRequested = false

  // MARK: Host app API

  /// Registers plugins into the headless background engine. Without it only
  /// this plugin is available there, and the Dart background setup (Supabase,
  /// shared_preferences, …) can't run.
  public static func setPluginRegistrantCallback(
    _ callback: @escaping (FlutterPluginRegistry) -> Void
  ) {
    registrantCallback = callback
  }

  /// Re-arms background delivery. Call from
  /// `application(_:didFinishLaunchingWithOptions:)` on EVERY launch —
  /// including background launches — as Apple requires. No-op until the
  /// Dart side has enabled it.
  public static func startBackgroundDelivery() {
    guard HKHealthStore.isHealthDataAvailable(),
          UserDefaults.standard.bool(forKey: Key.backgroundEnabled)
    else { return }
    enableDelivery()
  }

  // MARK: FlutterPlugin

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "health_workout_sync",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(HealthWorkoutSyncPlugin(), channel: channel)
    // The headless engine registers this plugin too; only the app's own
    // engine becomes the "main" channel background wakes are routed to.
    if !registeringHeadless { mainChannel = channel }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "isAvailable":
      result(HKHealthStore.isHealthDataAvailable())
    case "availability":
      result(HKHealthStore.isHealthDataAvailable() ? "available" : "unsupported")
    case "installHealthConnect":
      result(false)
    case "requestAuthorization":
      requestAuthorization(result)
    case "hasAuthorization":
      hasAuthorization(result)
    case "isBackgroundAuthorized":
      result(true) // entitlement-driven on iOS; nothing for the user to grant
    case "initialCursor":
      result(nil)
    case "changes":
      changes(
        cursor: args["cursor"] as? String,
        since: Self.date(args["since"]),
        includeSelf: args["includeSelf"] as? Bool ?? false,
        result: result
      )
    case "readWindow":
      readWindow(
        start: Self.date(args["start"]),
        end: Self.date(args["end"]),
        includeSelf: args["includeSelf"] as? Bool ?? false,
        result: result
      )
    case "openHealthSettings":
      openHealthSettings(result)
    case "notificationsEnabled":
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        let ok = settings.authorizationStatus == .authorized
          || settings.authorizationStatus == .provisional
        DispatchQueue.main.async { result(ok) }
      }
    case "requestNotificationPermission":
      UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound, .badge]
      ) { granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "installedPackages":
      // iOS doesn't expose other installed apps; callers fall back to which
      // apps have actually written workouts.
      result([String]())
    case "launchPackage":
      result(false)
    case "setBackgroundDelivery":
      setBackgroundDelivery(
        enabled: args["enabled"] as? Bool ?? false,
        dispatcherHandle: (args["dispatcherHandle"] as? NSNumber)?.int64Value,
        result: result
      )
    case "notify":
      postNotification(
        id: args["id"] as? String ?? "health_workout_sync",
        title: args["title"] as? String ?? "",
        body: args["body"] as? String ?? "",
        result: result
      )
    case "backgroundDeliveryState":
      let defaults = UserDefaults.standard
      var state: [String: Any] = [
        "enabled": defaults.bool(forKey: Key.backgroundEnabled),
        "observing": Self.observer != nil,
      ]
      state["delivery"] = defaults.string(forKey: Key.deliveryState)
      if let wake = defaults.object(forKey: Key.lastWakeAt) as? Date {
        state["lastWakeAt"] = Int64(wake.timeIntervalSince1970 * 1000)
      }
      result(state)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Authorization

  private func requestAuthorization(_ result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      result(FlutterError(code: "unavailable", message: "Health data unavailable", details: nil))
      return
    }
    Self.store.requestAuthorization(toShare: [], read: Self.readTypes) { success, error in
      DispatchQueue.main.async {
        if let error {
          result(FlutterError(code: "healthkit", message: error.localizedDescription, details: nil))
        } else {
          // `success` only means the sheet was handled; HealthKit never says
          // whether READ access was granted.
          result(["granted": success, "backgroundGranted": success])
        }
      }
    }
  }

  private func hasAuthorization(_ result: @escaping FlutterResult) {
    guard HKHealthStore.isHealthDataAvailable() else {
      result(false)
      return
    }
    Self.store.getRequestStatusForAuthorization(toShare: [], read: Self.readTypes) { status, _ in
      DispatchQueue.main.async { result(status == .unnecessary) }
    }
  }

  // MARK: Reads

  private func changes(
    cursor: String?, since: Date, includeSelf: Bool, result: @escaping FlutterResult
  ) {
    var anchor: HKQueryAnchor?
    if let cursor, let data = Data(base64Encoded: cursor) {
      anchor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
    let predicate = HKQuery.predicateForSamples(withStart: since, end: nil, options: [])
    let query = HKAnchoredObjectQuery(
      type: Self.workoutType,
      predicate: predicate,
      anchor: anchor,
      limit: HKObjectQueryNoLimit
    ) { _, samples, deleted, newAnchor, error in
      if let error {
        DispatchQueue.main.async {
          result(FlutterError(code: "healthkit", message: error.localizedDescription, details: nil))
        }
        return
      }
      var nextCursor: String?
      if let newAnchor,
         let data = try? NSKeyedArchiver.archivedData(
           withRootObject: newAnchor, requiringSecureCoding: true)
      {
        nextCursor = data.base64EncodedString()
      }
      var payload: [String: Any] = [
        "workouts": Self.workouts(samples, includeSelf: includeSelf),
        "deleted": (deleted ?? []).map { $0.uuid.uuidString },
        "expired": false,
      ]
      if let next = nextCursor ?? cursor { payload["cursor"] = next }
      DispatchQueue.main.async { result(payload) }
    }
    Self.store.execute(query)
  }

  private func readWindow(
    start: Date, end: Date, includeSelf: Bool, result: @escaping FlutterResult
  ) {
    let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
    let query = HKSampleQuery(
      sampleType: Self.workoutType,
      predicate: predicate,
      limit: HKObjectQueryNoLimit,
      sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
    ) { _, samples, error in
      DispatchQueue.main.async {
        if let error {
          result(FlutterError(code: "healthkit", message: error.localizedDescription, details: nil))
        } else {
          result(Self.workouts(samples, includeSelf: includeSelf))
        }
      }
    }
    Self.store.execute(query)
  }

  /// Workouts as channel maps. This app's own writes are skipped unless
  /// [includeSelf] (a testing aid) so they're never imported back.
  private static func workouts(_ samples: [HKSample]?, includeSelf: Bool) -> [[String: Any]] {
    let own = Bundle.main.bundleIdentifier
    return (samples ?? []).compactMap { sample in
      guard let workout = sample as? HKWorkout else { return nil }
      if !includeSelf, workout.sourceRevision.source.bundleIdentifier == own { return nil }
      return map(workout)
    }
  }

  private static func map(_ workout: HKWorkout) -> [String: Any] {
    [
      "id": workout.uuid.uuidString,
      "start": Int64(workout.startDate.timeIntervalSince1970 * 1000),
      "end": Int64(workout.endDate.timeIntervalSince1970 * 1000),
      "durationSeconds": workout.duration,
      "activityType": activityName(workout.workoutActivityType),
      "sourceAppId": workout.sourceRevision.source.bundleIdentifier,
      "sourceName": workout.sourceRevision.source.name,
      "userEntered": (workout.metadata?[HKMetadataKeyWasUserEntered] as? Bool) ?? false,
    ]
  }

  private func openHealthSettings(_ result: @escaping FlutterResult) {
    // iOS has no deep link to one app's Health permissions; the Health app
    // (Sharing → Apps) is the closest, else this app's Settings page.
    // open(_:) rather than canOpenURL: the latter needs the scheme whitelisted
    // in the host's LSApplicationQueriesSchemes.
    let settings = URL(string: UIApplication.openSettingsURLString)
    guard let health = URL(string: "x-apple-health://") else {
      result(false)
      return
    }
    UIApplication.shared.open(health) { opened in
      if opened {
        result(true)
      } else if let settings {
        UIApplication.shared.open(settings) { result($0) }
      } else {
        result(false)
      }
    }
  }

  // MARK: Local notifications

  /// Posts an immediate local notification. Works from the headless engine
  /// (background wake), which is the point: the sync that imports a workout
  /// is the only thing that knows to tell the user. A fixed [id] replaces a
  /// pending banner instead of stacking duplicates.
  private func postNotification(
    id: String, title: String, body: String, result: @escaping FlutterResult
  ) {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .authorized
        || settings.authorizationStatus == .provisional
      else {
        DispatchQueue.main.async { result("not_authorized") }
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
      center.add(request) { error in
        DispatchQueue.main.async { result(error == nil ? "posted" : "failed") }
      }
    }
  }

  // MARK: Background delivery

  private func setBackgroundDelivery(
    enabled: Bool,
    dispatcherHandle: Int64?,
    result: @escaping FlutterResult
  ) {
    let defaults = UserDefaults.standard
    if let dispatcherHandle { defaults.set(dispatcherHandle, forKey: Key.dispatcherHandle) }
    defaults.set(enabled, forKey: Key.backgroundEnabled)
    if enabled {
      Self.enableDelivery()
    } else {
      if let observer = Self.observer {
        Self.store.stop(observer)
        Self.observer = nil
      }
      Self.store.disableBackgroundDelivery(for: Self.workoutType) { _, _ in }
      defaults.set("disabled", forKey: Key.deliveryState)
    }
    result(nil)
  }

  private static func enableDelivery() {
    // Re-assert on every call: `disableBackgroundDelivery` is persisted by
    // healthd across launches, so after a disconnect → reconnect the
    // subscription would otherwise stay off while the observer looks fine.
    store.enableBackgroundDelivery(for: workoutType, frequency: .immediate) { success, error in
      let state = error.map { "failed: \($0.localizedDescription)" }
        ?? (success ? "enabled" : "refused")
      UserDefaults.standard.set(state, forKey: Key.deliveryState)
    }

    guard observer == nil else { return }
    let query = HKObserverQuery(sampleType: workoutType, predicate: nil) { _, completion, error in
      if error != nil {
        completion()
        return
      }
      DispatchQueue.main.async { handleWake(completion) }
    }
    store.execute(query)
    observer = query
  }

  /// HealthKit reported new/changed workouts. Every path below calls
  /// [completion] exactly once and promptly — an app that keeps HealthKit
  /// waiting has its background delivery throttled and eventually stopped.
  private static func handleWake(_ completion: @escaping HKObserverQueryCompletionHandler) {
    let state = UIApplication.shared.applicationState
    if state == .background {
      UserDefaults.standard.set(Date(), forKey: Key.lastWakeAt)
    }

    var reported = false
    let report = {
      guard !reported else { return }
      reported = true
      completion()
    }

    if syncInFlight {
      // The running pass may have queried before this sample landed — ask
      // for one more pass when it finishes instead of stacking engines.
      rerunRequested = true
      report()
      return
    }

    var task: UIBackgroundTaskIdentifier = .invalid
    let finish = {
      report()
      if task != .invalid {
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
      }
    }
    task = UIApplication.shared.beginBackgroundTask(withName: "HealthWorkoutSync") { finish() }
    // Report back to HealthKit after 15s regardless; the sync keeps going
    // under the task assertion.
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { report() }

    syncInFlight = true
    run(appState: state) {
      syncInFlight = false
      if rerunRequested {
        rerunRequested = false
        run(appState: UIApplication.shared.applicationState) { finish() }
      } else {
        finish()
      }
    }
  }

  /// Main engine if one is alive (it handles `runSync` once its Dart side is
  /// up), else a headless engine — but only for true background launches: at
  /// a foreground launch the observer's initial fire races the app's own
  /// startup sync, so it's dropped.
  private static func run(appState: UIApplication.State, done: @escaping () -> Void) {
    let args: [String: Any] = ["trigger": "healthKitObserver"]
    if let main = mainChannel {
      main.invokeMethod("runSync", arguments: args) { response in
        let unhandled = (response as? NSObject) === FlutterMethodNotImplemented
          || response is FlutterError
        if unhandled, appState == .background {
          runHeadless(args, done: done)
        } else {
          done()
        }
      }
      return
    }
    guard appState == .background else {
      done()
      return
    }
    runHeadless(args, done: done)
  }

  private static func runHeadless(_ args: [String: Any], done: @escaping () -> Void) {
    if headless == nil {
      let handle = (UserDefaults.standard.object(forKey: Key.dispatcherHandle) as? NSNumber)?.int64Value
      headless = handle.flatMap { HeadlessRunner(handle: $0) }
    }
    guard let runner = headless else {
      done()
      return
    }
    runner.runSync(args, done: done)
  }

  // MARK: Headless engine

  private final class HeadlessRunner {
    private let engine: FlutterEngine
    private let channel: FlutterMethodChannel
    private var ready = false
    private var pending: [(args: [String: Any], done: () -> Void)] = []

    init?(handle: Int64) {
      guard let info = FlutterCallbackCache.lookupCallbackInformation(handle) else { return nil }
      let engine = FlutterEngine(
        name: "health_workout_sync.background",
        project: nil,
        allowHeadlessExecution: true
      )
      guard engine.run(withEntrypoint: info.callbackName, libraryURI: info.callbackLibraryPath)
      else { return nil }

      registeringHeadless = true
      if let registrant = registrantCallback {
        registrant(engine)
      } else if let registrar = engine.registrar(forPlugin: "HealthWorkoutSyncPlugin") {
        HealthWorkoutSyncPlugin.register(with: registrar)
      }
      registeringHeadless = false

      self.engine = engine
      channel = FlutterMethodChannel(
        name: "health_workout_sync/background",
        binaryMessenger: engine.binaryMessenger
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self, call.method == "backgroundReady" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self.ready = true
        result(nil)
        let queued = self.pending
        self.pending.removeAll()
        for item in queued { self.invoke(item.args, done: item.done) }
      }
    }

    func runSync(_ args: [String: Any], done: @escaping () -> Void) {
      if ready {
        invoke(args, done: done)
      } else {
        pending.append((args, done))
      }
    }

    private func invoke(_ args: [String: Any], done: @escaping () -> Void) {
      channel.invokeMethod("runSync", arguments: args) { _ in done() }
    }
  }

  // MARK: Helpers

  private static func date(_ value: Any?) -> Date {
    let ms = (value as? NSNumber)?.doubleValue ?? 0
    return Date(timeIntervalSince1970: ms / 1000)
  }

  /// Stable case names (matches the Swift `HKWorkoutActivityType` cases).
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  static func activityName(_ type: HKWorkoutActivityType) -> String {
    switch type {
    case .americanFootball: return "americanFootball"
    case .archery: return "archery"
    case .australianFootball: return "australianFootball"
    case .badminton: return "badminton"
    case .baseball: return "baseball"
    case .basketball: return "basketball"
    case .bowling: return "bowling"
    case .boxing: return "boxing"
    case .climbing: return "climbing"
    case .cricket: return "cricket"
    case .crossTraining: return "crossTraining"
    case .curling: return "curling"
    case .cycling: return "cycling"
    case .dance: return "dance"
    case .danceInspiredTraining: return "danceInspiredTraining"
    case .elliptical: return "elliptical"
    case .equestrianSports: return "equestrianSports"
    case .fencing: return "fencing"
    case .fishing: return "fishing"
    case .functionalStrengthTraining: return "functionalStrengthTraining"
    case .golf: return "golf"
    case .gymnastics: return "gymnastics"
    case .handball: return "handball"
    case .hiking: return "hiking"
    case .hockey: return "hockey"
    case .hunting: return "hunting"
    case .lacrosse: return "lacrosse"
    case .martialArts: return "martialArts"
    case .mindAndBody: return "mindAndBody"
    case .mixedMetabolicCardioTraining: return "mixedMetabolicCardioTraining"
    case .paddleSports: return "paddleSports"
    case .play: return "play"
    case .preparationAndRecovery: return "preparationAndRecovery"
    case .racquetball: return "racquetball"
    case .rowing: return "rowing"
    case .rugby: return "rugby"
    case .running: return "running"
    case .sailing: return "sailing"
    case .skatingSports: return "skatingSports"
    case .snowSports: return "snowSports"
    case .soccer: return "soccer"
    case .softball: return "softball"
    case .squash: return "squash"
    case .stairClimbing: return "stairClimbing"
    case .surfingSports: return "surfingSports"
    case .swimming: return "swimming"
    case .tableTennis: return "tableTennis"
    case .tennis: return "tennis"
    case .trackAndField: return "trackAndField"
    case .traditionalStrengthTraining: return "traditionalStrengthTraining"
    case .volleyball: return "volleyball"
    case .walking: return "walking"
    case .waterFitness: return "waterFitness"
    case .waterPolo: return "waterPolo"
    case .waterSports: return "waterSports"
    case .wrestling: return "wrestling"
    case .yoga: return "yoga"
    case .barre: return "barre"
    case .coreTraining: return "coreTraining"
    case .crossCountrySkiing: return "crossCountrySkiing"
    case .downhillSkiing: return "downhillSkiing"
    case .flexibility: return "flexibility"
    case .highIntensityIntervalTraining: return "highIntensityIntervalTraining"
    case .jumpRope: return "jumpRope"
    case .kickboxing: return "kickboxing"
    case .pilates: return "pilates"
    case .snowboarding: return "snowboarding"
    case .stairs: return "stairs"
    case .stepTraining: return "stepTraining"
    case .wheelchairWalkPace: return "wheelchairWalkPace"
    case .wheelchairRunPace: return "wheelchairRunPace"
    case .taiChi: return "taiChi"
    case .mixedCardio: return "mixedCardio"
    case .handCycling: return "handCycling"
    case .discSports: return "discSports"
    case .fitnessGaming: return "fitnessGaming"
    case .cardioDance: return "cardioDance"
    case .socialDance: return "socialDance"
    case .pickleball: return "pickleball"
    case .cooldown: return "cooldown"
    case .swimBikeRun: return "swimBikeRun"
    case .transition: return "transition"
    case .other: return "other"
    default:
      if #available(iOS 17.0, *), type == .underwaterDiving { return "underwaterDiving" }
      return "other"
    }
  }
}
