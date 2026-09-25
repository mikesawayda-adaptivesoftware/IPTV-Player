package com.adaptivesoftware.iptvplayer

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.adaptivesoftware.iptvplayer/platform"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> result.success(isTelevision())

                    "setKeepScreenOn" -> {
                        setKeepScreenOn(call.argument<Boolean>("enabled") ?: false)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Whether this device is a TV.
     *
     * Three signals OR'd together. [UiModeManager] is the canonical check and is
     * correct on a real Google TV device, but AOSP-based boxes sometimes report
     * UI_MODE_TYPE_NORMAL, so the leanback feature and the absence of a
     * touchscreen are used as fallbacks. Any one of them is conclusive enough:
     * nothing that is not a TV reports leanback or lacks a touchscreen.
     *
     * Resolved once at app startup. That is safe because the activity declares
     * `uiMode` in configChanges - TV-ness never changes at runtime.
     */
    private fun isTelevision(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) {
            return true
        }
        if (packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)) {
            return true
        }
        return !packageManager.hasSystemFeature(PackageManager.FEATURE_TOUCHSCREEN)
    }

    /**
     * Holds the screen awake while something is playing.
     *
     * media_kit renders into a Flutter [android.view.Texture] rather than a
     * SurfaceView, so Android has no idea video is on screen and the TV's
     * daydream/screensaver will fire mid-programme. Nothing else in the app
     * asks for a wakelock.
     */
    private fun setKeepScreenOn(enabled: Boolean) {
        if (enabled) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }
    }
}
