package com.you.life360monitor

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.util.Base64
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.File

class MainActivity : Activity() {

  private var web: WebView? = null

  inner class Bridge {
    @JavascriptInterface fun send(s: String) { RelayService.instance?.send(s) }
    @JavascriptInterface fun token(): String = BuildConfig.TOKEN
    @JavascriptInterface fun save(name: String, text: String) { write(name, text.toByteArray(Charsets.UTF_8), "application/json") }
    @JavascriptInterface fun saveB64(name: String, b64: String) { write(name, Base64.decode(b64, Base64.DEFAULT), "image/jpeg") }
    @JavascriptInterface fun notify(title: String, body: String) { post(title, body) }
  }

  private fun write(name: String, bytes: ByteArray, mime: String) {
    try {
      if (Build.VERSION.SDK_INT >= 29) {
        val cv = ContentValues()
        cv.put(MediaStore.MediaColumns.DISPLAY_NAME, name)
        cv.put(MediaStore.MediaColumns.MIME_TYPE, mime)
        cv.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS)
        val uri: Uri? = contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, cv)
        if (uri != null) contentResolver.openOutputStream(uri)?.use { it.write(bytes) }
      } else {
        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), name).writeBytes(bytes)
      }
    } catch (e: Exception) { }
  }

  private fun post(title: String, body: String) {
    try {
      val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
      if (Build.VERSION.SDK_INT >= 26) nm.createNotificationChannel(NotificationChannel("l360", "Life360", NotificationManager.IMPORTANCE_DEFAULT))
      val n = Notification.Builder(this, "l360")
        .setContentTitle(title)
        .setContentText(body)
        .setSmallIcon(android.R.drawable.ic_menu_mylocation)
        .setAutoCancel(true)
        .build()
      nm.notify((System.currentTimeMillis() % 100000).toInt(), n)
    } catch (e: Exception) { }
  }

  @SuppressLint("SetJavaScriptEnabled")
  override fun onCreate(state: Bundle?) {
    super.onCreate(state)

    RelayService.start(this)

    val w = WebView(this)
    w.settings.javaScriptEnabled = true
    w.settings.domStorageEnabled = true
    w.settings.mediaPlaybackRequiresUserGesture = false
    w.webViewClient = WebViewClient()
    w.addJavascriptInterface(Bridge(), "Android")
    w.loadUrl("file:///android_asset/index.html")
    web = w
    setContentView(w)
    RelayService.webView = w

    if (Build.VERSION.SDK_INT >= 33) {
      requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 1)
    }
  }

  override fun onBackPressed() {
    val w = web
    if (w != null && w.canGoBack()) w.goBack() else super.onBackPressed()
  }
}
