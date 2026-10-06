package com.levelupfitness.health_workout_sync

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log

/**
 * Health Connect's "why does this app need access?" / privacy-policy link.
 *
 * Health Connect refuses to show its permission sheet unless the app handles
 * `ACTION_SHOW_PERMISSIONS_RATIONALE` (Android 13 and lower) and exposes a
 * `VIEW_PERMISSION_USAGE` alias (Android 14+). The plugin's manifest declares
 * both and merges them into the host app, so apps don't write any Kotlin.
 *
 * The host app supplies its privacy policy in AndroidManifest.xml:
 *
 * ```xml
 * <meta-data
 *     android:name="health_workout_sync.privacy_policy_url"
 *     android:value="https://example.com/privacy" />
 * ```
 */
class HealthPermissionsRationaleActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val url = privacyPolicyUrl()
        if (url == null) {
            Log.w(
                TAG,
                "No privacy policy configured. Add <meta-data android:name=\"$META_KEY\" " +
                    "android:value=\"https://…\"/> inside <application> in AndroidManifest.xml.",
            )
        } else {
            try {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
            } catch (_: ActivityNotFoundException) {
                Log.w(TAG, "No app can open $url")
            }
        }
        finish()
    }

    private fun privacyPolicyUrl(): String? = try {
        val info = if (Build.VERSION.SDK_INT >= 33) {
            packageManager.getApplicationInfo(
                packageName,
                PackageManager.ApplicationInfoFlags.of(PackageManager.GET_META_DATA.toLong()),
            )
        } else {
            @Suppress("DEPRECATION")
            packageManager.getApplicationInfo(packageName, PackageManager.GET_META_DATA)
        }
        info.metaData?.getString(META_KEY)?.takeIf { it.isNotBlank() }
    } catch (_: PackageManager.NameNotFoundException) {
        null
    }

    private companion object {
        const val TAG = "HealthWorkoutSync"
        const val META_KEY = "health_workout_sync.privacy_policy_url"
    }
}
