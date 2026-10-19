package com.you.life360monitor

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

class RelayService : Service() {

    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()

        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "life360monitor:relay")
        wake?.acquire()

        val chan = "monitor"
        val nm = getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(chan) == null) {
            nm.createNotificationChannel(
                NotificationChannel(chan, "Monitor", NotificationManager.IMPORTANCE_LOW)
            )
        }

        val notif = Notification.Builder(this, chan)
            .setContentTitle("Monitor")
            .setContentText("Connected to relay")
            .setSmallIcon(android.R.drawable.presence_online)
            .setOngoing(true)
            .build()

        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(1, notif)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        try { wake?.release() } catch (e: Exception) { }
        super.onDestroy()
    }

    companion object {
        fun start(ctx: Context) {
            val i = Intent(ctx, RelayService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }
    }
}
