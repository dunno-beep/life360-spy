package com.you.life360monitor

import android.annotation.SuppressLint
import android.app.Activity
import android.os.Build
import android.os.Bundle
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient

class MainActivity : Activity() {

    private var web: WebView? = null

    inner class Bridge {
        @JavascriptInterface fun send(s: String) { RelayService.instance?.send(s) }
        @JavascriptInterface fun token(): String = BuildConfig.TOKEN
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
