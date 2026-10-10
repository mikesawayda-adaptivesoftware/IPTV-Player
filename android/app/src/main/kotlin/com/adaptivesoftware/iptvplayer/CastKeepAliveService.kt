package com.adaptivesoftware.iptvplayer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaMetadata
import android.media.VolumeProvider
import android.media.session.MediaSession
import android.media.session.PlaybackState
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the phone relaying while casting with the screen off, and carries the
 * lock-screen and notification controls.
 *
 * The relay runs in Dart, in this app's process. With the screen off Android
 * would otherwise suspend the CPU and power the Wi-Fi radio down within a
 * minute or so, and the Chromecast would run out of chunks. A foreground
 * service keeps the process eligible to run, the wake lock keeps the CPU up,
 * and the Wi-Fi lock keeps the radio at full speed - the relay both receives
 * and re-sends every byte, so a throttled radio halves what it can carry.
 *
 * The controls are a MediaSession of our own rather than the Cast SDK's, whose
 * notification has no channel up/down and whose Stop would end the session
 * behind the relay's back. Every button is handed to Dart as a command, so
 * Dart owns the order of every teardown (provider connection first, so the
 * phone can never hold two streams). The session plays to a remote volume
 * provider, which is what makes the phone's volume keys set the TV's volume,
 * screen off included.
 */
class CastKeepAliveService : Service() {

    /** What the notification and lock screen show. */
    data class Info(
        val title: String,
        val device: String,
        val live: Boolean,
        val playing: Boolean,
    )

    companion object {
        private const val ACTION_COMMAND = "com.adaptivesoftware.iptvplayer.CAST_COMMAND"
        private const val EXTRA_COMMAND = "command"
        private const val CHANNEL_ID = "casting"
        private const val NOTIFICATION_ID = 4711
        const val VOLUME_STEPS = 20

        /** Set by [CastBridge]: next, previous, play, pause or stop. */
        var onCommand: ((String) -> Unit)? = null

        /** Set by [CastBridge]: the volume keys, in [VOLUME_STEPS] steps. */
        var onVolume: ((Int) -> Unit)? = null

        private var instance: CastKeepAliveService? = null
        private var state = Info("", "Chromecast", live = true, playing = true)

        fun start(context: Context, info: Info) {
            state = info
            val intent = Intent(context, CastKeepAliveService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CastKeepAliveService::class.java))
        }

        /**
         * Changes what the notification and lock screen show, in place. Not
         * [start] again: from the background, Android 12+ refuses to start a
         * foreground service, even one that is already running.
         */
        fun update(info: Info) {
            state = info
            instance?.refresh()
        }

        /** The receiver's volume changed, from here or anywhere else. */
        fun setVolume(level: Double) {
            instance?.volumeProvider?.currentVolume =
                (level * VOLUME_STEPS).toInt().coerceIn(0, VOLUME_STEPS)
        }

        val running: Boolean get() = instance != null
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var session: MediaSession? = null
    private var volumeProvider: VolumeProvider? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_COMMAND) {
            intent.getStringExtra(EXTRA_COMMAND)?.let { onCommand?.invoke(it) }
            return START_NOT_STICKY
        }

        instance = this
        ensureSession()
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        acquireLocks()
        // Not sticky: if the process dies the relay died with it, and a
        // restarted service with nothing to keep alive would only mislead.
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        session?.isActive = false
        session?.release()
        session = null
        volumeProvider = null
        releaseLocks()
        super.onDestroy()
    }

    /** The user swiped the app away: nothing is left to relay. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        onCommand?.invoke("stop")
        stopSelf()
        super.onTaskRemoved(rootIntent)
    }

    private fun refresh() {
        updateSession()
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(NOTIFICATION_ID, buildNotification())
    }

    private fun ensureSession() {
        if (session != null) {
            updateSession()
            return
        }
        val volume = object : VolumeProvider(
            VolumeProvider.VOLUME_CONTROL_ABSOLUTE, VOLUME_STEPS, VOLUME_STEPS / 2
        ) {
            override fun onSetVolumeTo(volume: Int) {
                val level = volume.coerceIn(0, VOLUME_STEPS)
                currentVolume = level
                onVolume?.invoke(level)
            }

            override fun onAdjustVolume(direction: Int) {
                val level = (currentVolume + direction).coerceIn(0, VOLUME_STEPS)
                currentVolume = level
                onVolume?.invoke(level)
            }
        }
        volumeProvider = volume
        session = MediaSession(this, "DefinitelyNotCableCast").apply {
            setCallback(object : MediaSession.Callback() {
                override fun onSkipToNext() { onCommand?.invoke("next") }
                override fun onSkipToPrevious() { onCommand?.invoke("previous") }
                override fun onPlay() { onCommand?.invoke("play") }
                override fun onPause() { onCommand?.invoke("pause") }
                override fun onStop() { onCommand?.invoke("stop") }
            })
            setPlaybackToRemote(volume)
            isActive = true
        }
        updateSession()
    }

    private fun updateSession() {
        val s = session ?: return
        val info = state
        s.setMetadata(
            MediaMetadata.Builder()
                .putString(MediaMetadata.METADATA_KEY_TITLE, info.title)
                .putString(MediaMetadata.METADATA_KEY_ARTIST, "Casting to ${info.device}")
                .build()
        )
        val actions = PlaybackState.ACTION_STOP or if (info.live) {
            PlaybackState.ACTION_SKIP_TO_NEXT or PlaybackState.ACTION_SKIP_TO_PREVIOUS
        } else {
            PlaybackState.ACTION_PLAY or PlaybackState.ACTION_PAUSE or
                PlaybackState.ACTION_PLAY_PAUSE
        }
        s.setPlaybackState(
            PlaybackState.Builder()
                .setActions(actions)
                .setState(
                    if (info.playing) PlaybackState.STATE_PLAYING else PlaybackState.STATE_PAUSED,
                    PlaybackState.PLAYBACK_POSITION_UNKNOWN,
                    1f,
                )
                .build()
        )
    }

    private fun commandIntent(command: String, requestCode: Int): PendingIntent {
        val immutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
        return PendingIntent.getService(
            this, requestCode,
            Intent(this, CastKeepAliveService::class.java)
                .setAction(ACTION_COMMAND)
                .putExtra(EXTRA_COMMAND, command),
            PendingIntent.FLAG_UPDATE_CURRENT or immutable,
        )
    }

    private fun buildNotification(): Notification {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Casting", NotificationManager.IMPORTANCE_LOW)
                    .apply { description = "Shown while casting to a Chromecast" }
            )
        }

        val immutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
        val open = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or immutable,
        )

        fun action(icon: Int, label: String, command: String, code: Int) =
            Notification.Action.Builder(icon, label, commandIntent(command, code)).build()

        val info = state
        val actions = if (info.live) {
            listOf(
                action(android.R.drawable.ic_media_previous, "Previous channel", "previous", 1),
                action(android.R.drawable.ic_menu_close_clear_cancel, "Stop casting", "stop", 2),
                action(android.R.drawable.ic_media_next, "Next channel", "next", 3),
            )
        } else {
            listOf(
                if (info.playing) {
                    action(android.R.drawable.ic_media_pause, "Pause", "pause", 4)
                } else {
                    action(android.R.drawable.ic_media_play, "Play", "play", 5)
                },
                action(android.R.drawable.ic_menu_close_clear_cancel, "Stop casting", "stop", 2),
            )
        }

        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        val style = Notification.MediaStyle()
        session?.let { style.setMediaSession(it.sessionToken) }
        style.setShowActionsInCompactView(*IntArray(actions.size) { it })
        builder
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(info.title)
            .setContentText("Casting to ${info.device}")
            .setContentIntent(open)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setStyle(style)
        actions.forEach { builder.addAction(it) }
        return builder.build()
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK, "DefinitelyNotCable:cast"
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "DefinitelyNotCable:cast").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }
}
