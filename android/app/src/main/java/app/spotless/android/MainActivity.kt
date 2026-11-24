package app.spotless.android

import android.annotation.SuppressLint
import android.app.Activity
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.WindowInsets
import android.view.WindowManager
import android.view.inputmethod.EditorInfo
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.window.OnBackInvokedCallback
import android.window.OnBackInvokedDispatcher
import androidx.webkit.WebViewAssetLoader
import java.io.ByteArrayInputStream
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener
import uniffi.encore_ffi.CoreConfig
import uniffi.encore_ffi.EncoreCore
import uniffi.encore_ffi.EventListener

/** Android shell: local HTML/CSS/JS UI, bridged to the shared Rust music core. */
class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val pendingUiMessages = ArrayDeque<String>()
    private var pageReady = false
    private var coreReady = false
    private var coreUiMounted = false
    private var destroyed = false
    private var modalOpen = false
    private var systemBackCallback: OnBackInvokedCallback? = null
    private var core: EncoreCore? = null
    @Volatile private var currentTrack: JSONObject? = null
    private var searchJob: Job? = null
    private var lyricsJob: Job? = null
    private var browserSessionDialog: AlertDialog? = null
    private var loginJob: Job? = null
    private var loginGeneration = 0L
    private lateinit var webView: WebView

    private val assetLoader by lazy {
        WebViewAssetLoader.Builder()
            .addPathHandler("/", WebViewAssetLoader.AssetsPathHandler(this))
            .build()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window.statusBarColor = Color.rgb(16, 16, 16)
        window.navigationBarColor = Color.BLACK
        window.decorView.setBackgroundColor(Color.rgb(16, 16, 16))
        CoreHolder.onEvent = { name, json -> handleCoreEvent(name, json) }
        buildWebView()
        registerSystemBackCallback()
        startCore()
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun buildWebView() {
        webView = WebView(this).apply {
            setBackgroundColor(Color.rgb(16, 16, 16))
            settings.apply {
                javaScriptEnabled = true
                domStorageEnabled = true
                allowFileAccess = false
                allowContentAccess = false
                allowFileAccessFromFileURLs = false
                allowUniversalAccessFromFileURLs = false
                javaScriptCanOpenWindowsAutomatically = false
                setSupportMultipleWindows(false)
                userAgentString = "$userAgentString ZtunesAndroidWebView"
                mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_NEVER_ALLOW
                loadsImagesAutomatically = true
                blockNetworkImage = false
            }
            addJavascriptInterface(AndroidBridge(), "ZtunesBridge")
            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                    val uri = request.url
                    if (uri.scheme == "https" && uri.host == ASSET_HOST) {
                        return assetLoader.shouldInterceptRequest(uri) ?: blockedResponse()
                    }
                    // Network requests from the page are denied except for artwork hosts explicitly
                    // allowed by the HTML Content Security Policy.
                    if (request.method == "GET" && uri.scheme == "https" && uri.host in ARTWORK_HOSTS) {
                        return super.shouldInterceptRequest(view, request)
                    }
                    return blockedResponse()
                }

                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val uri = request.url
                    return !(uri.scheme == "https" && uri.host == ASSET_HOST && uri.path?.startsWith("/") == true)
                }

                override fun onReceivedError(
                    view: WebView,
                    request: WebResourceRequest,
                    error: android.webkit.WebResourceError,
                ) {
                    super.onReceivedError(view, request, error)
                    if (request.isForMainFrame) {
                        postUi("status", JSONObject().put("message", "The Ztunes interface could not load.").put("error", true).toString())
                    }
                }
            }
            loadUrl(ASSET_URL)
        }
        if (Build.VERSION.SDK_INT >= 35) {
            // Android 15 enforces edge-to-edge for target SDK 35; inset the local web UI beneath bars.
            webView.setOnApplyWindowInsetsListener { view, insets ->
                val systemBars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
                view.setPadding(systemBars.left, systemBars.top, systemBars.right, systemBars.bottom)
                insets
            }
        }
        setContentView(webView)
    }

    private fun blockedResponse() = WebResourceResponse(
        "text/plain", "UTF-8", 403, "Blocked by Ztunes", emptyMap(), ByteArrayInputStream(ByteArray(0)),
    )

    private fun mountCoreUiIfReady() {
        if (coreReady && pageReady && !coreUiMounted) {
            coreUiMounted = true
            core?.uiMounted()
        }
    }

    private fun startCore() {
        scope.launch {
            try {
                val engine = withContext(Dispatchers.IO) {
                    CoreHolder.get(applicationContext, filesDir.absolutePath, cacheDir.absolutePath)
                }
                core = engine
                coreReady = true
                mountCoreUiIfReady()
                postUi("android-core-ready", "{}")
                withContext(Dispatchers.IO) { engine.invoke("account_watch", "{}") }
                if (CoreHolder.sessionRejected) {
                    scope.launch {
                        delay(250)
                        if (CoreHolder.sessionRejected) postUi("session-rejected", "{}")
                    }
                }
                val snapshot = withContext(Dispatchers.IO) { engine.invoke("get_playback", "{}") }
                val now = JSONObject(snapshot).optJSONObject("now")
                currentTrack = now
                postUi("snapshot", snapshot)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                postUi("core-error", JSONObject().put("message", e.message ?: e.javaClass.simpleName).toString())
            } catch (e: LinkageError) {
                postUi("core-error", JSONObject().put("message", "Native audio libraries could not load.").toString())
            }
        }
    }

    private inner class AndroidBridge {
        @JavascriptInterface
        fun postMessage(action: String?, payloadJson: String?) {
            // Used only for readiness/back-stack hints from the bundled appassets page.
            val verb = action ?: return
            val raw = payloadJson ?: "{}"
            runOnUiThread {
                if (!trustedPage() || destroyed) return@runOnUiThread
                scope.launch { handleUiAction(verb, raw) }
            }
        }

        @JavascriptInterface
        fun invoke(requestId: String?, command: String?, argsJson: String?) {
            val id = requestId ?: return
            val cmd = command ?: return
            val raw = argsJson ?: "{}"
            runOnUiThread {
                if (!trustedPage() || destroyed) return@runOnUiThread
                scope.launch {
                    try {
                        val result = invokeAndroid(cmd, raw)
                        resolveToPage(id, true, result)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        resolveToPage(id, false, e.message ?: "Android request failed")
                    }
                }
            }
        }
    }

    private fun trustedPage(): Boolean = ::webView.isInitialized && webView.url?.startsWith(ASSET_ORIGIN) == true

    private suspend fun invokeAndroid(command: String, argsJson: String): String {
        val args = try { JSONObject(argsJson) } catch (_: JSONException) { JSONObject() }
        when (command) {
            // Google blocks embedded Android WebViews. Android therefore imports a user-supplied
            // browser session in a native password-style field; the credential never crosses JS.
            "login_webview" -> {
                showBrowserSessionImport(args.optBoolean("addAccount"))
                return "null"
            }
            "cancel_login" -> {
                cancelBrowserSessionImport()
                return "null"
            }
            "account_sign_in" -> throw IllegalStateException("Import a browser session from the native sign-in sheet.")
            "get_google_accounts" -> return "[]" // Saved Google-account switching is desktop-only.
            "switch_google_account", "remove_google_account" ->
                throw IllegalStateException("Saved Google-account switching is not available on Android.")
            "sign_out" -> cancelBrowserSessionImport()
            // Device output is managed by Android. Keep audio settings loadable, with no desktop
            // device list exposed to the phone UI.
            "audio_devices" -> return JSONObject().put("devices", org.json.JSONArray())
                .put("selected", "auto").put("active", "auto").toString()
            "set_audio_device" -> return JSONObject().put("devices", org.json.JSONArray())
                .put("selected", "auto").put("active", "auto").toString()
            "can_self_update" -> return "false"
            "log_ui" -> return "null"
            "theater_fullscreen", "open_mini", "close_mini", "set_mini_compact" -> return "null"
            "video_stream", "forget_video_stream" -> return "null"
            "get_global_hotkeys", "reset_global_hotkeys", "set_global_hotkeys" ->
                return JSONObject().put("enabled", false).put("bindings", JSONObject()).toString()
            "global_hotkeys_on_wayland" -> return "false"
            "title_bar_double_click" -> return JSONObject.quote("None")
            "open_external" -> {
                val rawUrl = args.optString("url")
                val uri = Uri.parse(rawUrl)
                if (uri.scheme !in setOf("https", "http")) throw IllegalArgumentException("Only web links can be opened externally")
                startActivity(Intent(Intent.ACTION_VIEW, uri))
                return "null"
            }
            "quit_app" -> {
                runOnUiThread { finish() }
                return "null"
            }
        }
        val engine = core ?: throw IllegalStateException("The Ztunes music engine is still starting.")
        return withContext(Dispatchers.IO) { engine.invoke(command, args.toString()) }
    }

    /** Show a native, obscured input: the session credential never enters the Svelte/WebView layer. */
    private fun showBrowserSessionImport(addAccount: Boolean) {
        if (!CoreHolder.hasSecureStore()) {
            postUi("login-error", JSONObject.quote("Android secure storage is unavailable, so Ztunes cannot save this account safely."))
            return
        }
        if (browserSessionDialog?.isShowing == true) return

        val density = resources.displayMetrics.density
        val pad = (18 * density).toInt()
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(pad, pad, pad, 0)
        }
        val instructions = TextView(this).apply {
            text = "On a computer, sign in to music.youtube.com in Chrome or Edge. In DevTools, open Network and reload the page. Select a /youtubei/v1/browse request, open Headers → Request Headers, and copy the Cookie value. Paste it below.\n\nYour Windows app's session is separate. This cookie is as sensitive as a password: do not share it or paste it into chat. Ztunes keeps it encrypted in Android Keystore. Browser sessions can expire and may need to be imported again."
            textSize = 14f
            setTextColor(Color.LTGRAY)
        }
        val input = EditText(this).apply {
            hint = "Cookie: SAPISID=…; SID=…"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_VARIATION_PASSWORD
            imeOptions = EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
            importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO
            isSaveEnabled = false
            minLines = 3
            maxLines = 6
            filters = arrayOf(android.text.InputFilter.LengthFilter(MAX_SESSION_HEADER_CHARS))
            setTextColor(Color.WHITE)
            setHintTextColor(Color.GRAY)
        }
        val scroll = ScrollView(this).apply {
            isFillViewport = false
            addView(instructions)
        }
        content.addView(scroll, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            (210 * density).toInt(),
        ))
        content.addView(input, LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ))

        val dialog = AlertDialog.Builder(this)
            .setTitle(if (addAccount) "Import another browser session" else "Import browser session")
            .setView(content)
            .setPositiveButton("Connect", null)
            .setNegativeButton("Cancel", null)
            .create()
        browserSessionDialog = dialog
        dialog.setOnDismissListener {
            input.text?.clear()
            if (browserSessionDialog === dialog) {
                browserSessionDialog = null
                postUi("login-cancelled", "null")
            }
        }
        dialog.setOnShowListener {
            dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
            dialog.window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_HIDDEN)
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val cookie = parseBrowserCookieHeader(input.text?.toString().orEmpty())
                if (cookie == null) {
                    input.error = "Paste a YouTube Cookie header with SAPISID or __Secure-3PAPISID."
                    return@setOnClickListener
                }
                // Clear the editable field before starting network work. The value is used only by
                // this native-to-Rust call; it is never dispatched to JavaScript or written to logs.
                input.text?.clear()
                browserSessionDialog = null
                dialog.dismiss()
                importBrowserSession(cookie)
            }
        }
        dialog.show()
        dialog.window?.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
    }

    private fun cancelBrowserSessionImport() {
        loginGeneration++
        loginJob?.cancel()
        loginJob = null
        val dialog = browserSessionDialog
        browserSessionDialog = null
        dialog?.dismiss()
        if (dialog != null) postUi("login-cancelled", "null")
    }

    private fun parseBrowserCookieHeader(input: String): String? {
        if (input.isBlank() || input.length > MAX_SESSION_HEADER_CHARS) return null
        val lines = input.replace("\r\n", "\n").replace('\r', '\n').lines()
        val cookieLine = lines.firstOrNull { it.trimStart().startsWith("cookie:", ignoreCase = true) }
        val source = cookieLine?.substringAfter(':') ?: input
        val pairs = source.split(';').mapNotNull { raw ->
            val pair = raw.trim()
            val equals = pair.indexOf('=')
            if (equals <= 0) return@mapNotNull null
            val name = pair.substring(0, equals).trim()
            val value = pair.substring(equals + 1).trim()
            if (!name.matches(Regex("[!#$%&'*+.^_`|~0-9A-Za-z-]+")) || value.any { it == '\n' || it == '\r' }) {
                return@mapNotNull null
            }
            name to value
        }
        if (pairs.none { (name, value) -> name in setOf("SAPISID", "__Secure-3PAPISID") && value.isNotEmpty() }) return null
        return pairs.joinToString("; ") { (name, value) -> "$name=$value" }
    }

    private fun importBrowserSession(cookie: String) {
        val engine = core ?: run {
            postUi("login-error", JSONObject.quote("The Ztunes music engine is not ready yet."))
            return
        }
        val generation = ++loginGeneration
        val args = JSONObject().put("cookie", cookie).put("expectAccount", JSONObject.NULL).toString()
        loginJob?.cancel()
        loginJob = scope.launch {
            try {
                val accountJson = withContext(Dispatchers.IO) { engine.invoke("account_sign_in", args) }
                if (generation != loginGeneration) return@launch
                val account = JSONObject(accountJson)
                if (!account.optBoolean("signedIn")) throw IllegalStateException("Account not confirmed")
                if (!account.optBoolean("selectionRequired")) postUi("login-done", "null")
            } catch (e: CancellationException) {
                throw e
            } catch (_: Exception) {
                if (generation == loginGeneration) {
                    // Never surface request internals that might contain credential-adjacent data.
                    postUi("login-error", JSONObject.quote("Ztunes could not verify this browser session. Re-import a fresh Cookie header and try again."))
                }
            } finally {
                if (generation == loginGeneration) loginJob = null
            }
        }
    }

    private suspend fun handleUiAction(action: String, raw: String) {
        val payload = try { JSONObject(raw) } catch (_: JSONException) { JSONObject() }
        when (action) {
            "ui-ready" -> {
                pageReady = true
                mountCoreUiIfReady()
                while (pendingUiMessages.isNotEmpty()) deliverToPage(pendingUiMessages.removeFirst())
            }
            "modal-open" -> { modalOpen = true; syncSystemBackCallback() }
            "modal-close" -> { modalOpen = false; syncSystemBackCallback() }
            "search" -> runSearch(payload.optString("query").trim())
            "play" -> play(payload)
            "toggle-pause" -> runCommand("toggle_pause")
            "next" -> runCommand("next_track")
            "lyrics" -> loadLyrics(payload.optJSONObject("track"))
            else -> Unit
        }
    }

    private suspend fun runSearch(query: String) {
        val engine = core
        if (engine == null) {
            postUi("core-error", JSONObject().put("message", "The music engine is not ready yet.").toString())
            return
        }
        if (query.isBlank()) {
            postUi("search-error", JSONObject().put("message", "Enter a song or artist to search.").toString())
            return
        }
        searchJob?.cancel()
        searchJob = scope.launch {
            postUi("search-start", "{}")
            try {
                val args = JSONObject().put("query", query).put("recordHistory", false).toString()
                val result = withContext(Dispatchers.IO) { engine.invoke("search_overview", args) }
                postUi("search-results", result)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                postUi("search-error", JSONObject().put("message", e.message ?: "Search failed. Check your connection.").toString())
            }
        }
    }

    private suspend fun play(payload: JSONObject) {
        val engine = core ?: run {
            postUi("core-error", JSONObject().put("message", "The music engine is not ready yet.").toString())
            return
        }
        val item = payload.optJSONObject("item") ?: run {
            postUi("playback-error", JSONObject().put("message", "That search result could not be played.").toString())
            return
        }
        val args = JSONObject().put("item", item)
        payload.optString("from").takeIf { it.isNotBlank() }?.let { args.put("from", it) }
        try {
            withContext(Dispatchers.IO) { engine.invoke("play", args.toString()) }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            postUi("playback-error", JSONObject().put("message", e.message ?: "Could not play this track.").toString())
        }
    }

    private suspend fun runCommand(command: String) {
        val engine = core ?: return
        try {
            withContext(Dispatchers.IO) { engine.invoke(command, "{}") }
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            postUi("playback-error", JSONObject().put("message", e.message ?: "Playback command failed.").toString())
        }
    }

    private suspend fun loadLyrics(trackFromPage: JSONObject?) {
        val engine = core ?: return
        val track = trackFromPage ?: currentTrack
        if (track == null) {
            postUi("lyrics-error", JSONObject().put("message", "Start a track before opening lyrics.").toString())
            return
        }
        val videoId = track.optString("videoId")
        if (videoId.isBlank()) {
            postUi("lyrics-error", JSONObject().put("message", "Lyrics are not available for this item.").toString())
            return
        }
        lyricsJob?.cancel()
        lyricsJob = scope.launch {
            postUi("lyrics-start", "{}")
            try {
                val args = JSONObject()
                    .put("videoId", videoId)
                    .put("title", track.optString("title", ""))
                    .put("artists", track.optString("artists", ""))
                    .put("searched", false)
                if (!track.isNull("album")) args.put("album", track.optString("album"))
                durationSeconds(track.optString("duration"))?.let { args.put("duration", it) }
                val result = withContext(Dispatchers.IO) { engine.invoke("get_lyrics", args.toString()) }
                if (currentTrack?.optString("videoId") == videoId) postUi("lyrics-result", result)
                else postUi("lyrics-error", JSONObject().put("message", "The track changed while lyrics were loading.").toString())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                postUi("lyrics-error", JSONObject().put("message", e.message ?: "Could not load lyrics.").toString())
            }
        }
    }

    private fun durationSeconds(value: String): Double? {
        val pieces = value.trim().split(":")
        if (pieces.size !in 2..3) return null
        var total = 0L
        for (piece in pieces) {
            val n = piece.toLongOrNull() ?: return null
            if (n < 0) return null
            total = total * 60 + n
        }
        return total.toDouble().takeIf { it > 0 }
    }

    private fun handleCoreEvent(name: String, json: String) {
        if (destroyed) return
        if (name == "now-playing") {
            currentTrack = if (json == "null") null else runCatching { JSONObject(json) }.getOrNull()
        }
        // Forward the complete core event stream. The UI's Tauri event shim fans it out to the
        // existing Windows/Svelte components without translating their payloads.
        postUi(name, json)
    }

    /** Data stays JSON-encoded across the bridge; UI code renders labels as text, never HTML. */
    private fun postUi(type: String, payloadJson: String) {
        val script = "window.__ZTUNES_ANDROID_BRIDGE__?.dispatch(${JSONObject.quote(type)}, ${JSONObject.quote(payloadJson)});"
        runOnUiThread {
            if (destroyed) return@runOnUiThread
            if (pageReady) deliverToPage(script) else pendingUiMessages.addLast(script)
        }
    }

    private fun resolveToPage(id: String, success: Boolean, value: String) {
        if (!trustedPage() || destroyed) return
        val script = "window.__ZTUNES_ANDROID_BRIDGE__?.resolve(${JSONObject.quote(id)}, $success, ${JSONObject.quote(value)});"
        webView.evaluateJavascript(script, null)
    }

    private fun deliverToPage(script: String) {
        if (!trustedPage() || destroyed) return
        webView.evaluateJavascript(script, null)
    }

    private fun registerSystemBackCallback() {
        if (Build.VERSION.SDK_INT < 33 || systemBackCallback != null) return
        val callback = OnBackInvokedCallback { dispatchSystemBack() }
        onBackInvokedDispatcher.registerOnBackInvokedCallback(OnBackInvokedDispatcher.PRIORITY_DEFAULT, callback)
        systemBackCallback = callback
    }

    private fun syncSystemBackCallback() {
        // Keep a single activity-level callback installed; the JS shell decides whether Escape,
        // route back, or activity exit is appropriate for the current layer.
        registerSystemBackCallback()
    }

    private fun dispatchSystemBack() {
        if (!trustedPage() || destroyed) {
            finish()
            return
        }
        webView.evaluateJavascript("window.__ZTUNES_ANDROID_BRIDGE__?.handleBack?.() ?? false;") { handled ->
            if (handled != "true") runOnUiThread { if (!destroyed) finish() }
        }
    }

    override fun onBackPressed() {
        dispatchSystemBack()
    }

    override fun onPause() {
        if (::webView.isInitialized) webView.onPause()
        super.onPause()
    }

    override fun onResume() {
        super.onResume()
        if (::webView.isInitialized) webView.onResume()
    }

    override fun onDestroy() {
        destroyed = true
        modalOpen = false
        if (Build.VERSION.SDK_INT >= 33) systemBackCallback?.let {
            onBackInvokedDispatcher.unregisterOnBackInvokedCallback(it)
            systemBackCallback = null
        }
        browserSessionDialog?.dismiss()
        browserSessionDialog = null
        loginJob?.cancel()
        CoreHolder.onEvent = null
        scope.cancel()
        if (::webView.isInitialized) {
            webView.removeJavascriptInterface("ZtunesBridge")
            webView.stopLoading()
            webView.destroy()
        }
        super.onDestroy()
    }

    private companion object {
        const val ASSET_HOST = "appassets.androidplatform.net"
        const val ASSET_ORIGIN = "https://appassets.androidplatform.net/"
        const val ASSET_URL = "https://appassets.androidplatform.net/index.html"
        const val MAX_SESSION_HEADER_CHARS = 32 * 1024
        val ARTWORK_HOSTS = setOf("i.ytimg.com", "lh3.googleusercontent.com", "yt3.ggpht.com")
    }
}

/** One Rust core per process, so returning from Android UI doesn't start another player/database. */
private object CoreHolder {
    @Volatile var onEvent: ((String, String) -> Unit)? = null
    @Volatile var sessionRejected: Boolean = false
    private var instance: EncoreCore? = null
    private var secretStore: AndroidKeystoreSecretStore? = null
    private val listener = object : EventListener {
        override fun onEvent(name: String, json: String) {
            when (name) {
                "session-rejected" -> sessionRejected = true
                "auth-changed", "account-selection-required" -> sessionRejected = false
            }
            onEvent?.invoke(name, json)
        }
    }

    @Synchronized
    fun hasSecureStore(): Boolean = secretStore != null

    @Synchronized
    fun get(context: Context, data: String, cache: String): EncoreCore {
        instance?.let { return it }
        // Keep playback/search available if Keystore initialization fails, but never enable account
        // import without the encrypted store.
        secretStore = try {
            AndroidKeystoreSecretStore(context.applicationContext)
        } catch (_: Exception) {
            null
        }
        return EncoreCore(CoreConfig(data, cache, null), listener, secretStore).also { instance = it }
    }
}
