package org.lumen.lumen

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Answers one question Flutter cannot: is this a television?
 *
 * Dart has no way to tell a TV box from a phone. Screen size does not do it —
 * a 1080p TV at density 2.0 reports 960x540dp, whose shortest side (540) is
 * squarely in phone territory, which is exactly how the player's phone-only
 * lock button and brightness rail ended up on the TV. Nor does
 * `defaultTargetPlatform`, which is plain `android` on every TV box.
 *
 * So ask the platform, which knows for certain. Three signals, any of which
 * settles it:
 *   - UiModeManager reports UI_MODE_TYPE_TELEVISION (the definitive answer on
 *     a well-behaved Android TV / Google TV device)
 *   - the device declares the leanback feature (Fire TV and other
 *     non-Google-certified boxes, some of which report a normal ui mode)
 *   - the device has no touchscreen at all, which no phone or tablet can say
 */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "org.lumen.lumen/device",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isTv" -> result.success(isTelevision())
                else -> result.notImplemented()
            }
        }
    }

    private fun isTelevision(): Boolean {
        val uiMode = (getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager)
            ?.currentModeType
        if (uiMode == Configuration.UI_MODE_TYPE_TELEVISION) return true
        val pm = packageManager
        if (pm.hasSystemFeature(PackageManager.FEATURE_LEANBACK)) return true
        if (pm.hasSystemFeature("android.software.leanback_only")) return true
        return !pm.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
    }
}
