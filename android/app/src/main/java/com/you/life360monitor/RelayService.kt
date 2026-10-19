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
import android.util.Base64
import android.webkit.WebView
import org.eclipse.paho.client.mqttv3.MqttAsyncClient
import org.eclipse.paho.client.mqttv3.MqttCallbackExtended
import org.eclipse.paho.client.mqttv3.MqttConnectOptions
import org.eclipse.paho.client.mqttv3.MqttMessage
import org.eclipse.paho.client.mqttv3.IMqttDeliveryToken
import org.eclipse.paho.client.mqttv3.persist.MemoryPersistence
import org.json.JSONObject
import java.util.UUID

class RelayService : Service() {

    private var wake: PowerManager.WakeLock? = null
    private var client: MqttAsyncClient? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this

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
            .setContentText("Connected to broker")
            .setSmallIcon(android.R.drawable.presence_online)
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(1, notif, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(1, notif)
        }

        connect()
    }

    private fun connect() {
        try {
            val cid = "l360and" + UUID.randomUUID().toString().take(8)
            val c = MqttAsyncClient("ssl://broker.emqx.io:8883", cid, MemoryPersistence())
            c.setCallback(object : MqttCallbackExtended {
                override fun connectComplete(reconnect: Boolean, serverURI: String?) {
                    val base = "l360/" + BuildConfig.TOKEN
                    c.subscribe(arrayOf("$base/up", "$base/bin"), intArrayOf(0, 0))
                }
                override fun connectionLost(cause: Throwable?) {}
                override fun deliveryComplete(token: IMqttDeliveryToken?) {}
                override fun messageArrived(topic: String?, msg: MqttMessage?) {
                    val p = msg?.payload ?: return
                    if (topic != null && topic.endsWith("/bin")) {
                        pushBin(p)
                    } else {
                        val plain = Crypto.open(String(p)) ?: return
                        pushText(plain)
                    }
                }
            })
            client = c
            val o = MqttConnectOptions()
            o.isAutomaticReconnect = true
            o.isCleanSession = true
            o.keepAliveInterval = 30
            o.connectionTimeout = 15
            c.connect(o)
        } catch (e: Exception) { }
    }

    fun send(plain: String) {
        val sealed = Crypto.seal(plain) ?: return
        try {
            client?.publish(
                "l360/" + BuildConfig.TOKEN + "/down",
                MqttMessage(sealed.toByteArray()).apply { qos = 0 }
            )
        } catch (e: Exception) { }
    }

    private fun pushText(json: String) {
        val w = webView ?: return
        w.post { w.evaluateJavascript("ws.onmessage({data:" + JSONObject.quote(json) + "})", null) }
    }

    private fun pushBin(d: ByteArray) {
        val w = webView ?: return
        val b64 = Base64.encodeToString(d, Base64.NO_WRAP)
        w.post { w.evaluateJavascript("__bin('" + b64 + "')", null) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onDestroy() {
        instance = null
        try { client?.disconnect() } catch (e: Exception) { }
        try { client?.close() } catch (e: Exception) { }
        try { wake?.release() } catch (e: Exception) { }
        super.onDestroy()
    }

    companion object {
        @Volatile var instance: RelayService? = null
        @Volatile var webView: WebView? = null

        fun start(ctx: Context) {
            val i = Intent(ctx, RelayService::class.java)
            if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
        }
    }
}
