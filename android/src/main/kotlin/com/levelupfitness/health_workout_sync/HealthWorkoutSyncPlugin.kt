package com.levelupfitness.health_workout_sync

import android.app.Activity
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.HealthConnectFeatures
import androidx.health.connect.client.PermissionController
import androidx.health.connect.client.changes.DeletionChange
import androidx.health.connect.client.changes.UpsertionChange
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ChangesTokenRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.time.Instant
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Android side of health_workout_sync: Health Connect exercise sessions.
 *
 * Works from any FlutterActivity (no FragmentActivity needed — the permission
 * contract is driven through startActivityForResult) and from headless
 * engines (WorkManager), where only the read methods are used.
 *
 * Channel contract (shared with iOS):
 *  isAvailable                         → Bool
 *  requestAuthorization {background}   → {granted, backgroundGranted}
 *  hasAuthorization                    → Bool
 *  isBackgroundAuthorized              → Bool
 *  initialCursor                       → String (changes token)
 *  changes {cursor, since}             → {workouts, deleted, cursor, expired}
 *  readWindow {start, end}             → [workout]
 *  openHealthSettings                  → Bool
 *  installedPackages {packages}        → [String] (needs host <queries>)
 *  launchPackage {package}             → Bool
 *  notify {id, title, body, channelId, channelName}
 *                                      → "posted" | "not_authorized" | "failed"
 */
class HealthWorkoutSyncPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var binding: ActivityPluginBinding? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var pendingWantsBackground = false
    private var pendingNotificationPermission: MethodChannel.Result? = null

    private val client: HealthConnectClient by lazy { HealthConnectClient.getOrCreate(context) }

    private val readExercise = HealthPermission.getReadPermission(ExerciseSessionRecord::class)
    private val readInBackground = HealthPermission.PERMISSION_READ_HEALTH_DATA_IN_BACKGROUND

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        scope.cancel()
    }

    // ── ActivityAware ─────────────────────────────────────────────────────────

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.binding = binding
        binding.addActivityResultListener(this)
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() {
        binding?.removeActivityResultListener(this)
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
    }

    // ── Calls ─────────────────────────────────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isAvailable" -> result.success(isAvailable())
            "availability" -> result.success(
                when (HealthConnectClient.getSdkStatus(context)) {
                    HealthConnectClient.SDK_AVAILABLE -> "available"
                    HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> "needs_install"
                    else -> "unsupported"
                }
            )
            "installHealthConnect" -> result.success(installHealthConnect())
            "requestAuthorization" -> requestAuthorization(
                call.argument<Boolean>("background") ?: true,
                result,
            )
            "hasAuthorization" -> launch(result) { granted().contains(readExercise) }
            "isBackgroundAuthorized" -> launch(result) { granted().contains(readInBackground) }
            "initialCursor" -> launch(result) {
                client.getChangesToken(ChangesTokenRequest(setOf(ExerciseSessionRecord::class)))
            }
            "changes" -> launch(result) {
                changes(
                    call.argument<String>("cursor")!!,
                    Instant.ofEpochMilli(call.argument<Number>("since")!!.toLong()),
                    call.argument<Boolean>("includeSelf") ?: false,
                )
            }
            "readWindow" -> launch(result) {
                readWindow(
                    Instant.ofEpochMilli(call.argument<Number>("start")!!.toLong()),
                    Instant.ofEpochMilli(call.argument<Number>("end")!!.toLong()),
                    call.argument<Boolean>("includeSelf") ?: false,
                )
            }
            "openHealthSettings" -> result.success(
                openHealthSettings(call.argument<String>("page") ?: "app")
            )
            "installedPackages" -> result.success(
                installedPackages(call.argument<List<String>>("packages") ?: emptyList())
            )
            "launchPackage" -> result.success(launchPackage(call.argument<String>("package") ?: ""))
            "notificationsEnabled" -> result.success(
                NotificationManagerCompat.from(context).areNotificationsEnabled()
            )
            "requestNotificationPermission" -> requestNotificationPermission(result)
            "notify" -> result.success(
                postNotification(
                    call.argument<String>("id") ?: "health_workout_sync",
                    call.argument<String>("title") ?: "",
                    call.argument<String>("body") ?: "",
                    call.argument<String>("channelId") ?: "health_workout_sync",
                    call.argument<String>("channelName") ?: "Workout imports",
                )
            )
            else -> result.notImplemented()
        }
    }

    /** Runs [block] off the platform thread's call stack; errors → FlutterError. */
    private fun launch(result: MethodChannel.Result, block: suspend () -> Any?) {
        if (!isAvailable()) {
            result.error("unavailable", "Health Connect is not available", null)
            return
        }
        scope.launch {
            try {
                result.success(block())
            } catch (e: SecurityException) {
                result.error("unauthorized", e.message, null)
            } catch (e: Exception) {
                Log.w(TAG, "${e.javaClass.simpleName}: ${e.message}")
                result.error("health_connect", e.message, e.javaClass.simpleName)
            }
        }
    }

    private fun isAvailable(): Boolean =
        HealthConnectClient.getSdkStatus(context) == HealthConnectClient.SDK_AVAILABLE

    private suspend fun granted(): Set<String> = client.permissionController.getGrantedPermissions()

    private suspend fun backgroundReadSupported(): Boolean =
        client.features.getFeatureStatus(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_IN_BACKGROUND) ==
            HealthConnectFeatures.FEATURE_STATUS_AVAILABLE

    // ── Permissions ───────────────────────────────────────────────────────────

    private fun requestAuthorization(background: Boolean, result: MethodChannel.Result) {
        val activity: Activity = binding?.activity ?: run {
            result.error("no_activity", "Permission requests need a foreground activity", null)
            return
        }
        if (!isAvailable()) {
            result.error("unavailable", "Health Connect is not available", null)
            return
        }
        if (pendingPermission != null) {
            result.error("busy", "A permission request is already showing", null)
            return
        }
        scope.launch {
            try {
                val wanted = mutableSetOf(readExercise)
                if (background && backgroundReadSupported()) wanted += readInBackground
                val already = granted()
                if (already.containsAll(wanted)) {
                    result.success(permissionPayload(already))
                    return@launch
                }
                pendingPermission = result
                pendingWantsBackground = background
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    // Android 14+: Health Connect permissions are platform
                    // runtime permissions. The client's contract intent there
                    // is AndroidX's REQUEST_PERMISSIONS action, which only an
                    // ActivityResultRegistry can launch — started raw from a
                    // plain FlutterActivity it is rejected and no sheet shows.
                    activity.requestPermissions(wanted.toTypedArray(), REQUEST_CODE)
                } else {
                    // Android 13-: the Health Connect APK's own permission UI.
                    val contract = PermissionController.createRequestPermissionResultContract()
                    activity.startActivityForResult(contract.createIntent(activity, wanted), REQUEST_CODE)
                }
            } catch (e: Exception) {
                pendingPermission = null
                result.error("health_connect", e.message, null)
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode == NOTIFICATION_REQUEST_CODE) {
            val result = pendingNotificationPermission ?: return true
            pendingNotificationPermission = null
            result.success(NotificationManagerCompat.from(context).areNotificationsEnabled())
            return true
        }
        return onActivityResult(requestCode, Activity.RESULT_OK, null)
    }

    /**
     * Android 13+ asks for POST_NOTIFICATIONS at runtime (declared in the
     * plugin manifest). Older versions have no prompt: the answer is whether
     * notifications are switched on for the app.
     */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        val enabled = NotificationManagerCompat.from(context).areNotificationsEnabled()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || enabled) {
            result.success(enabled)
            return
        }
        val activity: Activity = binding?.activity ?: run {
            result.error("no_activity", "Permission requests need a foreground activity", null)
            return
        }
        if (pendingNotificationPermission != null) {
            result.error("busy", "A permission request is already showing", null)
            return
        }
        if (activity.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(enabled)
            return
        }
        pendingNotificationPermission = result
        activity.requestPermissions(
            arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_REQUEST_CODE,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pendingPermission ?: return true
        pendingPermission = null
        // Re-read rather than trusting the contract's result: the user may have
        // granted only part of the set, or already had some of it.
        scope.launch {
            try {
                result.success(permissionPayload(granted()))
            } catch (e: Exception) {
                result.error("health_connect", e.message, null)
            }
        }
        return true
    }

    private fun permissionPayload(granted: Set<String>) = mapOf(
        "granted" to granted.contains(readExercise),
        "backgroundGranted" to granted.contains(readInBackground),
    )

    // ── Reads ─────────────────────────────────────────────────────────────────

    /**
     * Drains a changes token. Only exercise sessions are tracked by the token;
     * our own writes are skipped unless [includeSelf] (a testing aid). Sessions that
     * ended before [since] are dropped — edits to pre-connection history must
     * not import.
     */
    private suspend fun changes(token: String, since: Instant, includeSelf: Boolean): Map<String, Any?> {
        val workouts = mutableListOf<Map<String, Any?>>()
        val deleted = mutableListOf<String>()
        var cursor = token
        var pages = 0
        while (true) {
            val response = client.getChanges(cursor)
            if (response.changesTokenExpired) {
                return mapOf("expired" to true)
            }
            for (change in response.changes) {
                when (change) {
                    is UpsertionChange -> {
                        val record = change.record as? ExerciseSessionRecord ?: continue
                        if (!includeSelf && isOwn(record)) continue
                        if (record.endTime.isBefore(since)) continue
                        workouts += toMap(record)
                    }
                    is DeletionChange -> deleted += change.recordId
                }
            }
            cursor = response.nextChangesToken
            pages++
            // Bounded so a huge backlog can't blow a background job's budget;
            // the returned cursor resumes exactly where this stopped.
            if (!response.hasMore || pages >= MAX_CHANGE_PAGES) break
        }
        return mapOf(
            "workouts" to workouts,
            "deleted" to deleted,
            "cursor" to cursor,
            "expired" to false,
        )
    }

    private suspend fun readWindow(start: Instant, end: Instant, includeSelf: Boolean): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        var pageToken: String? = null
        do {
            val response = client.readRecords(
                ReadRecordsRequest(
                    recordType = ExerciseSessionRecord::class,
                    timeRangeFilter = TimeRangeFilter.between(start, end),
                    pageToken = pageToken,
                )
            )
            response.records
                .filter { includeSelf || !isOwn(it) }
                .mapTo(out) { toMap(it) }
            pageToken = response.pageToken
        } while (pageToken != null)
        return out
    }

    private val labels = mutableMapOf<String, String>()

    /**
     * The writing app's display name ("Samsung Health"). Visible only for
     * packages Android lets us see (the plugin's `<queries>`); otherwise the
     * package name.
     */
    private fun appLabel(packageName: String): String = labels.getOrPut(packageName) {
        try {
            val pm = context.packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(packageName, 0)).toString()
        } catch (_: Exception) {
            packageName
        }
    }

    private fun isOwn(record: ExerciseSessionRecord) =
        record.metadata.dataOrigin.packageName == context.packageName

    private fun toMap(record: ExerciseSessionRecord): Map<String, Any?> = mapOf(
        "id" to record.metadata.id,
        "start" to record.startTime.toEpochMilli(),
        "end" to record.endTime.toEpochMilli(),
        "activityType" to exerciseTypeName(record.exerciseType),
        "sourceAppId" to record.metadata.dataOrigin.packageName,
        "sourceName" to appLabel(record.metadata.dataOrigin.packageName),
        "title" to record.title,
        "userEntered" to (record.metadata.recordingMethod == Metadata.RECORDING_METHOD_MANUAL_ENTRY),
    )

    // ── Other apps ────────────────────────────────────────────────────────────

    /**
     * Which of [packages] are installed. Android 11+ hides other apps unless
     * the HOST app lists them under `<queries>` in its manifest — unlisted
     * packages always read as absent.
     */
    private fun installedPackages(packages: List<String>): List<String> =
        packages.filter { pkg ->
            try {
                context.packageManager.getApplicationInfo(pkg, 0)
                true
            } catch (_: Exception) {
                false
            }
        }

    /** Opens another app (e.g. Samsung Health) so the user can turn sharing on. */
    private fun launchPackage(pkg: String): Boolean {
        val intent = context.packageManager.getLaunchIntentForPackage(pkg) ?: return false
        return try {
            val launcher: Context = binding?.activity ?: context
            if (launcher !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            launcher.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    // ── Local notifications ───────────────────────────────────────────────────

    /**
     * Immediate local notification — works from the WorkManager isolate, which
     * is the point: the background pass that imports a workout is the only
     * thing that knows to tell the user. A fixed [id] replaces the previous
     * banner instead of stacking. Tapping opens the app.
     */
    private fun postNotification(
        id: String,
        title: String,
        body: String,
        channelId: String,
        channelName: String,
    ): String {
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return "not_authorized"
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val system = context.getSystemService(NotificationManager::class.java)
                if (system.getNotificationChannel(channelId) == null) {
                    system.createNotificationChannel(
                        NotificationChannel(channelId, channelName, NotificationManager.IMPORTANCE_HIGH)
                    )
                }
            }
            val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val tap = launch?.let {
                PendingIntent.getActivity(
                    context,
                    id.hashCode(),
                    it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
            }
            val notification = NotificationCompat.Builder(context, channelId)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .apply { if (tap != null) setContentIntent(tap) }
                .build()
            manager.notify(id.hashCode(), notification)
            "posted"
        } catch (e: SecurityException) {
            "not_authorized"
        } catch (e: Exception) {
            Log.w(TAG, "notify failed: ${e.message}")
            "failed"
        }
    }

    // ── Settings ──────────────────────────────────────────────────────────────

    /** Health Connect's per-app permission screen (Android 14+), else its home. */
    /**
     * Android 13 and lower: Health Connect is an app from Google Play. Opens
     * its Play Store page (Google's onboarding link), falling back to the web.
     */
    private fun installHealthConnect(): Boolean {
        val providerPackage = "com.google.android.apps.healthdata"
        val launcher: Context = binding?.activity ?: context
        val intents = listOf(
            Intent(Intent.ACTION_VIEW).apply {
                setPackage("com.android.vending")
                data = android.net.Uri.parse(
                    "market://details?id=$providerPackage&url=healthconnect%3A%2F%2Fonboarding"
                )
                putExtra("overlay", true)
                putExtra("callerId", context.packageName)
            },
            Intent(
                Intent.ACTION_VIEW,
                android.net.Uri.parse("https://play.google.com/store/apps/details?id=$providerPackage"),
            ),
        )
        for (intent in intents) {
            try {
                if (launcher !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                launcher.startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
            }
        }
        return false
    }

    /**
     * [page] "app": this app's Health Connect permissions. "home": Health
     * Connect's main screen, where every app's sharing is listed — where a
     * user checks that Samsung Health / Garmin / … are allowed to write.
     */
    private fun openHealthSettings(page: String): Boolean {
        val intents = buildList {
            if (page == "app" && Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                add(
                    Intent("android.health.connect.action.MANAGE_HEALTH_PERMISSIONS")
                        .putExtra(Intent.EXTRA_PACKAGE_NAME, context.packageName)
                )
            }
            add(Intent(HealthConnectClient.ACTION_HEALTH_CONNECT_SETTINGS))
        }
        val launcher: Context = binding?.activity ?: context
        for (intent in intents) {
            try {
                if (launcher !is Activity) intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                launcher.startActivity(intent)
                return true
            } catch (_: ActivityNotFoundException) {
            } catch (_: SecurityException) {
            }
        }
        return false
    }

    companion object {
        private const val TAG = "HealthWorkoutSync"
        private const val CHANNEL = "health_workout_sync"
        private const val REQUEST_CODE = 0x4857 // "HW"
        private const val NOTIFICATION_REQUEST_CODE = 0x484E // "HN"
        private const val MAX_CHANGE_PAGES = 20

        /** Health Connect exercise type → stable name (EXERCISE_TYPE_ prefix dropped). */
        private val exerciseTypeNames: Map<Int, String> = mapOf(
            ExerciseSessionRecord.EXERCISE_TYPE_BADMINTON to "BADMINTON",
            ExerciseSessionRecord.EXERCISE_TYPE_BASEBALL to "BASEBALL",
            ExerciseSessionRecord.EXERCISE_TYPE_BASKETBALL to "BASKETBALL",
            ExerciseSessionRecord.EXERCISE_TYPE_BIKING to "BIKING",
            ExerciseSessionRecord.EXERCISE_TYPE_BIKING_STATIONARY to "BIKING_STATIONARY",
            ExerciseSessionRecord.EXERCISE_TYPE_BOOT_CAMP to "BOOT_CAMP",
            ExerciseSessionRecord.EXERCISE_TYPE_BOXING to "BOXING",
            ExerciseSessionRecord.EXERCISE_TYPE_CALISTHENICS to "CALISTHENICS",
            ExerciseSessionRecord.EXERCISE_TYPE_CRICKET to "CRICKET",
            ExerciseSessionRecord.EXERCISE_TYPE_DANCING to "DANCING",
            ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL to "ELLIPTICAL",
            ExerciseSessionRecord.EXERCISE_TYPE_EXERCISE_CLASS to "EXERCISE_CLASS",
            ExerciseSessionRecord.EXERCISE_TYPE_FENCING to "FENCING",
            ExerciseSessionRecord.EXERCISE_TYPE_FOOTBALL_AMERICAN to "FOOTBALL_AMERICAN",
            ExerciseSessionRecord.EXERCISE_TYPE_FOOTBALL_AUSTRALIAN to "FOOTBALL_AUSTRALIAN",
            ExerciseSessionRecord.EXERCISE_TYPE_FRISBEE_DISC to "FRISBEE_DISC",
            ExerciseSessionRecord.EXERCISE_TYPE_GOLF to "GOLF",
            ExerciseSessionRecord.EXERCISE_TYPE_GUIDED_BREATHING to "GUIDED_BREATHING",
            ExerciseSessionRecord.EXERCISE_TYPE_GYMNASTICS to "GYMNASTICS",
            ExerciseSessionRecord.EXERCISE_TYPE_HANDBALL to "HANDBALL",
            ExerciseSessionRecord.EXERCISE_TYPE_HIGH_INTENSITY_INTERVAL_TRAINING to "HIGH_INTENSITY_INTERVAL_TRAINING",
            ExerciseSessionRecord.EXERCISE_TYPE_HIKING to "HIKING",
            ExerciseSessionRecord.EXERCISE_TYPE_ICE_HOCKEY to "ICE_HOCKEY",
            ExerciseSessionRecord.EXERCISE_TYPE_ICE_SKATING to "ICE_SKATING",
            ExerciseSessionRecord.EXERCISE_TYPE_MARTIAL_ARTS to "MARTIAL_ARTS",
            ExerciseSessionRecord.EXERCISE_TYPE_PADDLING to "PADDLING",
            ExerciseSessionRecord.EXERCISE_TYPE_PARAGLIDING to "PARAGLIDING",
            ExerciseSessionRecord.EXERCISE_TYPE_PILATES to "PILATES",
            ExerciseSessionRecord.EXERCISE_TYPE_RACQUETBALL to "RACQUETBALL",
            ExerciseSessionRecord.EXERCISE_TYPE_ROCK_CLIMBING to "ROCK_CLIMBING",
            ExerciseSessionRecord.EXERCISE_TYPE_ROLLER_HOCKEY to "ROLLER_HOCKEY",
            ExerciseSessionRecord.EXERCISE_TYPE_ROWING to "ROWING",
            ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE to "ROWING_MACHINE",
            ExerciseSessionRecord.EXERCISE_TYPE_RUGBY to "RUGBY",
            ExerciseSessionRecord.EXERCISE_TYPE_RUNNING to "RUNNING",
            ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL to "RUNNING_TREADMILL",
            ExerciseSessionRecord.EXERCISE_TYPE_SAILING to "SAILING",
            ExerciseSessionRecord.EXERCISE_TYPE_SCUBA_DIVING to "SCUBA_DIVING",
            ExerciseSessionRecord.EXERCISE_TYPE_SKATING to "SKATING",
            ExerciseSessionRecord.EXERCISE_TYPE_SKIING to "SKIING",
            ExerciseSessionRecord.EXERCISE_TYPE_SNOWBOARDING to "SNOWBOARDING",
            ExerciseSessionRecord.EXERCISE_TYPE_SNOWSHOEING to "SNOWSHOEING",
            ExerciseSessionRecord.EXERCISE_TYPE_SOCCER to "SOCCER",
            ExerciseSessionRecord.EXERCISE_TYPE_SOFTBALL to "SOFTBALL",
            ExerciseSessionRecord.EXERCISE_TYPE_SQUASH to "SQUASH",
            ExerciseSessionRecord.EXERCISE_TYPE_STAIR_CLIMBING to "STAIR_CLIMBING",
            ExerciseSessionRecord.EXERCISE_TYPE_STAIR_CLIMBING_MACHINE to "STAIR_CLIMBING_MACHINE",
            ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING to "STRENGTH_TRAINING",
            ExerciseSessionRecord.EXERCISE_TYPE_STRETCHING to "STRETCHING",
            ExerciseSessionRecord.EXERCISE_TYPE_SURFING to "SURFING",
            ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER to "SWIMMING_OPEN_WATER",
            ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL to "SWIMMING_POOL",
            ExerciseSessionRecord.EXERCISE_TYPE_TABLE_TENNIS to "TABLE_TENNIS",
            ExerciseSessionRecord.EXERCISE_TYPE_TENNIS to "TENNIS",
            ExerciseSessionRecord.EXERCISE_TYPE_VOLLEYBALL to "VOLLEYBALL",
            ExerciseSessionRecord.EXERCISE_TYPE_WALKING to "WALKING",
            ExerciseSessionRecord.EXERCISE_TYPE_WATER_POLO to "WATER_POLO",
            ExerciseSessionRecord.EXERCISE_TYPE_WEIGHTLIFTING to "WEIGHTLIFTING",
            ExerciseSessionRecord.EXERCISE_TYPE_WHEELCHAIR to "WHEELCHAIR",
            ExerciseSessionRecord.EXERCISE_TYPE_YOGA to "YOGA",
            ExerciseSessionRecord.EXERCISE_TYPE_OTHER_WORKOUT to "OTHER_WORKOUT",
        )

        fun exerciseTypeName(type: Int): String = exerciseTypeNames[type] ?: "OTHER_WORKOUT"
    }
}
