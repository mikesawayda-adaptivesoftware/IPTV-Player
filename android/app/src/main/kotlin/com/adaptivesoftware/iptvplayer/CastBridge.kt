package com.adaptivesoftware.iptvplayer

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.HlsSegmentFormat
import com.google.android.gms.cast.HlsVideoSegmentFormat
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastOptions
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.OptionsProvider
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.SessionProvider
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Points the Cast SDK at Google's Default Media Receiver, so no receiver app
 * has to be registered or hosted. Named in the manifest.
 */
class CastOptionsProvider : OptionsProvider {
    override fun getCastOptions(context: Context): CastOptions =
        CastOptions.Builder()
            .setReceiverApplicationId(
                CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID
            )
            .build()

    override fun getAdditionalSessionProviders(context: Context): List<SessionProvider>? = null
}

/**
 * The Cast session, driven from Dart (`lib/core/cast/cast_bridge.dart`).
 *
 * Devices are found with MediaRouter directly rather than Google's
 * MediaRouteButton, because that button needs a FragmentActivity and
 * FlutterActivity is not one. Selecting a route is what makes the Cast
 * framework start a session; everything after that goes through the
 * session's RemoteMediaClient.
 */
class CastBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) {
    private val context: Context = activity.applicationContext

    companion object {
        const val CHANNEL = "com.adaptivesoftware.iptvplayer/cast"
    }

    private val channel = MethodChannel(messenger, CHANNEL)
    private var castContext: CastContext? = null
    private val router by lazy { MediaRouter.getInstance(context) }
    private val selector by lazy {
        MediaRouteSelector.Builder()
            .addControlCategory(
                CastMediaControlIntent.categoryForCast(
                    CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID
                )
            )
            .build()
    }
    private var discovering = false
    private var keptAlive = false
    private var mediaClient: RemoteMediaClient? = null

    init {
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "startDiscovery" -> {
                        startDiscovery()
                        result.success(null)
                    }
                    "stopDiscovery" -> {
                        stopDiscovery()
                        result.success(null)
                    }
                    "connect" -> {
                        connect(call.argument<String>("id") ?: "")
                        result.success(null)
                    }
                    "load" -> load(
                        call.argument<String>("url") ?: "",
                        call.argument<String>("title") ?: "",
                        call.argument<Boolean>("live") ?: true,
                        result,
                    )
                    "disconnect" -> {
                        disconnect()
                        result.success(null)
                    }
                    "keepAlive" -> {
                        keepAlive(
                            call.argument<String>("title") ?: "",
                            call.argument<String>("device") ?: "Chromecast",
                        )
                        result.success(null)
                    }
                    "releaseKeepAlive" -> {
                        CastKeepAliveService.stop(context)
                        keptAlive = false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                result.error("cast", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }

    /**
     * Lazily, because CastContext needs Google Play services and throws where
     * they are missing - it must not take the whole app down at startup.
     * Initialising it is also what registers the Cast route provider, so
     * discovery finds nothing until this has run.
     */
    @Suppress("DEPRECATION")
    private fun cast(): CastContext {
        castContext?.let { return it }
        val created = CastContext.getSharedInstance(context)
        created.sessionManager.addSessionManagerListener(
            sessionListener, CastSession::class.java
        )
        castContext = created
        return created
    }

    private fun startDiscovery() {
        cast()
        if (!discovering) {
            router.addCallback(
                selector, routerCallback, MediaRouter.CALLBACK_FLAG_PERFORM_ACTIVE_SCAN
            )
            discovering = true
        }
        publishRoutes()
    }

    private fun stopDiscovery() {
        if (discovering) {
            router.removeCallback(routerCallback)
            discovering = false
        }
    }

    private fun connect(id: String) {
        cast()
        val route = router.routes.firstOrNull { it.id == id }
            ?: throw IllegalStateException("That device is no longer visible")
        channel.invokeMethod("session", "connecting")
        router.selectRoute(route)
    }

    private fun load(url: String, title: String, live: Boolean, result: MethodChannel.Result) {
        val client = cast().sessionManager.currentCastSession?.remoteMediaClient
        if (client == null) {
            result.error("cast", "Not connected to a Chromecast", null)
            return
        }
        attach(client)

        val metadata = MediaMetadata(MediaMetadata.MEDIA_TYPE_MOVIE).apply {
            putString(MediaMetadata.KEY_TITLE, title)
        }
        val info = MediaInfo.Builder(url)
            .setContentUrl(url)
            .setContentType("application/x-mpegURL")
            .setStreamType(
                if (live) MediaInfo.STREAM_TYPE_LIVE else MediaInfo.STREAM_TYPE_BUFFERED
            )
            // The relay's segments are MPEG-TS. Without these the receiver
            // assumes packed audio and plays nothing.
            .setHlsSegmentFormat(HlsSegmentFormat.TS)
            .setHlsVideoSegmentFormat(HlsVideoSegmentFormat.MPEG2_TS)
            .setMetadata(metadata)
            .build()
        val request = MediaLoadRequestData.Builder()
            .setMediaInfo(info)
            .setAutoplay(true)
            .build()

        client.load(request).setResultCallback { r ->
            if (r.status.isSuccess) {
                result.success(null)
            } else {
                result.error(
                    "cast",
                    "Chromecast refused the stream (code ${r.status.statusCode})",
                    null,
                )
            }
        }
    }

    /**
     * Starts the screen-off service on the first call, and only updates its
     * notification after that (see [CastKeepAliveService.update]).
     */
    private fun keepAlive(title: String, device: String) {
        if (keptAlive) {
            CastKeepAliveService.update(context, title, device)
            return
        }
        // Android 13+ hides the notification without this. The service still
        // runs either way, so a refusal costs only the notification.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            activity.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 4712)
        }
        CastKeepAliveService.onStopRequested = {
            channel.invokeMethod("stopRequested", null)
        }
        CastKeepAliveService.start(context, title, device)
        keptAlive = true
    }

    private fun disconnect() {
        mediaClient?.unregisterCallback(mediaCallback)
        mediaClient = null
        castContext?.sessionManager?.endCurrentSession(true)
        router.unselect(MediaRouter.UNSELECT_REASON_STOPPED)
    }

    fun dispose() {
        CastKeepAliveService.onStopRequested = null
        if (keptAlive) CastKeepAliveService.stop(context)
        stopDiscovery()
        mediaClient?.unregisterCallback(mediaCallback)
        castContext?.sessionManager?.removeSessionManagerListener(
            sessionListener, CastSession::class.java
        )
        channel.setMethodCallHandler(null)
    }

    private fun attach(client: RemoteMediaClient) {
        if (client === mediaClient) return
        mediaClient?.unregisterCallback(mediaCallback)
        client.registerCallback(mediaCallback)
        mediaClient = client
    }

    private fun publishRoutes() {
        val devices = router.routes
            .filter { !it.isDefault && it.isEnabled && it.matchesSelector(selector) }
            .map {
                mapOf(
                    "id" to it.id,
                    "name" to it.name,
                    "description" to it.description,
                )
            }
        channel.invokeMethod("devices", devices)
    }

    private val routerCallback = object : MediaRouter.Callback() {
        override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) = publishRoutes()
        override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) = publishRoutes()
        override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) = publishRoutes()
    }

    private val mediaCallback = object : RemoteMediaClient.Callback() {
        override fun onStatusUpdated() {
            val status = mediaClient?.mediaStatus ?: return
            val idleReason = when (status.idleReason) {
                MediaStatus.IDLE_REASON_FINISHED -> "finished"
                MediaStatus.IDLE_REASON_CANCELED -> "canceled"
                MediaStatus.IDLE_REASON_INTERRUPTED -> "interrupted"
                MediaStatus.IDLE_REASON_ERROR -> "error"
                else -> null
            }
            channel.invokeMethod(
                "receiver",
                mapOf("state" to status.playerState, "idleReason" to idleReason),
            )
        }
    }

    private val sessionListener = object : SessionManagerListener<CastSession> {
        override fun onSessionStarting(session: CastSession) {
            channel.invokeMethod("session", "connecting")
        }

        override fun onSessionStarted(session: CastSession, sessionId: String) {
            channel.invokeMethod("session", "connected")
        }

        override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
            channel.invokeMethod("session", "connected")
        }

        override fun onSessionStartFailed(session: CastSession, error: Int) {
            channel.invokeMethod("session", "failed: could not start (code $error)")
        }

        override fun onSessionEnded(session: CastSession, error: Int) {
            channel.invokeMethod("session", "ended")
        }

        override fun onSessionResumeFailed(session: CastSession, error: Int) {
            channel.invokeMethod("session", "failed: could not resume (code $error)")
        }

        override fun onSessionSuspended(session: CastSession, reason: Int) {
            channel.invokeMethod("session", "connecting")
        }

        override fun onSessionEnding(session: CastSession) {}
        override fun onSessionResuming(session: CastSession, sessionId: String) {}
    }
}
