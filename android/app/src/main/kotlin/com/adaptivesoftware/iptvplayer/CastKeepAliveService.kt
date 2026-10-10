package com.adaptivesoftware.iptvplayer

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/**
 * Keeps the phone relaying while casting with the screen off.
 *
 * The relay runs in Dart, in this app's process. With the screen off Android
 * would otherwise suspend the CPU and power the Wi-Fi radio down within a
 * minute or so, and the Chromecast would run out of chunks. A foreground
 * service keeps the process eligible to run, the wake lock keeps the CPU up,
 * and the Wi-Fi lock keeps the radio at full speed - the relay both receives
 * and re-sends every byte, so a throttled radio halves what it can carry.
 *
 * Started and stopped from Dart through [CastBridge]. The notification's Stop
 * action is handed back to Dart, which owns the teardown order (provider
 * connection first, so the phone can never hold two streams).
 */
class CastKeepAliveService : Service() {

    companion object {
        const val EXTRA_TITLE = "title"
        const val EXTRA_DEVICE = "device"
        private const val ACTION_STOP = "com.adaptivesoftware.iptvplayer.CAST_STOP"
        private const val CHANNEL_ID = "casting"
        private const val NOTIFICATION_ID = 4711

        /** Set by [CastBridge]; called when the notification's Stop is tapped. */
        var onStopRequested: (() -> Unit)? = null

        fun start(context: Context, title: String, device: String) {
            val intent = Intent(context, CastKeepAliveService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_DEVICE, device)
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
         * Changes the notification's text in place. Not [start] again: from
         * the background, Android 12+ refuses to start a foreground service,
         * even one that is already running.
         */
        fun update(context: Context, title: String, device: String) {
            if (!running) return
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE)
                as NotificationManager
            manager.notify(NOTIFICATION_ID, buildNotification(context, title, device))
        }

        private var running = false

        private fun buildNotification(context: Context, title: String, device: String): Notification {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
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
                context, 0,
                Intent(context, MainActivity::class.java)
                    .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or immutable,
            )
            val stop = PendingIntent.getService(
                context, 1,
                Intent(context, CastKeepAliveService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_UPDATE_CURRENT or immutable,
            )

            @Suppress("DEPRECATION")
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                Notification.Builder(context)
            }
            @Suppress("DEPRECATION")
            return builder
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle("Casting to $device")
                .setContentText(title)
                .setContentIntent(open)
                .setOngoing(true)
                .addAction(
                    Notification.Action.Builder(
                        android.R.drawable.ic_media_pause, "Stop casting", stop
                    ).build()
                )
                .build()
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            onStopRequested?.invoke()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: ""
        val device = intent?.getStringExtra(EXTRA_DEVICE) ?: "Chromecast"
        val notification = buildNotification(this, title, device)
        running = true
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
        running = false
        releaseLocks()
        super.onDestroy()
    }

    /** The user swiped the app away: nothing is left to relay. */
    override fun onTaskRemoved(rootIntent: Intent?) {
        onStopRequested?.invoke()
        stopSelf()
        super.onTaskRemoved(rootIntent)
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
