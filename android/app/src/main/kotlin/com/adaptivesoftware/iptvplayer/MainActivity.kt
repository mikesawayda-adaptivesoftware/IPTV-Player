package com.adaptivesoftware.iptvplayer

import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "com.adaptivesoftware.iptvplayer/platform"
        private const val PIP_CHANNEL = "com.adaptivesoftware.iptvplayer/pip"

        // Android rejects a PiP aspect ratio outside 1:2.39 to 2.39:1.
        private const val MAX_PIP_ASPECT = 2.39f
    }

    private var castBridge: CastBridge? = null
    private var pipChannel: MethodChannel? = null

    /** Whether a playing video is on screen, so leaving should float it. */
    private var pipEnabled = false
    private var pipAspect = Rational(16, 9)

    /** Between onStop and onStart: what tells a closed PiP window from an expanded one. */
    private var stopped = false

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

        castBridge = CastBridge(this, flutterEngine.dartExecutor.binaryMessenger)

        pipChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PIP_CHANNEL)
            .also { channel ->
                channel.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "configure" -> {
                            configurePip(
                                call.argument<Boolean>("enabled") ?: false,
                                call.argument<Int>("width"),
                                call.argument<Int>("height"),
                            )
                            result.success(null)
                        }

                        else -> result.notImplemented()
                    }
                }
            }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        castBridge?.dispose()
        castBridge = null
        pipChannel?.setMethodCallHandler(null)
        pipChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
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

    // ------------------------------------------------------------------------
    // Picture-in-picture
    // ------------------------------------------------------------------------

    private fun pipSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)

    /**
     * Dart says whether a video is playing full screen, and its shape.
     *
     * On Android 12+ this is handed to the system up front with auto-enter, so
     * the shrink animates straight from the home gesture. Older versions have
     * no auto-enter and are entered by hand in [onUserLeaveHint].
     */
    private fun configurePip(enabled: Boolean, width: Int?, height: Int?) {
        pipEnabled = enabled
        if (width != null && height != null && width > 0 && height > 0) {
            val ratio = width.toFloat() / height
            pipAspect = when {
                ratio > MAX_PIP_ASPECT -> Rational(239, 100)
                ratio < 1 / MAX_PIP_ASPECT -> Rational(100, 239)
                else -> Rational(width, height)
            }
        }
        if (!pipSupported()) return
        try {
            setPictureInPictureParams(buildPipParams())
        } catch (e: IllegalStateException) {
            // Thrown if the activity cannot be put into PiP at all.
        }
    }

    private fun buildPipParams(): PictureInPictureParams {
        val builder = PictureInPictureParams.Builder().setAspectRatio(pipAspect)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            builder.setAutoEnterEnabled(pipEnabled)
            // Live video does not resize cleanly mid-frame; let the system
            // cross-fade instead of stretching the last frame.
            builder.setSeamlessResizeEnabled(false)
        }
        return builder.build()
    }

    override fun onStart() {
        super.onStart()
        stopped = false
    }

    override fun onStop() {
        stopped = true
        super.onStop()
    }

    /** Home or Recents while a video plays, before Android 12. */
    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!pipEnabled || !pipSupported()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return
        try {
            enterPictureInPictureMode(buildPipParams())
        } catch (e: IllegalStateException) {
            // Not allowed right now (e.g. the user turned PiP off for the app).
        }
    }

    override fun onPictureInPictureModeChanged(
        isInPictureInPictureMode: Boolean,
        newConfig: Configuration,
    ) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        pipChannel?.invokeMethod("modeChanged", isInPictureInPictureMode)
        // Leaving PiP either expands back to the app (the activity resumes) or
        // closes the window (it is stopped first, and stays stopped). Only the second
        // should stop the video.
        if (!isInPictureInPictureMode && stopped) {
            pipChannel?.invokeMethod("dismissed", null)
        }
    }
}
