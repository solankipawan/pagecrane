package com.theairsolanki.pagecrane

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var openChannel: MethodChannel? = null

    /** A PDF opened before Dart was listening (cold start); Dart takes it once. */
    private var pending: Map<String, Any?>? = null
    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        // "Open Settings" from the camera-permission card: Pagecrane's own app page.
        MethodChannel(messenger, "pagecrane/system").setMethodCallHandler { call, result ->
            if (call.method == "openAppSettings") {
                val intent = Intent(
                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.fromParts("package", packageName, null),
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                result.success(true)
            } else {
                result.notImplemented()
            }
        }

        // PDFs opened from other apps ("Open with Pagecrane").
        openChannel = MethodChannel(messenger, "pagecrane/open").also { ch ->
            ch.setMethodCallHandler { call, result ->
                if (call.method == "takePending") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        io.shutdown()
        super.onDestroy()
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action != Intent.ACTION_VIEW) return
        val uri = intent.data ?: return
        // Consume it so a rotation / recreation doesn't open the same file again.
        intent.action = Intent.ACTION_MAIN
        intent.data = null
        io.execute {
            val event = try {
                val (path, name) = copyIncoming(uri)
                mapOf("path" to path, "name" to name)
            } catch (e: IncomingPdfException) {
                mapOf("error" to e.message)
            } catch (e: Exception) {
                mapOf("error" to "Couldn’t open this file.")
            }
            main.post { deliver(event) }
        }
    }

    private fun deliver(event: Map<String, Any?>) {
        val ch = openChannel
        if (ch == null) {
            pending = event
            return
        }
        // Dart may not be listening yet on a cold start: keep it for takePending.
        pending = event
        ch.invokeMethod("opened", event, object : MethodChannel.Result {
            override fun success(result: Any?) {
                if (pending === event) pending = null
            }
            override fun error(code: String, msg: String?, details: Any?) {}
            override fun notImplemented() {}
        })
    }

    /**
     * Copies an incoming PDF into the app cache and returns (path, displayName).
     * Untrusted input: only content:// URIs from other apps, at most [MAX_BYTES],
     * must start with "%PDF-"; the shown name is sanitised and never used as a path.
     */
    private fun copyIncoming(uri: Uri): Pair<String, String> {
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) {
            // file:// could point at our own private files (confused deputy).
            throw IncomingPdfException("This file can’t be opened from here.")
        }
        if (uri.authority?.startsWith(packageName) == true) {
            throw IncomingPdfException("This file can’t be opened from here.")
        }
        val dir = File(cacheDir, "incoming").apply { mkdirs() }
        // Keep only the latest few opened files.
        dir.listFiles()?.sortedBy { it.lastModified() }?.dropLast(4)?.forEach { it.delete() }

        val out = File(dir, "${UUID.randomUUID()}.pdf")
        var total = 0L
        try {
            contentResolver.openInputStream(uri).use { input ->
                input ?: throw IncomingPdfException("Couldn’t read this file.")
                out.outputStream().use { output ->
                    val buf = ByteArray(64 * 1024)
                    var first = true
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        if (first) {
                            first = false
                            val head = String(buf, 0, minOf(n, 1024), Charsets.ISO_8859_1)
                            if (!head.contains("%PDF-")) {
                                throw IncomingPdfException("This file isn’t a PDF.")
                            }
                        }
                        total += n
                        if (total > MAX_BYTES) {
                            throw IncomingPdfException("This PDF is too large to open (over 200 MB).")
                        }
                        output.write(buf, 0, n)
                    }
                }
            }
            if (total == 0L) throw IncomingPdfException("This file is empty.")
        } catch (e: Exception) {
            out.delete()
            throw e
        }
        return out.absolutePath to displayName(uri)
    }

    private fun displayName(uri: Uri): String {
        var name: String? = null
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { c -> if (c.moveToFirst()) name = c.getString(0) }
        } catch (_: Exception) {}
        val clean = (name ?: "Document")
            .replace(Regex("(?i)\\.pdf$"), "")
            .replace(Regex("[\\p{Cntrl}\\u202A-\\u202E\\u2066-\\u2069/\\\\:*?\"<>|]+"), " ")
            .trim()
            .take(120)
        return clean.ifEmpty { "Document" }
    }

    private class IncomingPdfException(message: String) : Exception(message)

    companion object {
        private const val MAX_BYTES = 200L * 1024 * 1024
    }
}
