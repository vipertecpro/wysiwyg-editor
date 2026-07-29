package com.vipertecpro.plugins.wysiwyg_editor

// =============================================================================
// WysiwygEditor — Android native rich text editor
// =============================================================================
//
// A configurable, fully-native WYSIWYG editor. NOT a webview: the document is
// an Android `Editable` with spans, edited in a real EditText, wrapped in a
// Compose screen that supplies the chrome.
//
// Layout (top → bottom): [Cancel | title | Save] · editor · counter ·
// formatting toolbar pinned above the keyboard (undo/redo, then the tools the
// host configured, in order).
//
// On "Save" the document is serialized to the plugin's normalised HTML (plus a
// plain-text rendition) and returned via the `ContentSaved` event. Mirrors the
// iOS implementation exactly — the HTML contract in the README is normative for
// both, and the toolbar icons are the SAME hand-drawn vector paths, so the two
// platforms render an identical toolbar.
// =============================================================================

import android.app.AlertDialog
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.ViewGroup
import android.widget.FrameLayout
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicText
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.ComposeView
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.fragment.app.FragmentActivity
import com.nativephp.mobile.bridge.BridgeFunction
import com.nativephp.mobile.utils.NativeActionCoordinator
import org.json.JSONArray
import org.json.JSONObject

object WysiwygEditorFunctions {

    private const val TAG = "WysiwygEditor"
    private const val EVENT_SAVED = "Vipertecpro\\WysiwygEditor\\Events\\ContentSaved"
    private const val EVENT_CANCELLED = "Vipertecpro\\WysiwygEditor\\Events\\EditCancelled"
    private const val EVENT_MEDIA = "Vipertecpro\\WysiwygEditor\\Events\\MediaRequested"
    private const val EVENT_CHANGED = "Vipertecpro\\WysiwygEditor\\Events\\ContentChanged"

    /** The four surfaces the editor colours. */
    val THEME_KEYS = listOf("background", "text", "accent", "highlight")

    /** Every tool the toolbar can show, in the order the `full` preset uses. */
    val AVAILABLE_TOOLS = listOf(
        "bold", "italic", "underline", "strikethrough",
        "h1", "h2", "h3",
        "bulletList", "orderedList", "blockquote",
        "link", "code", "textColor", "highlight",
        "image", "video", "file",
        "clearFormat",
    )

    /** Toolbar tools that ask the HOST for media rather than formatting text. */
    val INSERT_TOOLS = listOf("image", "video", "file")

    /**
     * Host-app theme overrides. Every color is optional: null falls back to the
     * editor's built-in system-adaptive default, so the editor blends into ANY
     * app — the host decides, not the plugin. Mirrors the iOS WysiwygTheme.
     */
    data class EditorTheme(
        val background: Color? = null,  // editor screen background
        val text: Color? = null,        // body text, titles, inactive icons
        val accent: Color? = null,      // the Save button
        val highlight: Color? = null,   // active states (toggled tools, selection)
        // The HOST app's palette per colour scheme, resolved in PHP from its
        // NativeUI theme tokens. Used when the caller gave no explicit colour,
        // so an unconfigured editor still looks like part of the app.
        val light: Map<String, Color> = emptyMap(),
        val dark: Map<String, Color> = emptyMap(),
    ) {
        private fun host(key: String, night: Boolean): Color? =
            (if (night) dark else light)[key]

        fun backgroundColor(night: Boolean): Color = background
            ?: host("background", night)
            ?: if (night) Color(0xFF0B0B0C) else Color(0xFFFFFFFF)

        fun textColor(night: Boolean): Color = text
            ?: host("text", night)
            ?: if (night) Color(0xFFF5F5F7) else Color(0xFF111113)

        fun accentColor(night: Boolean): Color = accent
            ?: host("accent", night)
            ?: Color(0.92f, 0.47f, 0.18f)

        fun highlightColor(night: Boolean): Color = highlight
            ?: host("highlight", night)
            ?: Color(0xFF22C55E)
    }

    data class EditorConfig(
        val content: String,
        val toolbar: List<String>,
        val title: String,
        val placeholder: String,
        val maxLength: Int,
        val counts: List<String>,
        val menu: String,
        val typography: WysiwygTypography,
        val spacing: WysiwygSpacing,
        val validation: Map<String, Any>,
        val strings: Map<String, String>,
        val changeDebounce: Int,
        val haptics: Boolean,
        val theme: EditorTheme,
        val id: String?,
    )

    /**
     * The editor currently on screen. InsertMedia / UpdateUpload arrive as
     * separate bridge calls while the editor is open, so they need a way to
     * reach it. Cleared when the editor closes.
     */
    internal var live: LiveEditor? = null

    /** What the open editor exposes to the media bridge functions. */
    internal interface LiveEditor {
        fun insertMedia(kind: String, attrs: Map<String, String>)
        fun updateUpload(uploadId: String, state: String, src: String, message: String)
    }

    /**
     * Insert a media block at the caret. The host calls this after picking
     * (and optionally cropping) the media — the editor never opens a picker.
     */
    class InsertMedia(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val kind = parameters["kind"] as? String ?: return emptyMap()
            val attrs = mutableMapOf<String, String>()
            when (val raw = parameters["attributes"]) {
                is Map<*, *> -> raw.forEach { (k, v) ->
                    if (k is String && v is String) attrs[k] = v
                }
                is JSONObject -> raw.keys().forEach { k ->
                    raw.optString(k).takeIf { it.isNotEmpty() }?.let { attrs[k] = it }
                }
            }
            Handler(Looper.getMainLooper()).post { live?.insertMedia(kind, attrs) }
            return emptyMap()
        }
    }

    /** Report upload progress / completion / failure for an inserted block. */
    class UpdateUpload(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val uploadId = parameters["uploadId"] as? String ?: return emptyMap()
            val state = parameters["state"] as? String ?: "progress"
            val src = parameters["src"] as? String ?: ""
            val message = parameters["message"] as? String ?: ""
            Handler(Looper.getMainLooper()).post {
                live?.updateUpload(uploadId, state, src, message)
            }
            return emptyMap()
        }
    }

    class Open(private val activity: FragmentActivity) : BridgeFunction {
        override fun execute(parameters: Map<String, Any>): Map<String, Any> {
            val requested = parseStringList(parameters["toolbar"]).filter { AVAILABLE_TOOLS.contains(it) }

            val config = EditorConfig(
                content = parameters["content"] as? String ?: "",
                // An empty/unknown toolbar would ship a bar with no buttons —
                // fall back to everything rather than render a dead strip.
                toolbar = requested.distinct().ifEmpty { AVAILABLE_TOOLS },
                title = parameters["title"] as? String ?: "",
                placeholder = parameters["placeholder"] as? String ?: "",
                maxLength = ((parameters["maxLength"] as? Number)?.toInt() ?: 0).coerceAtLeast(0),
                counts = parseStringList(parameters["counts"]),
                menu = (parameters["menu"] as? String) ?: "toolbar",
                typography = parseTypography(parameters["typography"]),
                spacing = WysiwygSpacing.named((parameters["spacing"] as? String) ?: "comfortable"),
                validation = parseValidation(parameters["validation"]),
                strings = parseStringMap(parameters["strings"]),
                changeDebounce = ((parameters["changeDebounce"] as? Number)?.toInt() ?: 0).coerceAtLeast(0),
                haptics = parameters["haptics"] as? Boolean ?: true,
                theme = parseTheme(parameters["theme"]).copy(
                    light = parseThemeMap(parameters["themeLight"]),
                    dark = parseThemeMap(parameters["themeDark"]),
                ),
                id = parameters["id"] as? String,
            )

            Handler(Looper.getMainLooper()).post {
                try {
                    present(config)
                } catch (e: Exception) {
                    Log.e(TAG, "open failed: ${e.message}", e)
                    dispatch(EVENT_CANCELLED, config.id)
                }
            }

            return emptyMap()
        }

        private fun present(config: EditorConfig) {
            val root = activity.findViewById<ViewGroup>(android.R.id.content)
            val overlayTag = "wysiwyg_editor_overlay"

            // Re-entrancy guard: never stack two editors (e.g. a double tap).
            if (root.findViewWithTag<android.view.View>(overlayTag) != null) {
                dispatch(EVENT_CANCELLED, config.id)
                return
            }

            val night = (activity.resources.configuration.uiMode and
                android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
                android.content.res.Configuration.UI_MODE_NIGHT_YES

            // The document is parsed ONCE here; the same block list seeds the
            // editor and is the baseline the discard check compares against.
            val initialBlocks = HtmlCoder.parse(config.content)
            val initialHtml = HtmlCoder.serialize(initialBlocks).first

            val view = ComposeView(activity).apply {
                tag = overlayTag
                layoutParams = FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
                // Opaque overlay — otherwise the screen underneath shows through.
                setBackgroundColor(config.theme.backgroundColor(night).toArgb())
                isClickable = true // swallow touches meant for the editor
            }

            // Lock orientation while the editor is up. A config-change would
            // destroy this programmatically-added overlay and its Compose
            // state, leaving the PHP side waiting for an event that never comes.
            val prevOrientation = activity.requestedOrientation
            activity.requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LOCKED

            // Deliver EXACTLY ONE terminal event: Save racing Cancel, a double
            // tap, or a Back press can otherwise fire two events — or none.
            val finished = java.util.concurrent.atomic.AtomicBoolean(false)

            // The auto-save seam: emit ContentChanged once the user stops
            // typing, so the host can persist a draft without the editor
            // owning drafts itself. Off unless changeDebounce > 0.
            val changeHandler = Handler(Looper.getMainLooper())
            var pendingChange: Runnable? = null
            lateinit var backCallback: androidx.activity.OnBackPressedCallback

            fun cleanup() {
                pendingChange?.let(changeHandler::removeCallbacks)
                (view.parent as? ViewGroup)?.removeView(view)
                activity.requestedOrientation = prevOrientation
                backCallback.remove()
            }

            fun finishCancelled() {
                if (finished.compareAndSet(false, true)) {
                    cleanup()
                    dispatch(EVENT_CANCELLED, config.id)
                }
            }

            fun finishSaved(html: String, text: String, json: String) {
                if (finished.compareAndSet(false, true)) {
                    cleanup()
                    dispatch(EVENT_SAVED, config.id, html, text, json)
                }
            }

            // Holds the live document so Cancel/Save can read it without the
            // Compose tree having to hoist it back up on every keystroke.
            val documentRef = mutableStateOf<List<WysiwygBlock>>(initialBlocks)

            fun scheduleChangeEvent() {
                if (config.changeDebounce <= 0) return
                pendingChange?.let(changeHandler::removeCallbacks)
                val runnable = Runnable {
                    if (finished.get()) return@Runnable
                    val document = documentRef.value
                    val (html, text) = HtmlCoder.serialize(document)
                    dispatch(EVENT_CHANGED, config.id, html, text, JsonCoder.encode(document))
                }
                pendingChange = runnable
                changeHandler.postDelayed(runnable, config.changeDebounce.toLong())
            }

            /** Cancel path — confirm first when the document actually changed. */
            fun attemptCancel() {
                val current = HtmlCoder.serialize(documentRef.value).first
                if (current == initialHtml) {
                    finishCancelled()
                    return
                }
                AlertDialog.Builder(activity)
                    .setTitle(localized(config.strings, "discardTitle", "Discard changes?"))
                    .setMessage(localized(config.strings, "discardMessage", "Your edits will be lost."))
                    .setPositiveButton(localized(config.strings, "discard", "Discard")) { _, _ ->
                        finishCancelled()
                    }
                    .setNegativeButton(localized(config.strings, "keepEditing", "Keep Editing"), null)
                    .setCancelable(true)
                    .show()
            }

            // System BACK → same as Cancel, so it can never orphan the overlay.
            backCallback = object : androidx.activity.OnBackPressedCallback(true) {
                override fun handleOnBackPressed() = attemptCancel()
            }
            activity.onBackPressedDispatcher.addCallback(backCallback)

            view.setContent {
                EditorScreen(
                    activity = activity,
                    config = config,
                    initialBlocks = initialBlocks,
                    onDocumentChanged = {
                        documentRef.value = it
                        scheduleChangeEvent()
                    },
                    onCancel = { attemptCancel() },
                    onSave = {
                        val document = documentRef.value
                        val problem = validateDocument(document, config.validation, config.strings)
                        if (problem != null) {
                            // Blocked natively — a failing document never makes
                            // the round-trip to PHP just to be rejected.
                            AlertDialog.Builder(activity)
                                .setTitle(localized(config.strings, "cannotSaveTitle", "Cannot save yet"))
                                .setMessage(problem)
                                .setPositiveButton(localized(config.strings, "ok", "OK"), null)
                                .show()
                        } else {
                            val (html, text) = HtmlCoder.serialize(document)
                            finishSaved(html, text, JsonCoder.encode(document))
                        }
                    },
                    onRequestMedia = { kind -> requestMedia(kind, config.id) },
                )
            }

            root.addView(view)
        }

        private fun dispatch(
            event: String,
            id: String?,
            html: String? = null,
            text: String? = null,
            json: String? = null,
        ) {
            val payload = JSONObject().apply {
                html?.let { put("html", it) }
                text?.let { put("text", it) }
                json?.let { put("json", it) }
                id?.let { put("id", it) }
            }
            NativeActionCoordinator.dispatchEvent(activity, event, payload.toString())
        }

        /** Ask the HOST to pick media — the editor ships no picker. */
        private fun requestMedia(kind: String, id: String?) {
            val payload = JSONObject().apply {
                put("kind", kind)
                id?.let { put("id", it) }
            }
            NativeActionCoordinator.dispatchEvent(activity, EVENT_MEDIA, payload.toString())
        }
    }
}

// ── Config parsing ──────────────────────────────────────────────────────────

private fun parseStringList(any: Any?): List<String> = when (any) {
    is List<*> -> any.mapNotNull { it as? String }
    is JSONArray -> (0 until any.length()).mapNotNull { i -> any.optString(i).takeIf { it.isNotEmpty() } }
    else -> emptyList()
}

/**
 * Type settings.
 *
 * The heading ramp is DERIVED from the body size with fixed multipliers rather
 * than configured separately, so a host that wants larger text sets one number
 * and the proportions hold. The multipliers are normative — Swift uses the
 * same three — and the default base of 16 reproduces the 28 / 22 / 18 ramp the
 * editor used before the option existed.
 */
class WysiwygTypography(
    val fontFamily: String = "",
    val base: Int = 16,
    val lineHeight: Float = 1.15f,
) {
    fun size(type: String): Int = when (type) {
        "h1" -> Math.round(base * 1.75f)
        "h2" -> Math.round(base * 1.375f)
        "h3" -> Math.round(base * 1.125f)
        else -> base
    }

    /**
     * The host app's font, or null for the platform default. A theme naming a
     * font the app never bundled must not leave the editor with no text, and
     * Typeface.create falls back to the default on its own.
     */
    fun typeface(): android.graphics.Typeface? =
        if (fontFamily.isEmpty()) {
            null
        } else {
            android.graphics.Typeface.create(fontFamily, android.graphics.Typeface.NORMAL)
        }
}

/** Editing density. dp here, points on iOS — the same numbers either way. */
class WysiwygSpacing(val horizontal: Int, val vertical: Int, val paragraph: Int) {
    companion object {
        fun named(name: String): WysiwygSpacing = when (name) {
            "compact" -> WysiwygSpacing(12, 8, 4)
            "roomy" -> WysiwygSpacing(20, 18, 10)
            else -> WysiwygSpacing(16, 12, 6)
        }
    }
}

private fun parseTypography(any: Any?): WysiwygTypography {
    val map = parseValidation(any)

    return WysiwygTypography(
        fontFamily = (map["fontFamily"] as? String) ?: "",
        base = (map["fontSize"] as? Number)?.toInt() ?: 16,
        lineHeight = (map["lineHeight"] as? Number)?.toFloat() ?: 1.15f,
    )
}

private fun parseStringMap(any: Any?): Map<String, String> = when (any) {
    is Map<*, *> -> any.entries.mapNotNull { (k, v) ->
        if (k is String && v is String) k to v else null
    }.toMap()
    is JSONObject -> any.keys().asSequence().mapNotNull { key ->
        any.optString(key).takeIf { it.isNotEmpty() }?.let { key to it }
    }.toMap()
    else -> emptyMap()
}

private fun parseValidation(any: Any?): Map<String, Any> = when (any) {
    is Map<*, *> -> any.entries.mapNotNull { (k, v) ->
        if (k is String && v != null) k to v else null
    }.toMap()
    is JSONObject -> any.keys().asSequence().mapNotNull { key ->
        when (val value = any.opt(key)) {
            is JSONArray -> key to (0 until value.length()).mapNotNull { value.optString(it).takeIf(String::isNotEmpty) }
            null -> null
            else -> key to value
        }
    }.toMap()
    else -> emptyMap()
}

private fun parseTheme(any: Any?): WysiwygEditorFunctions.EditorTheme = when (any) {
    is Map<*, *> -> WysiwygEditorFunctions.EditorTheme(
        background = parseHexColor(any["background"]),
        text = parseHexColor(any["text"]),
        accent = parseHexColor(any["accent"]),
        highlight = parseHexColor(any["highlight"]),
    )
    is JSONObject -> WysiwygEditorFunctions.EditorTheme(
        background = parseHexColor(any.optString("background").takeIf { it.isNotEmpty() }),
        text = parseHexColor(any.optString("text").takeIf { it.isNotEmpty() }),
        accent = parseHexColor(any.optString("accent").takeIf { it.isNotEmpty() }),
        highlight = parseHexColor(any.optString("highlight").takeIf { it.isNotEmpty() }),
    )
    else -> WysiwygEditorFunctions.EditorTheme()
}

/** One colour-scheme palette from PHP: editor key → colour. */
private fun parseThemeMap(any: Any?): Map<String, Color> {
    val source: Map<*, *> = when (any) {
        is Map<*, *> -> any
        is JSONObject -> any.keys().asSequence().associateWith { any.opt(it) }
        else -> return emptyMap()
    }

    val out = mutableMapOf<String, Color>()
    for (key in WysiwygEditorFunctions.THEME_KEYS) {
        parseHexColor(source[key])?.let { out[key] = it }
    }
    return out
}

/** #RGB / #RRGGBB / #RRGGBBAA (leading '#' optional) → Compose Color, or null. */
private fun parseHexColor(value: Any?): Color? {
    var s = (value as? String)?.trim()?.removePrefix("#") ?: return null
    if (s.length == 3) s = s.map { "$it$it" }.joinToString("")
    if (s.length != 6 && s.length != 8) return null
    val v = s.toLongOrNull(16) ?: return null
    return if (s.length == 6) {
        Color(((0xFF000000L or v).toInt()))
    } else {
        // #RRGGBBAA on the wire → 0xAARRGGBB for Compose.
        val rgb = (v ushr 8) and 0xFFFFFF
        val a = v and 0xFF
        Color((((a shl 24) or rgb).toInt()))
    }
}

// ── Document model ──────────────────────────────────────────────────────────

/**
 * The inline marks of one run of text, in a serialization-friendly form.
 * Nesting order (outermost → innermost) is fixed by the HTML contract:
 * link → color → highlight → strong → em → u → s → code.
 */
internal data class MarkSet(
    val link: String? = null,
    val color: String? = null,      // "#RRGGBB"
    val highlight: String? = null,  // "#RRGGBB"
    val bold: Boolean = false,
    val italic: Boolean = false,
    val underline: Boolean = false,
    val strike: Boolean = false,
    val code: Boolean = false,
) {
    val isPlain: Boolean get() = this == MarkSet()
}

/** Mutable accumulator used while parsing (marks nest, so they stack up). */
internal class MarkBuilder {
    var link: String? = null
    var color: String? = null
    var highlight: String? = null
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var code = false

    fun build() = MarkSet(link, color, highlight, bold, italic, underline, strike, code)
}

internal data class WysiwygRun(val text: String, val marks: MarkSet)

/** A poll choice. Ids are stable so a host can attribute votes to an option. */
internal data class PollOption(val id: String, val label: String)

/**
 * One block of the document.
 *
 * TEXT blocks (p/h1-h3/ul/ol/blockquote) carry [runs] and are exactly the v1
 * model. MEDIA blocks (image/video/file/embed/poll/divider) carry [attrs]
 * instead — a flat string map rather than a field per type, so adding a block
 * type does not ripple through both platforms' serializers.
 *
 * [id] is stable for the block's lifetime and exists so hosts can map upload
 * progress or comments to a specific block. It never appears in HTML.
 */
internal class WysiwygBlock(
    var type: String,
    val runs: MutableList<WysiwygRun> = mutableListOf(),
    var id: String = "",
    val attrs: MutableMap<String, String> = mutableMapOf(),
    val options: MutableList<PollOption> = mutableListOf(),
) {
    val isEmpty: Boolean get() = runs.all { it.text.isEmpty() }
    val plainText: String get() = runs.joinToString("") { it.text }
    val isText: Boolean get() = KNOWN_TYPES.contains(type)

    companion object {
        val KNOWN_TYPES = setOf("p", "h1", "h2", "h3", "ul", "ol", "blockquote")
        val MEDIA_TYPES = setOf("image", "video", "file", "embed", "poll", "divider")

        /** Attribute keys per media type, in SERIALIZATION order (normative). */
        val MEDIA_ATTRS = mapOf(
            "image" to listOf("src", "localPath", "alt", "caption", "width", "height", "uploadId"),
            "video" to listOf("src", "localPath", "poster", "caption", "uploadId"),
            "file" to listOf("src", "localPath", "name", "size", "mime", "uploadId"),
            "embed" to listOf("url", "provider", "html"),
            "poll" to listOf("question", "multiple", "closesAt"),
            "divider" to listOf(),
        )
    }
}

// ── HTML coder ──────────────────────────────────────────────────────────────

/**
 * Hand-written HTML parser + serializer implementing the plugin's normative
 * HTML contract (see README). Both directions are pure functions over
 * `List<WysiwygBlock>` so the round-trip is deterministic and identical to the
 * iOS implementation. `Html.fromHtml` is deliberately NOT used — it is lossy
 * and would not agree with iOS.
 */
internal object HtmlCoder {

    // ── parse ───────────────────────────────────────────────────────────────

    /**
     * Tolerant scanner: aliases normalised (b→strong, i→em, del/strike→s,
     * div→p, h4-h6→h3), <br> splits blocks, unknown tags ignored (text kept),
     * <script>/<style> skipped entirely, inter-block whitespace ignored,
     * entities decoded, unsafe link schemes dropped (text kept).
     */
    fun parse(html: String): MutableList<WysiwygBlock> {
        val blocks = mutableListOf<WysiwygBlock>()
        var current: WysiwygBlock? = null
        var openedByBr = false
        val listStack = mutableListOf<String>()
        val markStack = mutableListOf<Pair<String, (MarkBuilder) -> Unit>>()
        // The media block currently being assembled from a <figure>, if any.
        var mediaBlock: WysiwygBlock? = null
        var inFigcaption = false
        val n = html.length
        var i = 0

        fun marksNow(): MarkSet {
            val builder = MarkBuilder()
            markStack.forEach { it.second(builder) }
            return builder.build()
        }

        // Unconditionally append the open block (used by <br>, which WANTS
        // intentional empty blocks committed).
        fun commit() {
            current?.let { blocks.add(it) }
            current = null
            openedByBr = false
        }

        // Close the open block, dropping a still-empty block that only exists
        // because a <br> split opened it (so `<p>x<br></p>` is one block).
        fun closeBlock() {
            if (openedByBr && (current?.isEmpty != false)) {
                current = null
                openedByBr = false
            } else {
                commit()
            }
        }

        fun open(type: String, byBr: Boolean = false) {
            closeBlock()
            current = WysiwygBlock(type)
            openedByBr = byBr
        }

        fun appendText(decoded: String) {
            val text = collapseWhitespace(decoded)
            val media = mediaBlock
            if (media != null) {
                // Inside a <figure>: only the caption is content; anything else
                // (whitespace between the img and figcaption) is layout noise.
                if (inFigcaption) media.attrs["caption"] = media.attrs["caption"].orEmpty() + text
                return
            }
            if (current == null) {
                // No open block: whitespace between blocks is ignored; real
                // text opens an implicit paragraph (tolerance).
                if (text.isBlank()) return
                open("p")
            }
            if (text.isEmpty()) return
            val marks = marksNow()
            val block = current ?: return
            val last = block.runs.lastOrNull()
            if (last != null && last.marks == marks) {
                block.runs[block.runs.size - 1] = WysiwygRun(last.text + text, marks)
            } else {
                block.runs.add(WysiwygRun(text, marks))
            }
        }

        /** Skip everything up to (and including) `</tag …>` — script/style. */
        fun skipRawContent(tag: String) {
            val closing = "</$tag"
            val at = html.indexOf(closing, startIndex = i, ignoreCase = true)
            if (at < 0) {
                i = n
                return
            }
            var j = at
            while (j < n && html[j] != '>') j++
            i = minOf(j + 1, n)
        }

        fun canonicalInline(name: String): String = when (name) {
            "b" -> "strong"
            "i" -> "em"
            "del", "strike" -> "s"
            else -> name
        }

        fun handleOpen(name: String, attrText: String) {
            when (name) {
                "script", "style" -> skipRawContent(name)
                "br" -> {
                    val type = current?.type ?: "p"
                    commit()
                    open(type, byBr = true)
                }
                "hr" -> { closeBlock(); blocks.add(WysiwygBlock("divider")) }
                "figure" -> {
                    closeBlock()
                    val a = attributes(attrText)
                    mediaBlock = when {
                        a["data-poll"] != null ->
                            JsonCoder.decode(a["data-poll"]!!).firstOrNull() ?: WysiwygBlock("poll")
                        a["data-embed"] != null -> WysiwygBlock("embed").apply {
                            attrs["url"] = a["data-embed"]!!
                            a["data-provider"]?.takeIf { it.isNotEmpty() }?.let { attrs["provider"] = it }
                        }
                        // Type is decided by whatever <img>/<video> it contains.
                        else -> WysiwygBlock("figure")
                    }
                    a["data-pending"]?.takeIf { it.isNotEmpty() }?.let { mediaBlock?.attrs?.put("uploadId", it) }
                }
                "img", "video" -> {
                    val a = attributes(attrText)
                    val target = mediaBlock ?: WysiwygBlock(name)
                    target.type = if (name == "img") "image" else "video"
                    a["src"]?.takeIf { it.isNotEmpty() }?.let { target.attrs["src"] = it }
                    a["alt"]?.takeIf { it.isNotEmpty() }?.let { target.attrs["alt"] = it }
                    a["poster"]?.takeIf { it.isNotEmpty() }?.let { target.attrs["poster"] = it }
                    if (mediaBlock == null) {
                        // A bare <img>/<video> outside a figure is still a block.
                        closeBlock()
                        blocks.add(target)
                    } else {
                        mediaBlock = target
                    }
                }
                "figcaption" -> inFigcaption = true
                "p", "div" -> open("p")
                "h1" -> open("h1")
                "h2" -> open("h2")
                "h3", "h4", "h5", "h6" -> open("h3")
                "blockquote" -> open("blockquote")
                "ul" -> { closeBlock(); listStack.add("ul") }
                "ol" -> { closeBlock(); listStack.add("ol") }
                "li" -> open(listStack.lastOrNull() ?: "p")
                "a" -> {
                    val href = allowedHref(attributes(attrText)["href"])
                    markStack.add("a" to { b -> if (href != null) b.link = href })
                }
                "span" -> {
                    val color = cssColor("color", attributes(attrText)["style"])
                    markStack.add("span" to { b -> if (color != null) b.color = color })
                }
                "mark" -> {
                    val bg = cssColor("background-color", attributes(attrText)["style"]) ?: "#FDE68A"
                    markStack.add("mark" to { b -> b.highlight = bg })
                }
                "strong", "b" -> markStack.add("strong" to { b -> b.bold = true })
                "em", "i" -> markStack.add("em" to { b -> b.italic = true })
                "u" -> markStack.add("u" to { b -> b.underline = true })
                "s", "del", "strike" -> markStack.add("s" to { b -> b.strike = true })
                "code" -> markStack.add("code" to { b -> b.code = true })
                else -> Unit // unknown tag: ignored, its text still flows through
            }
        }

        fun handleClose(name: String) {
            when (name) {
                "figure" -> {
                    mediaBlock?.let { if (it.type != "figure") blocks.add(it) }
                    mediaBlock = null
                    inFigcaption = false
                }
                "figcaption" -> inFigcaption = false
                "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "li" -> closeBlock()
                "ul", "ol" -> {
                    closeBlock()
                    if (listStack.isNotEmpty()) listStack.removeAt(listStack.size - 1)
                }
                "a", "span", "mark", "strong", "b", "em", "i", "u", "s", "del", "strike", "code" -> {
                    val canonical = canonicalInline(name)
                    val idx = markStack.indexOfLast { it.first == canonical }
                    if (idx >= 0) markStack.removeAt(idx)
                }
                else -> Unit
            }
        }

        fun handleTag(raw: String) {
            var body = raw.trim()
            if (body.isEmpty()) return
            val isClose = body.startsWith("/")
            if (isClose) body = body.substring(1)
            if (body.endsWith("/")) body = body.dropLast(1)
            var k = 0
            while (k < body.length && body[k].isLetterOrDigit()) k++
            if (k == 0) return
            val name = body.substring(0, k).lowercase()
            val attrText = body.substring(k)
            if (isClose) handleClose(name) else handleOpen(name, attrText)
        }

        while (i < n) {
            if (html[i] == '<') {
                if (i + 3 < n && html[i + 1] == '!' && html[i + 2] == '-' && html[i + 3] == '-') {
                    val end = html.indexOf("-->", startIndex = i + 4)
                    i = if (end < 0) n else end + 3
                    continue
                }
                if (i + 1 < n && html[i + 1] == '!') { // <!doctype …>
                    var j = i
                    while (j < n && html[j] != '>') j++
                    i = minOf(j + 1, n)
                    continue
                }
                // Find the tag-closing '>' (quote-aware for attribute values).
                var j = i + 1
                var quote: Char? = null
                while (j < n) {
                    val c = html[j]
                    if (quote != null) {
                        if (c == quote) quote = null
                    } else if (c == '"' || c == '\'') {
                        quote = c
                    } else if (c == '>') {
                        break
                    }
                    j++
                }
                if (j >= n) { // unterminated tag — treat the rest as text
                    appendText(decodeEntities(html.substring(i)))
                    break
                }
                val inner = html.substring(i + 1, j)
                i = j + 1
                handleTag(inner)
            } else {
                var j = i
                while (j < n && html[j] != '<') j++
                appendText(decodeEntities(html.substring(i, j)))
                i = j
            }
        }

        closeBlock()
        return blocks
    }

    // ── serialize ───────────────────────────────────────────────────────────

    /**
     * Emit the normalised HTML + the plain-text rendition. `<p><br></p>` for an
     * intentional blank line; consecutive list items grouped into one list; no
     * whitespace between blocks. An empty document — or a document that is just
     * one empty paragraph — serializes to the EMPTY STRING, not `<p><br></p>`.
     */
    fun serialize(blocks: List<WysiwygBlock>): Pair<String, String> {
        if (blocks.isEmpty()) return "" to ""
        if (blocks.size == 1 && blocks[0].type == "p" && blocks[0].isEmpty) return "" to ""

        val html = StringBuilder()
        val lines = mutableListOf<String>()
        var i = 0

        while (i < blocks.size) {
            val type = blocks[i].type

            if (WysiwygBlock.MEDIA_TYPES.contains(type)) {
                html.append(mediaHtml(blocks[i]))
                lines.add(mediaText(blocks[i]))
                i++
                continue
            }

            if (type == "ul" || type == "ol") {
                html.append('<').append(type).append('>')
                var ordinal = 1
                while (i < blocks.size && blocks[i].type == type) {
                    html.append("<li>").append(inlineHtml(blocks[i].runs)).append("</li>")
                    val text = blocks[i].plainText
                    lines.add(if (type == "ul") "- $text" else "$ordinal. $text")
                    ordinal++
                    i++
                }
                html.append("</").append(type).append('>')
                continue
            }

            val tag = if (WysiwygBlock.KNOWN_TYPES.contains(type)) type else "p"
            if (tag == "p" && blocks[i].isEmpty) {
                html.append("<p><br></p>")
            } else {
                html.append('<').append(tag).append('>')
                    .append(inlineHtml(blocks[i].runs))
                    .append("</").append(tag).append('>')
            }
            lines.add(blocks[i].plainText)
            i++
        }

        return html.toString() to lines.joinToString("\n")
    }

    /**
     * Media blocks as HTML. `src` is the PUBLIC url — a block whose upload has
     * not finished exports with `data-pending` and no src rather than leaking
     * a device path into published HTML, so the host can find unfinished
     * uploads instead of silently shipping a broken image.
     */
    private fun mediaHtml(block: WysiwygBlock): String {
        val src = block.attrs["src"].orEmpty()
        val caption = block.attrs["caption"].orEmpty()
        val uploadId = block.attrs["uploadId"].orEmpty()
        val pending = if (src.isEmpty() && uploadId.isNotEmpty()) {
            " data-pending=\"" + escapeAttribute(uploadId) + "\""
        } else {
            ""
        }
        val figcaption = if (caption.isEmpty()) "" else "<figcaption>" + escapeText(caption) + "</figcaption>"

        return when (block.type) {
            "divider" -> "<hr>"
            "image" -> {
                val attrs = StringBuilder()
                if (src.isNotEmpty()) attrs.append(" src=\"").append(escapeAttribute(src)).append('"')
                attrs.append(" alt=\"").append(escapeAttribute(block.attrs["alt"].orEmpty())).append('"')
                "<figure$pending><img$attrs>$figcaption</figure>"
            }
            "video" -> {
                val attrs = StringBuilder()
                if (src.isNotEmpty()) attrs.append(" src=\"").append(escapeAttribute(src)).append('"')
                block.attrs["poster"]?.takeIf { it.isNotEmpty() }?.let {
                    attrs.append(" poster=\"").append(escapeAttribute(it)).append('"')
                }
                "<figure$pending><video$attrs controls></video>$figcaption</figure>"
            }
            "file" -> "<p><a href=\"" + escapeAttribute(src) + "\" download>" +
                escapeText(block.attrs["name"].orEmpty()) + "</a></p>"
            "embed" -> {
                val provider = block.attrs["provider"].orEmpty()
                val providerAttr = if (provider.isEmpty()) {
                    ""
                } else {
                    " data-provider=\"" + escapeAttribute(provider) + "\""
                }
                "<figure data-embed=\"" + escapeAttribute(block.attrs["url"].orEmpty()) +
                    "\"" + providerAttr + "></figure>"
            }
            // The whole block round-trips as escaped JSON — HTML has nowhere
            // else to keep option ids.
            "poll" -> "<figure data-poll=\"" + escapeAttribute(JsonCoder.encode(listOf(block))) +
                "\"></figure>"
            else -> ""
        }
    }

    /** The plain-text stand-in for a media block (used for excerpts/search). */
    private fun mediaText(block: WysiwygBlock): String = when (block.type) {
        "divider" -> "---"
        "image" -> block.attrs["caption"]?.takeIf { it.isNotEmpty() } ?: block.attrs["alt"].orEmpty()
        "video" -> block.attrs["caption"].orEmpty()
        "file" -> block.attrs["name"].orEmpty()
        "embed" -> block.attrs["url"].orEmpty()
        "poll" -> block.attrs["question"].orEmpty()
        else -> ""
    }

    /**
     * Merge adjacent identical runs, then wrap them in the fixed nesting order
     * (link → color → highlight → strong → em → u → s → code) by recursively
     * grouping consecutive runs that share the mark at each level — so
     * "bold, then bold+italic" emits `<strong>a<em>b</em></strong>`, one tag,
     * not two adjacent `<strong>`s. Mirrors the iOS emitLevel exactly.
     */
    private fun inlineHtml(runs: List<WysiwygRun>): String {
        val merged = mutableListOf<WysiwygRun>()
        for (run in runs) {
            if (run.text.isEmpty()) continue
            val last = merged.lastOrNull()
            if (last != null && last.marks == run.marks) {
                merged[merged.size - 1] = WysiwygRun(last.text + run.text, run.marks)
            } else {
                merged.add(run)
            }
        }
        return emitLevel(merged, 0, merged.size, 0)
    }

    /** The mark examined at each nesting level; null means "not marked". */
    private fun markValue(m: MarkSet, level: Int): String? = when (level) {
        0 -> m.link
        1 -> m.color
        2 -> m.highlight
        3 -> if (m.bold) "1" else null
        4 -> if (m.italic) "1" else null
        5 -> if (m.underline) "1" else null
        6 -> if (m.strike) "1" else null
        else -> if (m.code) "1" else null
    }

    private fun emitLevel(runs: List<WysiwygRun>, from: Int, to: Int, level: Int): String {
        if (level >= 8) {
            val plain = StringBuilder()
            for (i in from until to) plain.append(escapeText(runs[i].text))
            return plain.toString()
        }

        val out = StringBuilder()
        var i = from
        while (i < to) {
            val value = markValue(runs[i].marks, level)
            var j = i + 1
            while (j < to && markValue(runs[j].marks, level) == value) j++
            val inner = emitLevel(runs, i, j, level + 1)

            if (value != null) {
                when (level) {
                    0 -> out.append("<a href=\"").append(escapeAttribute(value)).append("\">")
                        .append(inner).append("</a>")
                    1 -> out.append("<span style=\"color:").append(value).append("\">")
                        .append(inner).append("</span>")
                    2 -> out.append("<mark style=\"background-color:").append(value).append("\">")
                        .append(inner).append("</mark>")
                    3 -> out.append("<strong>").append(inner).append("</strong>")
                    4 -> out.append("<em>").append(inner).append("</em>")
                    5 -> out.append("<u>").append(inner).append("</u>")
                    6 -> out.append("<s>").append(inner).append("</s>")
                    else -> out.append("<code>").append(inner).append("</code>")
                }
            } else {
                out.append(inner)
            }
            i = j
        }
        return out.toString()
    }

    // ── helpers (shared semantics with iOS) ─────────────────────────────────

    fun escapeText(s: String): String {
        val out = StringBuilder(s.length)
        for (c in s) {
            when (c) {
                '&' -> out.append("&amp;")
                '<' -> out.append("&lt;")
                '>' -> out.append("&gt;")
                else -> out.append(c)
            }
        }
        return out.toString()
    }

    fun escapeAttribute(s: String): String = escapeText(s).replace("\"", "&quot;")

    fun decodeEntities(s: String): String {
        if (!s.contains('&')) return s
        val out = StringBuilder(s.length)
        var i = 0
        while (i < s.length) {
            if (s[i] == '&') {
                // Entities are short — look ahead a bounded distance for ';'.
                var semi = -1
                var j = i + 1
                while (j < s.length && j - i <= 10) {
                    if (s[j] == ';') { semi = j; break }
                    j++
                }
                if (semi > i + 1) {
                    val decoded = decodeEntity(s.substring(i + 1, semi))
                    if (decoded != null) {
                        out.append(decoded)
                        i = semi + 1
                        continue
                    }
                }
            }
            out.append(s[i])
            i++
        }
        return out.toString()
    }

    private fun decodeEntity(name: String): String? {
        when (name.lowercase()) {
            "amp" -> return "&"
            "lt" -> return "<"
            "gt" -> return ">"
            "quot" -> return "\""
            "apos" -> return "'"
            "nbsp" -> return "\u00A0"
        }
        if (name.startsWith("#")) {
            val digits = name.substring(1)
            val value = if (digits.startsWith("x", ignoreCase = true)) {
                digits.substring(1).toIntOrNull(16)
            } else {
                digits.toIntOrNull()
            }
            if (value != null && value in 1..0x10FFFF) {
                return String(Character.toChars(value))
            }
        }
        return null
    }

    /**
     * Runs of whitespace that contain a line break / tab (i.e. source-code
     * formatting) collapse to one space; runs of plain spaces are preserved so
     * user-typed content round-trips verbatim.
     */
    fun collapseWhitespace(s: String): String {
        if (!s.any { it == '\n' || it == '\r' || it == '\t' }) return s
        val out = StringBuilder(s.length)
        val run = StringBuilder()
        var runHasBreak = false
        for (c in s) {
            if (c == ' ' || c == '\n' || c == '\r' || c == '\t') {
                run.append(c)
                if (c != ' ') runHasBreak = true
            } else {
                if (run.isNotEmpty()) {
                    out.append(if (runHasBreak) " " else run.toString())
                    run.setLength(0)
                    runHasBreak = false
                }
                out.append(c)
            }
        }
        if (run.isNotEmpty()) out.append(if (runHasBreak) " " else run.toString())
        return out.toString()
    }

    /** Very small attribute scanner: name[=value] pairs, quoted or bare. */
    fun attributes(s: String): Map<String, String> {
        val result = mutableMapOf<String, String>()
        val n = s.length
        var i = 0
        while (i < n) {
            while (i < n && s[i].isWhitespace()) i++
            val name = StringBuilder()
            while (i < n && !s[i].isWhitespace() && s[i] != '=') { name.append(s[i]); i++ }
            while (i < n && s[i].isWhitespace()) i++
            val value = StringBuilder()
            if (i < n && s[i] == '=') {
                i++
                while (i < n && s[i].isWhitespace()) i++
                if (i < n && (s[i] == '"' || s[i] == '\'')) {
                    val q = s[i]
                    i++
                    while (i < n && s[i] != q) { value.append(s[i]); i++ }
                    if (i < n) i++
                } else {
                    while (i < n && !s[i].isWhitespace()) { value.append(s[i]); i++ }
                }
            }
            if (name.isNotEmpty()) result[name.toString().lowercase()] = decodeEntities(value.toString())
        }
        return result
    }

    /**
     * Extract `property: #hex` from an inline style, canonicalised to uppercase
     * 6-digit "#RRGGBB" (3-digit shorthand expanded). Null otherwise.
     */
    fun cssColor(property: String, style: String?): String? {
        if (style == null) return null
        for (declaration in style.split(';')) {
            val idx = declaration.indexOf(':')
            if (idx < 0) continue
            val key = declaration.substring(0, idx).trim().lowercase()
            if (key != property) continue
            return normalizeHex(declaration.substring(idx + 1).trim())
        }
        return null
    }

    /** "#abc" / "#AABBCC" → "#AABBCC". Null for anything else. */
    fun normalizeHex(raw: String): String? {
        var s = raw.trim()
        if (!s.startsWith("#")) return null
        s = s.substring(1)
        if (s.length == 3) s = s.map { "$it$it" }.joinToString("")
        if (s.length != 6 || !s.all { it.isDigit() || it in 'a'..'f' || it in 'A'..'F' }) return null
        return "#" + s.uppercase()
    }

    /** Keep only http(s)/mailto/tel hrefs (input tolerance — no auto-fixing). */
    fun allowedHref(href: String?): String? {
        val trimmed = href?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        val lower = trimmed.lowercase()
        return if (lower.startsWith("http://") || lower.startsWith("https://") ||
            lower.startsWith("mailto:") || lower.startsWith("tel:")
        ) trimmed else null
    }
}

// ── JSON coder ──────────────────────────────────────────────────────────────

/**
 * The FIDELITY format: unlike HTML it carries block ids, upload state and poll
 * options. See docs/DOCUMENT-MODEL.md.
 *
 * The writer is hand-rolled rather than `org.json` / `JSONObject` for two
 * reasons: platform JSON writers make no guarantee about key ORDER, so the two
 * platforms would emit different bytes for the same document and the parity
 * harness could not compare them; and staying dependency-free keeps the coder
 * pure Kotlin, so it runs off-device in the test harness.
 */
internal object JsonCoder {

    // ── encode ──────────────────────────────────────────────────────────────

    fun encode(blocks: List<WysiwygBlock>): String {
        val out = StringBuilder()
        out.append("{\"version\":2,\"blocks\":[")
        blocks.forEachIndexed { index, block ->
            if (index > 0) out.append(',')
            encodeBlock(out, block)
        }
        out.append("]}")
        return out.toString()
    }

    private fun encodeBlock(out: StringBuilder, block: WysiwygBlock) {
        out.append("{\"id\":").append(quote(block.id))
        out.append(",\"type\":").append(quote(block.type))

        if (block.isText) {
            out.append(",\"runs\":[")
            var first = true
            for (run in block.runs) {
                if (run.text.isEmpty()) continue
                if (!first) out.append(',')
                first = false
                out.append("{\"text\":").append(quote(run.text))
                out.append(",\"marks\":")
                encodeMarks(out, run.marks)
                out.append('}')
            }
            out.append(']')
        } else {
            // Fixed key order per type keeps both platforms byte-identical.
            for (key in WysiwygBlock.MEDIA_ATTRS[block.type].orEmpty()) {
                val value = block.attrs[key] ?: continue
                out.append(',').append(quote(key)).append(':').append(quote(value))
            }
            if (block.type == "poll") {
                out.append(",\"options\":[")
                block.options.forEachIndexed { index, option ->
                    if (index > 0) out.append(',')
                    out.append("{\"id\":").append(quote(option.id))
                    out.append(",\"label\":").append(quote(option.label)).append('}')
                }
                out.append(']')
            }
        }

        out.append('}')
    }

    /** Only marks that are SET are emitted, in the contract's nesting order. */
    private fun encodeMarks(out: StringBuilder, marks: MarkSet) {
        out.append('{')
        var first = true
        fun pair(key: String, value: String) {
            if (!first) out.append(',')
            first = false
            out.append(quote(key)).append(':').append(value)
        }
        marks.link?.let { pair("link", quote(it)) }
        marks.color?.let { pair("color", quote(it)) }
        marks.highlight?.let { pair("highlight", quote(it)) }
        if (marks.bold) pair("bold", "true")
        if (marks.italic) pair("italic", "true")
        if (marks.underline) pair("underline", "true")
        if (marks.strike) pair("strike", "true")
        if (marks.code) pair("code", "true")
        out.append('}')
    }

    fun quote(s: String): String {
        val out = StringBuilder(s.length + 2)
        out.append('"')
        for (c in s) {
            when (c) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                else -> if (c < ' ') {
                    out.append("\\u").append(String.format("%04x", c.code))
                } else {
                    out.append(c)
                }
            }
        }
        out.append('"')
        return out.toString()
    }

    // ── decode ──────────────────────────────────────────────────────────────

    /** Tolerant reader: unknown keys ignored, malformed input yields no blocks. */
    fun decode(json: String): MutableList<WysiwygBlock> {
        val value = try {
            JsonScanner(json).parseValue()
        } catch (e: Exception) {
            return mutableListOf()
        }

        val root = value as? Map<*, *> ?: return mutableListOf()
        val rawBlocks = root["blocks"] as? List<*> ?: return mutableListOf()
        val blocks = mutableListOf<WysiwygBlock>()

        for (raw in rawBlocks) {
            val map = raw as? Map<*, *> ?: continue
            val type = map["type"] as? String ?: continue
            if (!WysiwygBlock.KNOWN_TYPES.contains(type) && !WysiwygBlock.MEDIA_TYPES.contains(type)) {
                continue
            }

            val block = WysiwygBlock(type, id = map["id"] as? String ?: "")

            if (block.isText) {
                for (rawRun in map["runs"] as? List<*> ?: emptyList<Any>()) {
                    val runMap = rawRun as? Map<*, *> ?: continue
                    val text = runMap["text"] as? String ?: continue
                    if (text.isEmpty()) continue
                    block.runs.add(WysiwygRun(text, decodeMarks(runMap["marks"] as? Map<*, *>)))
                }
            } else {
                for (key in WysiwygBlock.MEDIA_ATTRS[type].orEmpty()) {
                    val value2 = map[key]
                    if (value2 != null) block.attrs[key] = stringify(value2)
                }
                for (rawOption in map["options"] as? List<*> ?: emptyList<Any>()) {
                    val optionMap = rawOption as? Map<*, *> ?: continue
                    block.options.add(
                        PollOption(
                            optionMap["id"] as? String ?: "",
                            optionMap["label"] as? String ?: "",
                        )
                    )
                }
            }

            blocks.add(block)
        }

        return blocks
    }

    private fun stringify(value: Any?): String = when (value) {
        null -> ""
        is String -> value
        is Boolean -> if (value) "true" else "false"
        is Double -> if (value == Math.floor(value) && !value.isInfinite()) {
            value.toLong().toString()
        } else {
            value.toString()
        }
        else -> value.toString()
    }

    private fun decodeMarks(map: Map<*, *>?): MarkSet {
        if (map == null) return MarkSet()
        fun flag(key: String) = map[key] == true
        return MarkSet(
            link = map["link"] as? String,
            color = map["color"] as? String,
            highlight = map["highlight"] as? String,
            bold = flag("bold"),
            italic = flag("italic"),
            underline = flag("underline"),
            strike = flag("strike"),
            code = flag("code"),
        )
    }
}

/** Minimal recursive-descent JSON reader — objects, arrays, strings, numbers,
 *  booleans and null. Enough for this document model, nothing more. */
internal class JsonScanner(private val src: String) {
    private var i = 0

    fun parseValue(): Any? {
        skipWhitespace()
        if (i >= src.length) return null
        return when (src[i]) {
            '{' -> parseObject()
            '[' -> parseArray()
            '"' -> parseString()
            't' -> literal("true", true)
            'f' -> literal("false", false)
            'n' -> literal("null", null)
            else -> parseNumber()
        }
    }

    private fun skipWhitespace() {
        while (i < src.length && src[i].isWhitespace()) i++
    }

    private fun literal(word: String, value: Any?): Any? {
        require(src.startsWith(word, i)) { "bad literal at $i" }
        i += word.length
        return value
    }

    private fun parseObject(): Map<String, Any?> {
        val map = LinkedHashMap<String, Any?>()
        i++ // '{'
        skipWhitespace()
        if (i < src.length && src[i] == '}') { i++; return map }
        while (i < src.length) {
            skipWhitespace()
            val key = parseString()
            skipWhitespace()
            require(i < src.length && src[i] == ':') { "expected ':' at $i" }
            i++
            map[key] = parseValue()
            skipWhitespace()
            if (i < src.length && src[i] == ',') { i++; continue }
            if (i < src.length && src[i] == '}') { i++; break }
            break
        }
        return map
    }

    private fun parseArray(): List<Any?> {
        val list = mutableListOf<Any?>()
        i++ // '['
        skipWhitespace()
        if (i < src.length && src[i] == ']') { i++; return list }
        while (i < src.length) {
            list.add(parseValue())
            skipWhitespace()
            if (i < src.length && src[i] == ',') { i++; continue }
            if (i < src.length && src[i] == ']') { i++; break }
            break
        }
        return list
    }

    private fun parseString(): String {
        require(i < src.length && src[i] == '"') { "expected string at $i" }
        i++
        val out = StringBuilder()
        while (i < src.length) {
            val c = src[i]
            when {
                c == '"' -> { i++; return out.toString() }
                c == '\\' -> {
                    i++
                    when (val esc = src.getOrNull(i)) {
                        '"' -> out.append('"')
                        '\\' -> out.append('\\')
                        '/' -> out.append('/')
                        'n' -> out.append('\n')
                        'r' -> out.append('\r')
                        't' -> out.append('\t')
                        'b' -> out.append('\b')
                        'f' -> out.append('')
                        'u' -> {
                            val hex = src.substring(i + 1, minOf(i + 5, src.length))
                            out.append(hex.toInt(16).toChar())
                            i += 4
                        }
                        else -> if (esc != null) out.append(esc)
                    }
                    i++
                }
                else -> { out.append(c); i++ }
            }
        }
        return out.toString()
    }

    private fun parseNumber(): Double {
        val start = i
        while (i < src.length && (src[i].isDigit() || src[i] in "-+.eE")) i++
        return src.substring(start, i).toDoubleOrNull() ?: 0.0
    }
}

/** Whitespace-delimited words across the whole document. */
internal fun countWords(blocks: List<WysiwygBlock>): Int =
    blocks.sumOf { block ->
        block.plainText.split(' ', '\n', '\t', '\u00A0')
            .count { it.isNotBlank() }
    }


/**
 * A user-visible string, translated by the host when it supplied one.
 *
 * `{n}` / `{max}` / `{type}` placeholders are substituted here so the host's
 * translation controls word order, which matters in languages where the number
 * does not come first.
 */
internal fun localized(
    strings: Map<String, String>,
    key: String,
    fallback: String,
    n: Any? = null,
    max: Any? = null,
    type: String? = null,
): String {
    var out = strings[key] ?: fallback
    if (n != null) out = out.replace("{n}", n.toString())
    if (max != null) out = out.replace("{max}", max.toString())
    if (type != null) out = out.replace("{type}", type)
    return out
}

/**
 * Declarative save-time rules. Evaluated natively so a failing document never
 * makes the round-trip to PHP just to be rejected.
 *
 * Returns the first violation as a human-readable message, or null when the
 * document may be saved.
 */
internal fun validateDocument(
    blocks: List<WysiwygBlock>,
    rules: Map<String, Any>,
    strings: Map<String, String> = emptyMap(),
): String? {
    if (rules.isEmpty()) return null

    val words = countWords(blocks)

    (rules["minWords"] as? Number)?.toInt()?.let { min ->
        if (min > 0 && words < min) {
            return localized(strings, "ruleMinWords",
                "At least {max} words needed — you have {n}.", n = words, max = min)
        }
    }
    (rules["maxWords"] as? Number)?.toInt()?.let { max ->
        if (max > 0 && words > max) {
            return localized(strings, "ruleMaxWords",
                "At most {max} words allowed — you have {n}.", n = words, max = max)
        }
    }
    (rules["maxImages"] as? Number)?.toInt()?.let { max ->
        val images = blocks.count { it.type == "image" }
        if (images > max) {
            return localized(strings, "ruleMaxImages",
                "At most {max} image(s) allowed — you have {n}.", n = images, max = max)
        }
    }
    @Suppress("UNCHECKED_CAST")
    (rules["requiredBlocks"] as? List<String>)?.forEach { type ->
        if (blocks.none { it.type == type }) {
            return localized(strings, "ruleRequiredBlock",
                "This needs at least one {type}.", type = type)
        }
    }

    return null
}

// ── Segments ────────────────────────────────────────────────────────────────

/**
 * How a document is laid out for editing. Consecutive TEXT blocks collapse
 * into one editor (the v1 engine, unchanged); each media block gets its own
 * view. See docs/DOCUMENT-MODEL.md — this is what keeps caret handling to the
 * rare text↔media boundary instead of every paragraph break.
 */
internal sealed class Segment {
    /** A run of text blocks sharing one editor. */
    class Text(val blocks: MutableList<WysiwygBlock>) : Segment()

    /** A single media block rendered as its own card. */
    class Media(val block: WysiwygBlock) : Segment()
}

/** Group a block list into segments, preserving document order. */
internal fun segmentsOf(blocks: List<WysiwygBlock>): List<Segment> {
    val segments = mutableListOf<Segment>()

    for (block in blocks) {
        if (block.isText) {
            val last = segments.lastOrNull()
            if (last is Segment.Text) {
                last.blocks.add(block)
            } else {
                segments.add(Segment.Text(mutableListOf(block)))
            }
        } else {
            segments.add(Segment.Media(block))
        }
    }

    // An empty document still needs somewhere to type.
    if (segments.isEmpty()) segments.add(Segment.Text(mutableListOf(WysiwygBlock("p"))))

    return segments
}

/** Flatten segments back into a block list for serialization. */
internal fun blocksOf(segments: List<Segment>): List<WysiwygBlock> =
    segments.flatMap { segment ->
        when (segment) {
            is Segment.Text -> segment.blocks
            is Segment.Media -> listOf(segment.block)
        }
    }

// ── Toolbar icons ───────────────────────────────────────────────────────────

/**
 * One toolbar glyph: outline path data in a 24×24 box, plus its stroke weight.
 *
 * The path strings below are the SINGLE SOURCE OF TRUTH for the toolbar's
 * appearance and are duplicated VERBATIM in the iOS file — that is deliberate.
 * Platform icon sets (SF Symbols / Material) have no common subset, so drawing
 * the same vectors on both sides is the only way the two toolbars can actually
 * match. Keep the two copies in sync when editing.
 *
 * Supported path commands (a deliberately tiny SVG subset, so the renderer on
 * each platform stays ~40 lines): M x y · L x y · C x1 y1 x2 y2 x y · Z.
 * A zero-length line with a round cap renders as a dot (used by the lists).
 */
internal data class ToolIcon(val path: String, val stroke: Float = 2f)

internal val TOOL_ICONS: Map<String, ToolIcon> = mapOf(
    "undo" to ToolIcon("M9 7L4 12L9 17M4 12L14 12C17.3 12 20 14.7 20 18"),
    "redo" to ToolIcon("M15 7L20 12L15 17M20 12L10 12C6.7 12 4 14.7 4 18"),
    "bold" to ToolIcon(
        "M8 5L8 19M8 5L13 5C15.2 5 17 6.8 17 9C17 11.2 15.2 12 13 12L8 12" +
            "M8 12L14 12C16.2 12 18 13.8 18 16C18 18.2 16.2 19 14 19L8 19"
    ),
    "italic" to ToolIcon("M10 5L18 5M6 19L14 19M14.5 5L9.5 19"),
    "underline" to ToolIcon("M6 4L6 11C6 14.3 8.7 17 12 17C15.3 17 18 14.3 18 11L18 4M5 20L19 20"),
    "strikethrough" to ToolIcon(
        "M16 7C16 5.3 14.2 4 12 4C9.8 4 8 5.3 8 7C8 8.7 9.8 10 12 10" +
            "M12 14C14.2 14 16 15.3 16 17C16 18.7 14.2 20 12 20C9.8 20 8 18.7 8 17M4 12L20 12"
    ),
    "h1" to ToolIcon("M4 6L4 18M4 12L11 12M11 6L11 18M15 9.5L17.5 8L17.5 18"),
    "h2" to ToolIcon(
        "M4 6L4 18M4 12L11 12M11 6L11 18" +
            "M15 9.5C15 8.4 16 7.5 17.2 7.5C18.7 7.5 19.7 8.6 19.7 10C19.7 12.5 15 14.5 15 18L19.7 18"
    ),
    "h3" to ToolIcon(
        "M4 6L4 18M4 12L11 12M11 6L11 18" +
            "M15 8L19.5 8L16.8 11.5C18.6 11.5 19.9 12.7 19.9 14.5C19.9 16.5 18.5 18 16.7 18C15.8 18 15.2 17.7 14.8 17.2"
    ),
    "bulletList" to ToolIcon("M4 7L4.01 7M9 7L20 7M4 12L4.01 12M9 12L20 12M4 17L4.01 17M9 17L20 17"),
    "orderedList" to ToolIcon(
        "M3.6 5.2L4.7 4.6L4.7 8.4" +
            "M3.2 11.1C3.2 10.4 3.8 9.9 4.5 9.9C5.3 9.9 5.8 10.5 5.8 11.2C5.8 12.4 3.2 13.2 3.2 14.5L5.9 14.5" +
            "M3.3 15.9L5.9 15.9L4.5 17.7C5.3 17.7 6 18.3 6 19.1C6 19.9 5.4 20.5 4.6 20.5C4 20.5 3.6 20.3 3.3 20" +
            "M9 6.5L20 6.5M9 12.2L20 12.2M9 18L20 18",
        stroke = 1.5f,
    ),
    "blockquote" to ToolIcon("M4 5L4 19M9 8L20 8M9 12L20 12M9 16L17 16"),
    // Plain body text — offered in the Format sheet as the way BACK from a
    // heading, so it needs a glyph like every other row.
    "p" to ToolIcon("M4 6L20 6M4 12L20 12M4 18L14 18"),
    "link" to ToolIcon(
        "M9.5 12L14.5 12" +
            "M10 8L7.5 8C5.3 8 3.5 9.8 3.5 12C3.5 14.2 5.3 16 7.5 16L10 16" +
            "M14 8L16.5 8C18.7 8 20.5 9.8 20.5 12C20.5 14.2 18.7 16 16.5 16L14 16"
    ),
    "code" to ToolIcon("M9 8L4.5 12L9 16M15 8L19.5 12L15 16"),
    "textColor" to ToolIcon("M5 15L10 5L15 15M6.8 11.6L13.2 11.6M4 19.5L20 19.5"),
    "highlight" to ToolIcon("M15 4L20 9L10 19L5 19L5 14L15 4M13 6L18 11"),
    "clearFormat" to ToolIcon("M5 15L10 5L15 15M6.8 11.6L13.2 11.6M4 4L20 20"),
    // Insert tools: a framed picture, a play triangle, a paperclip.
    "image" to ToolIcon(
        "M3.5 5.5L20.5 5.5L20.5 18.5L3.5 18.5L3.5 5.5" +
            "M3.5 15L8.5 10.5L12.5 14L15.5 11.5L20.5 16M15.5 9.2L15.51 9.2"
    ),
    "video" to ToolIcon("M3.5 6L16 6L16 18L3.5 18L3.5 6M16 10.5L20.5 8L20.5 16L16 13.5"),
    "file" to ToolIcon(
        "M16.5 7.5L9 15C7.6 16.4 7.6 18.6 9 20C10.4 21.4 12.6 21.4 14 20L19.5 14.5" +
            "C21.6 12.4 21.6 9.1 19.5 7C17.4 4.9 14.1 4.9 12 7L6.5 12.5"
    ),
)

/**
 * Parse the mini path language into a Compose Path, scaled from the 24×24
 * design box to `size` pixels. Unknown commands are ignored rather than
 * throwing — a malformed glyph should never crash the editor.
 */
internal fun buildIconPath(data: String, size: Float): androidx.compose.ui.graphics.Path {
    val path = androidx.compose.ui.graphics.Path()
    val k = size / 24f
    val args = mutableListOf<Float>()
    var command = ' '
    var i = 0

    fun expected(c: Char): Int = when (c) {
        'M', 'L' -> 2
        'C' -> 6
        else -> 0
    }

    fun emit() {
        when (command) {
            'M' -> if (args.size >= 2) path.moveTo(args[0] * k, args[1] * k)
            'L' -> if (args.size >= 2) path.lineTo(args[0] * k, args[1] * k)
            'C' -> if (args.size >= 6) path.cubicTo(
                args[0] * k, args[1] * k, args[2] * k, args[3] * k, args[4] * k, args[5] * k,
            )
        }
        args.clear()
    }

    while (i < data.length) {
        val c = data[i]
        when {
            c.isLetter() -> {
                args.clear()
                command = c.uppercaseChar()
                if (command == 'Z') path.close()
                i++
            }
            c == ' ' || c == ',' -> i++
            else -> {
                val start = i
                if (data[i] == '-') i++
                while (i < data.length && (data[i].isDigit() || data[i] == '.')) i++
                args.add(data.substring(start, i).toFloatOrNull() ?: 0f)
                if (args.size == expected(command)) emit()
            }
        }
    }

    return path
}

// ── Spans ───────────────────────────────────────────────────────────────────

/**
 * Marker interface for spans that carry DOCUMENT meaning (and therefore
 * round-trip to HTML). Everything else applied to the Editable — heading
 * sizes, quote indents, list margins — is presentation only and is ignored by
 * the serializer, which is why display styling can reuse the platform spans
 * freely without corrupting the document.
 */
internal interface SemanticSpan

internal class BoldMarkSpan : android.text.style.StyleSpan(android.graphics.Typeface.BOLD), SemanticSpan
internal class ItalicMarkSpan : android.text.style.StyleSpan(android.graphics.Typeface.ITALIC), SemanticSpan
internal class UnderlineMarkSpan : android.text.style.UnderlineSpan(), SemanticSpan
internal class StrikeMarkSpan : android.text.style.StrikethroughSpan(), SemanticSpan
internal class ColorMarkSpan(val hex: String, color: Int) :
    android.text.style.ForegroundColorSpan(color), SemanticSpan
internal class HighlightMarkSpan(val hex: String, color: Int) :
    android.text.style.BackgroundColorSpan(color), SemanticSpan
internal class LinkMarkSpan(val url: String, private val tint: Int) :
    android.text.style.CharacterStyle(), SemanticSpan, android.text.style.UpdateAppearance {
    override fun updateDrawState(tp: android.text.TextPaint) {
        tp.color = tint
        tp.isUnderlineText = true
    }
}

internal class CodeMarkSpan(private val background: Int) :
    android.text.style.MetricAffectingSpan(), SemanticSpan {
    override fun updateDrawState(tp: android.text.TextPaint) {
        apply(tp)
        tp.bgColor = background
    }

    override fun updateMeasureState(tp: android.text.TextPaint) = apply(tp)

    private fun apply(tp: android.text.TextPaint) {
        tp.typeface = android.graphics.Typeface.MONOSPACE
    }
}

/**
 * Paragraph type ("p", "h1", … "blockquote"). Attached with SPAN_PARAGRAPH so
 * Android keeps it aligned to newline boundaries as the user edits.
 */
internal class BlockSpan(val type: String)

/**
 * Covers a list item's literal marker text ("• " / "1. "). The
 * serializer strips it, and the editor treats it as one indivisible unit so a
 * backspace at the start of an item removes the whole marker rather than
 * leaving "1" behind.
 */
internal class MarkerSpan

// ── Styler ──────────────────────────────────────────────────────────────────

/** Non-breaking space — keeps a list marker glued to its item while wrapping. */
internal const val NBSP = '\u00A0'

/**
 * Converts between the document model and the Editable the EditText renders.
 * Display styling (sizes, indents, quote bars) is applied here and deliberately
 * NOT read back — see [SemanticSpan].
 */
internal object Styler {

    fun markerFor(type: String, ordinal: Int): String = when (type) {
        "ul" -> "•$NBSP"
        "ol" -> "$ordinal.$NBSP"
        else -> ""
    }

    /** Build the editable text for a whole document. */
    fun toSpannable(
        blocks: List<WysiwygBlock>,
        theme: WysiwygEditorFunctions.EditorTheme,
        night: Boolean,
        typography: WysiwygTypography = WysiwygTypography(),
    ): android.text.SpannableStringBuilder {
        val out = android.text.SpannableStringBuilder()
        val source = if (blocks.isEmpty()) listOf(WysiwygBlock("p")) else blocks
        var ordinal = 1

        source.forEachIndexed { index, block ->
            if (index > 0) out.append('\n')
            val start = out.length

            // Ordered-list numbering restarts whenever the run of items breaks.
            if (block.type == "ol") {
                val previous = source.getOrNull(index - 1)
                if (previous?.type != "ol") ordinal = 1
            }

            val marker = markerFor(block.type, ordinal)
            if (marker.isNotEmpty()) {
                out.append(marker)
                out.setSpan(
                    MarkerSpan(), start, out.length,
                    android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                )
                if (block.type == "ol") ordinal++
            }

            for (run in block.runs) {
                if (run.text.isEmpty()) continue
                val runStart = out.length
                out.append(run.text)
                applyMarks(out, runStart, out.length, run.marks, theme, night)
            }

            applyBlockStyle(out, start, out.length, block.type, theme, night, typography)
        }

        return out
    }

    /** Attach the semantic mark spans for one run. */
    fun applyMarks(
        out: android.text.Spannable,
        start: Int,
        end: Int,
        marks: MarkSet,
        theme: WysiwygEditorFunctions.EditorTheme,
        night: Boolean,
    ) {
        if (end <= start) return
        val flag = android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE

        if (marks.bold) out.setSpan(BoldMarkSpan(), start, end, flag)
        if (marks.italic) out.setSpan(ItalicMarkSpan(), start, end, flag)
        if (marks.underline) out.setSpan(UnderlineMarkSpan(), start, end, flag)
        if (marks.strike) out.setSpan(StrikeMarkSpan(), start, end, flag)
        if (marks.code) {
            val bg = if (night) 0x22FFFFFF else 0x14000000
            out.setSpan(CodeMarkSpan(bg), start, end, flag)
        }
        marks.color?.let { hex ->
            out.setSpan(ColorMarkSpan(hex, android.graphics.Color.parseColor(hex)), start, end, flag)
        }
        marks.highlight?.let { hex ->
            out.setSpan(HighlightMarkSpan(hex, android.graphics.Color.parseColor(hex)), start, end, flag)
        }
        marks.link?.let { url ->
            out.setSpan(LinkMarkSpan(url, theme.accentColor(night).toArgb()), start, end, flag)
        }
    }

    /** Attach the block type plus its presentation spans. */
    fun applyBlockStyle(
        out: android.text.Spannable,
        start: Int,
        end: Int,
        type: String,
        theme: WysiwygEditorFunctions.EditorTheme,
        night: Boolean,
        typography: WysiwygTypography = WysiwygTypography(),
    ) {
        // Android only honours SPAN_PARAGRAPH when the span ends AFTER a
        // newline (charAt(end - 1) == '\n') or at the very end of the buffer.
        // Ending exactly AT the newline makes it silently drop the span, which
        // loses the block type of every paragraph but the last — so extend the
        // block span over its terminating newline.
        val hasTrailingNewline = end < out.length
        val blockEnd = if (hasTrailingNewline) end + 1 else out.length
        val blockFlag = when {
            start >= blockEnd -> android.text.Spanned.SPAN_INCLUSIVE_INCLUSIVE
            hasTrailingNewline -> android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            // Last paragraph: typing at the end must extend the block.
            else -> android.text.Spanned.SPAN_EXCLUSIVE_INCLUSIVE
        }
        out.setSpan(BlockSpan(type), start, blockEnd, blockFlag)

        if (end <= start) return
        val inclusive = android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
        val paragraph = android.text.Spanned.SPAN_PARAGRAPH

        when (type) {
            "h1", "h2", "h3" -> {
                out.setSpan(
                    android.text.style.AbsoluteSizeSpan(typography.size(type), true),
                    start, end, inclusive,
                )
                out.setSpan(android.text.style.StyleSpan(android.graphics.Typeface.BOLD), start, end, inclusive)
            }
            "blockquote" -> {
                out.setSpan(android.text.style.LeadingMarginSpan.Standard(48), start, blockEnd, paragraph)
                out.setSpan(android.text.style.StyleSpan(android.graphics.Typeface.ITALIC), start, end, inclusive)
                val dim = theme.textColor(night).copy(alpha = 0.72f).toArgb()
                out.setSpan(android.text.style.ForegroundColorSpan(dim), start, end, inclusive)
            }
            "ul", "ol" -> {
                // Wrapped lines align past the marker rather than under it.
                out.setSpan(android.text.style.LeadingMarginSpan.Standard(0, 56), start, blockEnd, paragraph)
            }
        }
    }

    /** Read the document back out of the editable text. */
    fun toBlocks(text: android.text.Spanned): MutableList<WysiwygBlock> {
        val blocks = mutableListOf<WysiwygBlock>()
        val whole = text.toString()
        var lineStart = 0

        while (lineStart <= whole.length) {
            var lineEnd = whole.indexOf('\n', lineStart)
            if (lineEnd < 0) lineEnd = whole.length

            // Block spans cover their terminating newline, so a query for THIS
            // line can also return the previous line's span — keep only a span
            // that actually starts at or before this line.
            val type = text.getSpans(lineStart, maxOf(lineStart, lineEnd), BlockSpan::class.java)
                .filter { text.getSpanStart(it) <= lineStart }
                .maxByOrNull { text.getSpanStart(it) }?.type ?: "p"
            val block = WysiwygBlock(if (WysiwygBlock.KNOWN_TYPES.contains(type)) type else "p")

            // Skip the marker prefix — it is chrome, never content.
            var contentStart = lineStart
            if (lineEnd > lineStart) {
                val markers = text.getSpans(lineStart, lineEnd, MarkerSpan::class.java)
                for (marker in markers) {
                    val markerEnd = text.getSpanEnd(marker)
                    if (text.getSpanStart(marker) <= contentStart && markerEnd > contentStart) {
                        contentStart = minOf(markerEnd, lineEnd)
                    }
                }
            }

            var i = contentStart
            while (i < lineEnd) {
                val next = text.nextSpanTransition(i, lineEnd, android.text.style.CharacterStyle::class.java)
                val segmentEnd = minOf(next, lineEnd)
                if (segmentEnd > i) {
                    val marks = marksIn(text, i, segmentEnd)
                    val chunk = whole.substring(i, segmentEnd)
                    val last = block.runs.lastOrNull()
                    if (last != null && last.marks == marks) {
                        block.runs[block.runs.size - 1] = WysiwygRun(last.text + chunk, marks)
                    } else {
                        block.runs.add(WysiwygRun(chunk, marks))
                    }
                }
                i = segmentEnd
            }

            blocks.add(block)

            if (lineEnd >= whole.length) break
            lineStart = lineEnd + 1
        }

        return blocks
    }

    /** The marks covering [start, end) — semantic spans only. */
    private fun marksIn(text: android.text.Spanned, start: Int, end: Int): MarkSet {
        val builder = MarkBuilder()
        for (span in text.getSpans(start, end, Any::class.java)) {
            if (span !is SemanticSpan) continue
            // A span that merely touches the segment edge does not cover it.
            if (text.getSpanStart(span) > start || text.getSpanEnd(span) < end) continue
            when (span) {
                is BoldMarkSpan -> builder.bold = true
                is ItalicMarkSpan -> builder.italic = true
                is UnderlineMarkSpan -> builder.underline = true
                is StrikeMarkSpan -> builder.strike = true
                is CodeMarkSpan -> builder.code = true
                is ColorMarkSpan -> builder.color = span.hex
                is HighlightMarkSpan -> builder.highlight = span.hex
                is LinkMarkSpan -> builder.link = span.url
            }
        }
        return builder.build()
    }
}

// ── Editor controller ───────────────────────────────────────────────────────

/**
 * All editing behaviour that is not view construction: mark toggles, block
 * conversion, list renumbering, the undo stack and the length cap.
 *
 * The EditText's Editable is the single source of truth while the editor is
 * open; the document model is derived from it on demand (and pushed to the
 * host on every change so Save/Cancel can read it without touching the view).
 */
internal class EditorController(
    private val editText: android.widget.EditText,
    private val config: WysiwygEditorFunctions.EditorConfig,
    private val night: Boolean,
    private val onDocumentChanged: (List<WysiwygBlock>) -> Unit,
    private val onStateChanged: () -> Unit,
) {
    private val theme get() = config.theme

    /**
     * Marks armed by a toolbar toggle made with no selection. They apply to
     * everything typed CONTIGUOUSLY from [pendingAnchor] — arm bold, type a
     * word, the whole word is bold — and are dropped as soon as the caret
     * moves somewhere else.
     */
    private var pendingMarks: MarkSet? = null
    private var pendingAnchor = -1

    /** True while a text change is being processed, so caret moves it causes
     *  are not mistaken for the user moving the cursor. */
    private var inTextChange = false

    private var programmatic = false
    private var lastPushAt = 0L
    private val undoStack = ArrayDeque<Snapshot>()
    private val redoStack = ArrayDeque<Snapshot>()

    private class Snapshot(val text: android.text.SpannableStringBuilder, val selection: Int)

    val canUndo: Boolean get() = undoStack.isNotEmpty()
    val canRedo: Boolean get() = redoStack.isNotEmpty()

    /** Plain-text length as the user perceives it — markers are not content. */
    fun plainLength(): Int = Styler.toBlocks(editText.text).sumOf { it.plainText.length }

    fun document(): List<WysiwygBlock> = Styler.toBlocks(editText.text)

    /**
     * Backspace pressed with the caret at offset 0 — the document decides
     * whether there is a media card above to delete. Returning true consumes
     * the keystroke.
     */
    var onBackspaceAtStart: (() -> Boolean)? = null

    /**
     * Length of this segment's styled text — where a following segment's
     * content lands once the two are merged.
     */
    fun styledLength(): Int = editText.text.length

    /**
     * Swap this segment's whole content, putting the caret at [caretAt].
     *
     * Used when a media card between two text segments is deleted and the two
     * have to become one. Only the surviving segment is rebuilt, so every
     * other segment keeps its own undo history.
     */
    fun replaceDocument(blocks: List<WysiwygBlock>, caretAt: Int) {
        pushUndoForced()
        programmatic = true
        try {
            editText.setText(Styler.toSpannable(blocks, theme, night, config.typography))
        } finally {
            programmatic = false
        }
        editText.setSelection(caretAt.coerceIn(0, editText.text.length))
        onDocumentChanged(document())
        onStateChanged()
    }

    /**
     * Return focus (and the keyboard) to the document after a dialog or a
     * palette tap. Without this the caret is gone when the dialog closes, so
     * anything the tool just armed would be lost the moment the user taps back
     * in to carry on typing.
     */
    fun refocus() {
        editText.requestFocus()
        val imm = editText.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE)
            as? android.view.inputmethod.InputMethodManager
        imm?.showSoftInput(editText, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
    }

    /**
     * The caret moved. Armed marks survive contiguous typing but are dropped
     * the moment the user puts the cursor somewhere else — otherwise a bold
     * armed in one paragraph would leak into the next thing they type.
     */
    fun onCaretMoved() {
        if (inTextChange || programmatic) return
        if (pendingMarks != null && editText.selectionStart != pendingAnchor) {
            pendingMarks = null
            pendingAnchor = -1
        }
    }

    // ── change tracking ─────────────────────────────────────────────────────

    fun attachWatcher() {
        editText.addTextChangedListener(object : android.text.TextWatcher {
            private var insertedAt = -1
            private var insertedCount = 0

            override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {
                if (programmatic) return
                inTextChange = true
                pushUndo()
            }

            override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {
                if (programmatic) return
                insertedAt = start
                insertedCount = count
            }

            override fun afterTextChanged(s: android.text.Editable?) {
                if (programmatic || s == null) return
                programmatic = true
                try {
                    if (insertedCount > 0) {
                        styleInsertedText(s, insertedAt, insertedAt + insertedCount)
                    }
                    enforceMaxLength(s)
                    refreshBlockStyles(s)
                    renumberLists()
                } finally {
                    programmatic = false
                    inTextChange = false
                }
                emit()
            }
        })
    }

    /**
     * Newly typed text inherits the marks of the character to its left (so a
     * word typed inside a bold run stays bold), unless a toolbar toggle set an
     * explicit pending style. A typed newline additionally continues the block.
     */
    private fun styleInsertedText(s: android.text.Editable, start: Int, end: Int) {
        if (end <= start) return

        val newlineAt = (start until end).firstOrNull { s[it] == '\n' }
        // Armed marks apply only to text typed contiguously from the anchor;
        // anything else falls back to inheriting from the character to the left.
        val armed = pendingMarks?.takeIf { start == pendingAnchor }
        val marks = armed ?: inheritedMarks(s, start)

        // Clear any marks the platform copied onto the inserted range, then
        // apply exactly what we intend — otherwise pasted text keeps its
        // source styling and the document drifts from what the toolbar shows.
        for (span in s.getSpans(start, end, Any::class.java)) {
            if (span is SemanticSpan) {
                val spanStart = s.getSpanStart(span)
                val spanEnd = s.getSpanEnd(span)
                if (spanStart >= start && spanEnd <= end) s.removeSpan(span)
            }
        }
        Styler.applyMarks(s, start, end, marks, theme, night)

        if (armed != null) {
            // Keep the arming alive so the REST of the word gets it too.
            pendingAnchor = end
        } else {
            pendingMarks = null
            pendingAnchor = -1
        }

        if (newlineAt != null) continueBlockAfterNewline(s, newlineAt)
    }

    /**
     * Re-apply every paragraph's DISPLAY styling from its BlockSpan.
     *
     * A block applied to an EMPTY paragraph has nowhere to hang its size /
     * indent spans, so text typed afterwards would render as body text while
     * still serializing as a heading. Rebuilding the presentation spans after
     * each change keeps what the user sees and what they get in sync.
     */
    private fun refreshBlockStyles(s: android.text.Editable) {
        val whole = s.toString()
        var lineStart = 0

        while (lineStart <= whole.length) {
            val end = lineEnd(s, lineStart)
            val type = s.getSpans(lineStart, maxOf(lineStart, end), BlockSpan::class.java)
                .filter { s.getSpanStart(it) <= lineStart }
                .maxByOrNull { s.getSpanStart(it) }?.type

            if (type != null && end > lineStart) {
                stripDisplaySpans(s, lineStart, end)
                Styler.applyBlockStyle(s, lineStart, end, type, theme, night, config.typography)
            }

            if (end >= whole.length) break
            lineStart = end + 1
        }
    }

    /**
     * True when `span` belongs to the paragraph beginning at `start`, rather
     * than being the tail of the paragraph above it. Block and paragraph spans
     * extend over their terminating newline, so a naive range query returns
     * the previous paragraph's spans at every boundary.
     */
    private fun spanBelongsTo(text: android.text.Spanned, span: Any, start: Int): Boolean {
        val spanStart = text.getSpanStart(span)
        val spanEnd = text.getSpanEnd(span)
        return !(spanEnd <= start && spanStart < start)
    }

    /** Remove presentation-only spans in a range, leaving the document intact. */
    private fun stripDisplaySpans(s: android.text.Editable, start: Int, end: Int) {
        for (span in s.getSpans(start, end, Any::class.java)) {
            if (span is SemanticSpan || span is MarkerSpan) continue
            if (!spanBelongsTo(s, span, start)) continue
            if (span is BlockSpan ||
                span is android.text.style.AbsoluteSizeSpan ||
                span is android.text.style.LeadingMarginSpan ||
                span is android.text.style.StyleSpan ||
                span is android.text.style.ForegroundColorSpan
            ) {
                s.removeSpan(span)
            }
        }
    }

    private fun inheritedMarks(s: android.text.Editable, start: Int): MarkSet {
        if (start <= 0) return MarkSet()
        val builder = MarkBuilder()
        for (span in s.getSpans(start - 1, start, Any::class.java)) {
            if (span !is SemanticSpan) continue
            if (s.getSpanEnd(span) < start) continue
            when (span) {
                is BoldMarkSpan -> builder.bold = true
                is ItalicMarkSpan -> builder.italic = true
                is UnderlineMarkSpan -> builder.underline = true
                is StrikeMarkSpan -> builder.strike = true
                is CodeMarkSpan -> builder.code = true
                is ColorMarkSpan -> builder.color = span.hex
                is HighlightMarkSpan -> builder.highlight = span.hex
                // Links deliberately do NOT extend by typing at their edge.
                else -> Unit
            }
        }
        return builder.build()
    }

    /**
     * Enter inside a list continues it with a fresh marker; Enter on an EMPTY
     * list item exits the list instead (the behaviour every editor has).
     */
    private fun continueBlockAfterNewline(s: android.text.Editable, newlineAt: Int) {
        val previousStart = s.toString().lastIndexOf('\n', newlineAt - 1) + 1
        val previousType = s.getSpans(previousStart, newlineAt, BlockSpan::class.java)
            .filter { s.getSpanStart(it) <= previousStart }
            .maxByOrNull { s.getSpanStart(it) }?.type ?: "p"

        val previousContent = contentStart(s, previousStart, newlineAt)
        val previousIsEmptyItem = (previousType == "ul" || previousType == "ol") &&
            previousContent >= newlineAt

        if (previousIsEmptyItem) {
            // Exit the list: strip the marker and demote BOTH paragraphs.
            removeMarker(s, previousStart, newlineAt)
            val strippedEnd = s.toString().indexOf('\n', previousStart).let {
                if (it < 0) s.length else it
            }
            retype(s, previousStart, strippedEnd, "p")
            val nextStart = minOf(strippedEnd + 1, s.length)
            retype(s, nextStart, lineEnd(s, nextStart), "p")
            return
        }

        val nextStart = newlineAt + 1
        val nextEnd = lineEnd(s, nextStart)
        // Headings do not continue — Enter after a title starts body text.
        val continued = when (previousType) {
            "h1", "h2", "h3" -> "p"
            else -> previousType
        }
        retype(s, nextStart, nextEnd, continued)
    }

    // ── length cap ──────────────────────────────────────────────────────────

    /**
     * Trim back to the cap. Enforced here rather than with an InputFilter
     * because the cap counts PLAIN TEXT — list markers are chrome and must not
     * consume the user's budget.
     */
    private fun enforceMaxLength(s: android.text.Editable) {
        if (config.maxLength <= 0) return
        var guard = 0
        while (plainLength() > config.maxLength && s.isNotEmpty() && guard < 4096) {
            val cursor = editText.selectionStart.coerceIn(0, s.length)
            val cut = (cursor - 1).coerceAtLeast(0)
            if (cut >= s.length) break
            s.delete(cut, cut + 1)
            guard++
        }
    }

    // ── undo / redo ─────────────────────────────────────────────────────────

    private fun pushUndo() {
        val now = android.os.SystemClock.uptimeMillis()
        // Coalesce a burst of keystrokes into one undo step.
        if (now - lastPushAt < 400 && undoStack.isNotEmpty()) return
        lastPushAt = now
        undoStack.addLast(snapshot())
        while (undoStack.size > 100) undoStack.removeFirst()
        redoStack.clear()
        onStateChanged()
    }

    private fun snapshot() = Snapshot(
        android.text.SpannableStringBuilder(editText.text),
        editText.selectionStart.coerceAtLeast(0),
    )

    private fun restore(snapshot: Snapshot) {
        programmatic = true
        try {
            editText.text = android.text.SpannableStringBuilder(snapshot.text)
            editText.setSelection(snapshot.selection.coerceIn(0, editText.text.length))
        } finally {
            programmatic = false
        }
        emit()
        onStateChanged()
    }

    fun undo() {
        val previous = undoStack.removeLastOrNull() ?: return
        redoStack.addLast(snapshot())
        restore(previous)
    }

    fun redo() {
        val next = redoStack.removeLastOrNull() ?: return
        undoStack.addLast(snapshot())
        restore(next)
    }

    // ── toolbar actions ─────────────────────────────────────────────────────

    /** Marks currently under the cursor / selection, for toolbar highlighting. */
    fun activeMarks(): MarkSet {
        pendingMarks?.let { return it }
        val text = editText.text
        val start = editText.selectionStart.coerceIn(0, text.length)
        val end = editText.selectionEnd.coerceIn(0, text.length)
        if (start == end) return inheritedMarks(text, start)

        // A mark is "active" for a selection only when it covers all of it.
        var result: MarkSet? = null
        var i = start
        while (i < end) {
            val next = text.nextSpanTransition(i, end, android.text.style.CharacterStyle::class.java)
            val segment = marksOf(text, i, minOf(next, end))
            result = if (result == null) segment else intersect(result, segment)
            i = minOf(next, end)
        }
        return result ?: MarkSet()
    }

    private fun marksOf(text: android.text.Spanned, start: Int, end: Int): MarkSet {
        val builder = MarkBuilder()
        for (span in text.getSpans(start, end, Any::class.java)) {
            if (span !is SemanticSpan) continue
            if (text.getSpanStart(span) > start || text.getSpanEnd(span) < end) continue
            when (span) {
                is BoldMarkSpan -> builder.bold = true
                is ItalicMarkSpan -> builder.italic = true
                is UnderlineMarkSpan -> builder.underline = true
                is StrikeMarkSpan -> builder.strike = true
                is CodeMarkSpan -> builder.code = true
                is ColorMarkSpan -> builder.color = span.hex
                is HighlightMarkSpan -> builder.highlight = span.hex
                is LinkMarkSpan -> builder.link = span.url
            }
        }
        return builder.build()
    }

    private fun intersect(a: MarkSet, b: MarkSet) = MarkSet(
        link = if (a.link == b.link) a.link else null,
        color = if (a.color == b.color) a.color else null,
        highlight = if (a.highlight == b.highlight) a.highlight else null,
        bold = a.bold && b.bold,
        italic = a.italic && b.italic,
        underline = a.underline && b.underline,
        strike = a.strike && b.strike,
        code = a.code && b.code,
    )

    /** Block type of the paragraph holding the cursor. */
    fun activeBlock(): String {
        val text = editText.text
        val cursor = editText.selectionStart.coerceIn(0, text.length)
        val start = text.toString().lastIndexOf('\n', (cursor - 1).coerceAtLeast(0))
            .let { if (it < 0) 0 else it + 1 }
        val end = lineEnd(text, start)
        return text.getSpans(start, maxOf(start, end), BlockSpan::class.java)
            .filter { text.getSpanStart(it) <= start }
            .maxByOrNull { text.getSpanStart(it) }?.type ?: "p"
    }

    fun toggleInline(tool: String) {
        val current = activeMarks()
        val next = when (tool) {
            "bold" -> current.copy(bold = !current.bold)
            "italic" -> current.copy(italic = !current.italic)
            "underline" -> current.copy(underline = !current.underline)
            "strikethrough" -> current.copy(strike = !current.strike)
            "code" -> current.copy(code = !current.code)
            else -> return
        }
        applyMarksToSelection(next)
    }

    /**
     * Backspace at the very start of a list item's content removes the WHOLE
     * marker and demotes the item to a paragraph — the standard editor
     * behaviour. Without this the caret nibbles into the marker text and
     * leaves a stray "•" or "1." behind. Returns true when it handled the key.
     */
    fun handleBackspace(): Boolean {
        val text = editText.text
        val caret = editText.selectionStart
        if (caret != editText.selectionEnd) return false
        // At the very start there is nothing here to delete — the document
        // may still want to remove a media card sitting above this segment.
        if (caret == 0) return onBackspaceAtStart?.invoke() == true
        if (caret < 0) return false

        val whole = text.toString()
        val lineStart = whole.lastIndexOf('\n', caret - 1).let { if (it < 0) 0 else it + 1 }
        val lineEnd = lineEnd(text, lineStart)
        val content = contentStart(text, lineStart, lineEnd)

        // Only when there IS a marker and the caret sits just after it.
        if (content <= lineStart || caret != content) return false

        pushUndoForced()
        programmatic = true
        try {
            removeMarker(text, lineStart, lineEnd)
            retype(text, lineStart, lineEnd(text, lineStart), "p")
            refreshBlockStyles(text)
            renumberLists()
        } finally {
            programmatic = false
        }
        editText.setSelection(lineStart.coerceIn(0, editText.text.length))
        emit()
        onStateChanged()
        return true
    }

    fun setColor(hex: String?) = applyMarksToSelection(activeMarks().copy(color = hex))

    fun setHighlight(hex: String?) = applyMarksToSelection(activeMarks().copy(highlight = hex))

    /**
     * With a selection, link it. With none, INSERT the URL as its own linked
     * text — the behaviour iOS has and the one Notes/Mail use. Arming a link
     * for text the user hasn't typed yet is both undiscoverable and divergent
     * across the two platforms.
     */
    fun setLink(url: String?) {
        val start = editText.selectionStart
        val end = editText.selectionEnd

        if (url != null && start == end) {
            insertLinkedText(url)
            return
        }
        applyMarksToSelection(activeMarks().copy(link = url))
    }

    private fun insertLinkedText(url: String) {
        pushUndoForced()
        val text = editText.text
        val at = editText.selectionStart.coerceIn(0, text.length)

        programmatic = true
        try {
            text.insert(at, url)
            val end = at + url.length
            // Drop anything the platform copied onto the inserted range, then
            // apply exactly the marks we intend.
            for (span in text.getSpans(at, end, Any::class.java)) {
                if (span !is SemanticSpan) continue
                if (text.getSpanStart(span) >= at && text.getSpanEnd(span) <= end) {
                    text.removeSpan(span)
                }
            }
            Styler.applyMarks(text, at, end, inheritedMarks(text, at).copy(link = url), theme, night)
            refreshBlockStyles(text)
        } finally {
            programmatic = false
        }

        editText.setSelection((at + url.length).coerceAtMost(editText.text.length))
        pendingMarks = null
        pendingAnchor = -1
        emit()
        onStateChanged()
    }

    fun clearFormat() = applyMarksToSelection(MarkSet())

    /** Current link under the cursor, for pre-filling the link dialog. */
    fun currentLink(): String? = activeMarks().link

    private fun applyMarksToSelection(marks: MarkSet) {
        val text = editText.text
        val start = editText.selectionStart.coerceIn(0, text.length)
        val end = editText.selectionEnd.coerceIn(0, text.length)

        if (start == end) {
            // Nothing selected — arm the style for what gets typed next.
            pendingMarks = marks
            pendingAnchor = start
            onStateChanged()
            return
        }

        pushUndoForced()
        programmatic = true
        try {
            for (span in text.getSpans(start, end, Any::class.java)) {
                if (span !is SemanticSpan) continue
                val spanStart = text.getSpanStart(span)
                val spanEnd = text.getSpanEnd(span)
                text.removeSpan(span)
                // Re-apply the parts of a partially-covered span we did not touch.
                if (spanStart < start) reapplySingle(text, span, spanStart, start)
                if (spanEnd > end) reapplySingle(text, span, end, spanEnd)
            }
            Styler.applyMarks(text, start, end, marks, theme, night)
        } finally {
            programmatic = false
        }
        emit()
        onStateChanged()
    }

    private fun reapplySingle(text: android.text.Spannable, span: Any, start: Int, end: Int) {
        if (end <= start) return
        val marks = when (span) {
            is BoldMarkSpan -> MarkSet(bold = true)
            is ItalicMarkSpan -> MarkSet(italic = true)
            is UnderlineMarkSpan -> MarkSet(underline = true)
            is StrikeMarkSpan -> MarkSet(strike = true)
            is CodeMarkSpan -> MarkSet(code = true)
            is ColorMarkSpan -> MarkSet(color = span.hex)
            is HighlightMarkSpan -> MarkSet(highlight = span.hex)
            is LinkMarkSpan -> MarkSet(link = span.url)
            else -> return
        }
        Styler.applyMarks(text, start, end, marks, theme, night)
    }

    /** Convert every paragraph touched by the selection; toggles back to "p". */
    fun applyBlock(tool: String) {
        val target = when (tool) {
            "h1", "h2", "h3" -> tool
            "bulletList" -> "ul"
            "orderedList" -> "ol"
            "blockquote" -> "blockquote"
            else -> return
        }
        val next = if (activeBlock() == target) "p" else target

        pushUndoForced()
        val text = editText.text
        programmatic = true
        try {
            for (range in paragraphRanges()) {
                removeMarker(text, range.first, range.second)
                val end = lineEnd(text, range.first)
                retype(text, range.first, end, next)
            }
            renumberLists()
        } finally {
            programmatic = false
        }
        emit()
        onStateChanged()
    }

    private fun pushUndoForced() {
        lastPushAt = 0L
        pushUndo()
    }

    private fun emit() = onDocumentChanged(document())

    // ── paragraph plumbing ──────────────────────────────────────────────────

    /** [start, end) of every paragraph the selection touches. */
    private fun paragraphRanges(): List<Pair<Int, Int>> {
        val text = editText.text
        val whole = text.toString()
        val selStart = editText.selectionStart.coerceIn(0, whole.length)
        val selEnd = editText.selectionEnd.coerceIn(0, whole.length)

        val ranges = mutableListOf<Pair<Int, Int>>()
        var lineStart = whole.lastIndexOf('\n', (selStart - 1).coerceAtLeast(0))
            .let { if (it < 0) 0 else it + 1 }

        while (lineStart <= whole.length) {
            val end = lineEnd(text, lineStart)
            ranges.add(lineStart to end)
            if (end >= selEnd || end >= whole.length) break
            lineStart = end + 1
        }
        return ranges
    }

    private fun lineEnd(text: CharSequence, start: Int): Int {
        val idx = text.toString().indexOf('\n', start)
        return if (idx < 0) text.length else idx
    }

    /** First index of real content in a paragraph (past any list marker). */
    private fun contentStart(text: android.text.Spanned, start: Int, end: Int): Int {
        if (end <= start) return start
        var result = start
        for (marker in text.getSpans(start, end, MarkerSpan::class.java)) {
            val markerEnd = text.getSpanEnd(marker)
            if (text.getSpanStart(marker) <= result && markerEnd > result) {
                result = minOf(markerEnd, end)
            }
        }
        return result
    }

    private fun removeMarker(text: android.text.Editable, start: Int, end: Int) {
        if (end <= start) return
        val markers = text.getSpans(start, end, MarkerSpan::class.java)
        for (marker in markers) {
            val markerStart = text.getSpanStart(marker)
            val markerEnd = text.getSpanEnd(marker)
            text.removeSpan(marker)
            if (markerEnd > markerStart) text.delete(markerStart, markerEnd)
        }
    }

    /** Restyle one paragraph as [type], inserting a list marker when needed. */
    private fun retype(text: android.text.Editable, start: Int, end: Int, type: String) {
        if (start > text.length) return
        val safeEnd = end.coerceIn(start, text.length)

        for (span in text.getSpans(start, maxOf(start, safeEnd), Any::class.java)) {
            if (span is SemanticSpan) continue
            // A block span covers its terminating newline, so the PREVIOUS
            // paragraph's span reaches this paragraph's start offset. Removing
            // it here would silently strip the type off the paragraph above.
            if (!spanBelongsTo(text, span, start)) continue
            if (span is BlockSpan || span is android.text.style.AbsoluteSizeSpan ||
                span is android.text.style.LeadingMarginSpan ||
                (span is android.text.style.StyleSpan) ||
                (span is android.text.style.ForegroundColorSpan)
            ) {
                text.removeSpan(span)
            }
        }

        var contentEnd = safeEnd
        if (type == "ul" || type == "ol") {
            val marker = Styler.markerFor(type, 1)
            text.insert(start, marker)
            text.setSpan(
                MarkerSpan(), start, start + marker.length,
                android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
            )
            contentEnd = safeEnd + marker.length
        }

        Styler.applyBlockStyle(
            text, start, contentEnd.coerceAtMost(text.length), type, theme, night, config.typography,
        )
    }

    /**
     * Rewrite every ordered-list marker so numbering is correct after any edit
     * that inserted, removed or re-typed items.
     */
    fun renumberLists() {
        val text = editText.text
        val whole = text.toString()
        var lineStart = 0
        var ordinal = 1
        var previousWasOrdered = false

        while (lineStart <= whole.length) {
            val end = lineEnd(text, lineStart)
            val type = text.getSpans(lineStart, maxOf(lineStart, end), BlockSpan::class.java)
                .filter { text.getSpanStart(it) <= lineStart }
                .maxByOrNull { text.getSpanStart(it) }?.type ?: "p"

            if (type == "ol") {
                if (!previousWasOrdered) ordinal = 1
                val expected = Styler.markerFor("ol", ordinal)
                val marker = text.getSpans(lineStart, maxOf(lineStart, end), MarkerSpan::class.java)
                    .firstOrNull()
                if (marker != null) {
                    val markerStart = text.getSpanStart(marker)
                    val markerEnd = text.getSpanEnd(marker)
                    if (whole.substring(markerStart, markerEnd) != expected) {
                        text.removeSpan(marker)
                        text.replace(markerStart, markerEnd, expected)
                        text.setSpan(
                            MarkerSpan(), markerStart, markerStart + expected.length,
                            android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE,
                        )
                        // The buffer shifted — restart the sweep rather than
                        // walking stale offsets.
                        renumberLists()
                        return
                    }
                }
                ordinal++
                previousWasOrdered = true
            } else {
                previousWasOrdered = false
            }

            if (end >= whole.length) break
            lineStart = end + 1
        }
    }
}

/**
 * A segment plus a STABLE id.
 *
 * Editor controllers are keyed by this rather than by list position, so
 * inserting media in the middle of a document does not silently re-point every
 * controller after it.
 */
internal class SegmentEntry(val id: Int, val segment: Segment)

// ── Palettes (normative — identical on iOS) ─────────────────────────────────

internal val TEXT_COLORS = listOf("#EF4444", "#F97316", "#EAB308", "#22C55E", "#3B82F6", "#A855F7")
internal val HIGHLIGHT_COLORS = listOf("#FDE68A", "#FED7AA", "#BBF7D0", "#BFDBFE", "#E9D5FF", "#FBCFE8")

// ── EditText subclass ───────────────────────────────────────────────────────

/** EditText that reports caret moves, so the toolbar can track active state. */
internal class WysiwygEditText(context: android.content.Context) :
    android.widget.EditText(context) {

    var onSelectionMoved: (() -> Unit)? = null

    /**
     * Invoked before a backspace is applied. Returning true consumes it —
     * used to delete a list marker as ONE unit instead of nibbling away its
     * characters and leaving a stray bullet behind.
     */
    var onBackspace: (() -> Boolean)? = null

    override fun onSelectionChanged(selStart: Int, selEnd: Int) {
        super.onSelectionChanged(selStart, selEnd)
        onSelectionMoved?.invoke()
    }

    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if (keyCode == android.view.KeyEvent.KEYCODE_DEL && onBackspace?.invoke() == true) {
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    /**
     * Soft keyboards usually delete via `deleteSurroundingText` rather than a
     * DEL key event, so the interception has to happen on the input connection
     * as well — otherwise this works with a hardware keyboard only.
     */
    override fun onCreateInputConnection(
        outAttrs: android.view.inputmethod.EditorInfo,
    ): android.view.inputmethod.InputConnection? {
        val target = super.onCreateInputConnection(outAttrs) ?: return null

        return object : android.view.inputmethod.InputConnectionWrapper(target, true) {
            override fun deleteSurroundingText(beforeLength: Int, afterLength: Int): Boolean {
                if (beforeLength == 1 && afterLength == 0 && onBackspace?.invoke() == true) {
                    return true
                }
                return super.deleteSurroundingText(beforeLength, afterLength)
            }

            override fun sendKeyEvent(event: android.view.KeyEvent): Boolean {
                if (event.action == android.view.KeyEvent.ACTION_DOWN &&
                    event.keyCode == android.view.KeyEvent.KEYCODE_DEL &&
                    onBackspace?.invoke() == true
                ) {
                    return true
                }
                return super.sendKeyEvent(event)
            }
        }
    }
}

// ── Screen ──────────────────────────────────────────────────────────────────

@Composable
internal fun EditorScreen(
    activity: FragmentActivity,
    config: WysiwygEditorFunctions.EditorConfig,
    initialBlocks: List<WysiwygBlock>,
    onDocumentChanged: (List<WysiwygBlock>) -> Unit,
    onCancel: () -> Unit,
    onSave: () -> Unit,
    onRequestMedia: (String) -> Unit,
) {
    val night = isSystemInDarkTheme()
    val theme = config.theme
    val background = theme.backgroundColor(night)
    val foreground = theme.textColor(night)
    val accent = theme.accentColor(night)

    // One controller per TEXT segment; the toolbar drives the focused one.
    val controllers = remember { mutableMapOf<Int, EditorController>() }
    val focused = remember { mutableStateOf<EditorController?>(null) }
    // Bumped on every edit / caret move so the toolbar re-reads active state.
    val revision = remember { mutableStateOf(0) }
    val palette = remember { mutableStateOf<String?>(null) }
    /** Which bottom sheet is open, in `menu: sheet` mode. */
    val sheet = remember { mutableStateOf<String?>(null) }
    val length = remember { mutableStateOf(initialBlocks.sumOf { it.plainText.length }) }
    val words = remember { mutableStateOf(countWords(initialBlocks)) }

    Box(modifier = Modifier.fillMaxSize()) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(background)
                .systemBarsPadding()
                .imePadding(),
        ) {
            // ── Top bar ─────────────────────────────────────────────────────────
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 8.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                BarButton(
                    localized(config.strings, "cancel", "Cancel"),
                    foreground.copy(alpha = 0.8f), FontWeight.Normal, onCancel,
                )
                Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.Center) {
                    if (config.title.isNotEmpty()) {
                        BasicText(
                            text = config.title,
                            style = TextStyle(color = foreground, fontSize = 16.sp, fontWeight = FontWeight.SemiBold),
                        )
                    }
                }
                BarButton(localized(config.strings, "save", "Save"), accent, FontWeight.SemiBold, onSave)
            }

            // ── Editor: one view per segment ─────────────────────────────────────
            val nextId = remember { intArrayOf(0) }
            val entries = remember {
                androidx.compose.runtime.mutableStateListOf<SegmentEntry>().also { list ->
                    segmentsOf(initialBlocks).forEach { list.add(SegmentEntry(nextId[0]++, it)) }
                }
            }

            /** Reassemble the whole document from every segment's live state. */
            fun rebuildDocument() {
                val out = mutableListOf<WysiwygBlock>()
                for (entry in entries) {
                    when (val segment = entry.segment) {
                        is Segment.Text -> out.addAll(controllers[entry.id]?.document() ?: segment.blocks)
                        is Segment.Media -> out.add(segment.block)
                    }
                }
                onDocumentChanged(out)
                length.value = out.sumOf { it.plainText.length }
                words.value = countWords(out)
            }

            /**
             * Backspace pressed at the very start of the text segment [entryId].
             *
             * If a media card sits directly above, it is deleted — matching what
             * Notes and Docs do, where backspacing into an image removes it rather
             * than doing nothing. When that leaves two text segments touching they
             * merge into one and the caret lands on the join.
             *
             * Returns true when the keystroke was consumed.
             */
            fun handleBackspaceAtStart(entryId: Int): Boolean {
                val index = entries.indexOfFirst { it.id == entryId }
                if (index <= 0) return false
                if (entries[index - 1].segment !is Segment.Media) return false

                entries.removeAt(index - 1)
                val position = index - 1

                // Two text segments are now adjacent — fold the lower one into the
                // upper one so the document keeps ONE editor per run of text.
                val above = entries.getOrNull(position - 1)
                val aboveController = above?.let { controllers[it.id] }
                val mine = controllers[entryId]
                if (above != null && above.segment is Segment.Text && aboveController != null && mine != null) {
                    val join = aboveController.styledLength() + 1
                    aboveController.replaceDocument(aboveController.document() + mine.document(), join)
                    controllers.remove(entryId)
                    entries.removeAt(position)
                    focused.value = aboveController
                    aboveController.refocus()
                }

                rebuildDocument()
                revision.value++
                return true
            }

            // Expose this editor to the media bridge functions while it is open.
            androidx.compose.runtime.DisposableEffect(Unit) {
                WysiwygEditorFunctions.live = object : WysiwygEditorFunctions.LiveEditor {
                    override fun insertMedia(kind: String, attrs: Map<String, String>) {
                        val block = WysiwygBlock(kind)
                        attrs.forEach { (key, value) -> block.attrs[key] = value }
                        // Place it after the focused segment, then give the user a
                        // fresh paragraph below so typing can continue.
                        val at = entries.indexOfFirst { controllers[it.id] === focused.value }
                        val insertAt = if (at >= 0) at + 1 else entries.size
                        entries.add(insertAt, SegmentEntry(nextId[0]++, Segment.Media(block)))
                        entries.add(
                            insertAt + 1,
                            SegmentEntry(nextId[0]++, Segment.Text(mutableListOf(WysiwygBlock("p")))),
                        )
                        rebuildDocument()
                    }

                    override fun updateUpload(uploadId: String, state: String, src: String, message: String) {
                        val index = entries.indexOfFirst { entry ->
                            (entry.segment as? Segment.Media)?.block?.attrs?.get("uploadId") == uploadId
                        }
                        if (index < 0) return
                        val block = (entries[index].segment as Segment.Media).block
                        when (state) {
                            "completed" -> {
                                if (src.isNotEmpty()) block.attrs["src"] = src
                                block.attrs.remove("uploadId")
                            }
                            "failed" -> block.attrs["uploadError"] = message.ifEmpty { "Upload failed" }
                            else -> block.attrs["uploadProgress"] = src
                        }
                        // Swap the entry so Compose sees a change.
                        entries[index] = SegmentEntry(entries[index].id, Segment.Media(block))
                        rebuildDocument()
                    }
                }
                onDispose { WysiwygEditorFunctions.live = null }
            }

            Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .verticalScroll(rememberScrollState()),
                ) {
                    entries.forEachIndexed { index, entry ->
                        when (val segment = entry.segment) {
                            is Segment.Media -> MediaCard(segment.block, foreground, accent, config.strings)
                            is Segment.Text -> AndroidView(
                                modifier = Modifier.fillMaxWidth(),
                                factory = { context ->
                                    WysiwygEditText(context).apply {
                                        setBackgroundColor(android.graphics.Color.TRANSPARENT)
                                        gravity = Gravity.TOP or Gravity.START
                                        setTextSize(
                                            TypedValue.COMPLEX_UNIT_SP,
                                            config.typography.base.toFloat(),
                                        )
                                        config.typography.typeface()?.let { typeface = it }
                                        setTextColor(foreground.toArgb())
                                        setHintTextColor(foreground.copy(alpha = 0.38f).toArgb())
                                        setLineSpacing(0f, config.typography.lineHeight)
                                        // Only the first segment shows the placeholder.
                                        if (index == 0) hint = config.placeholder
                                        // dp, not raw px — until now this was
                                        // pixels, which made Android visibly
                                        // tighter than iOS on the same document.
                                        val dp = resources.displayMetrics.density
                                        setPadding(
                                            (config.spacing.horizontal * dp).toInt(),
                                            (config.spacing.vertical * dp).toInt(),
                                            (config.spacing.horizontal * dp).toInt(),
                                            (config.spacing.vertical * dp).toInt(),
                                        )
                                        inputType = android.text.InputType.TYPE_CLASS_TEXT or
                                            android.text.InputType.TYPE_TEXT_FLAG_MULTI_LINE or
                                            android.text.InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                                        setText(
                                            Styler.toSpannable(
                                                segment.blocks, theme, night, config.typography,
                                            ),
                                        )

                                        val controller = EditorController(
                                            editText = this,
                                            config = config,
                                            night = night,
                                            onDocumentChanged = { rebuildDocument() },
                                            onStateChanged = { revision.value++ },
                                        )
                                        controller.attachWatcher()
                                        controllers[entry.id] = controller
                                        if (focused.value == null) focused.value = controller

                                        onSelectionMoved = { controller.onCaretMoved(); revision.value++ }
                                        controller.onBackspaceAtStart = {
                                            handleBackspaceAtStart(entry.id)
                                        }
                                        onBackspace = { controller.handleBackspace() }
                                        // The toolbar acts on whichever segment has
                                        // the caret.
                                        setOnFocusChangeListener { _, hasFocus ->
                                            if (hasFocus) {
                                                focused.value = controller
                                                revision.value++
                                            }
                                        }

                                        isFocusable = true
                                        isFocusableInTouchMode = true

                                        if (index == 0) {
                                            requestFocus()
                                            // Deferred: at factory time the view is
                                            // not attached yet, so requestFocus
                                            // alone does not raise the IME.
                                            postDelayed({
                                                requestFocus()
                                                val imm = context.getSystemService(
                                                    android.content.Context.INPUT_METHOD_SERVICE,
                                                ) as? android.view.inputmethod.InputMethodManager
                                                imm?.showSoftInput(
                                                    this,
                                                    android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT,
                                                )
                                            }, 250)
                                        }
                                    }
                                },
                            )
                        }
                    }
                }
            }

            // ── Counts readout ──────────────────────────────────────────────────
            val readout = countsReadout(config, length.value, words.value)
            if (readout.isNotEmpty()) {
                val over = config.maxLength > 0 && length.value >= config.maxLength
                Row(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
                    horizontalArrangement = androidx.compose.foundation.layout.Arrangement.End,
                ) {
                    BasicText(
                        text = readout,
                        style = TextStyle(
                            color = if (over) Color(0xFFEF4444) else foreground.copy(alpha = 0.45f),
                            fontSize = 12.sp,
                        ),
                    )
                }
            }

            // ── Colour palette (shown while a colour tool is armed) ─────────────
            palette.value?.let { kind ->
                PaletteRow(
                    colors = if (kind == "textColor") TEXT_COLORS else HIGHLIGHT_COLORS,
                    foreground = foreground,
                    onPick = { hex ->
                        val c = focused.value
                        if (kind == "textColor") c?.setColor(hex) else c?.setHighlight(hex)
                        palette.value = null
                        c?.refocus()
                    },
                )
            }

            // ── Formatting toolbar ──────────────────────────────────────────────
            ToolbarRow(
                activity = activity,
                config = config,
                controllerState = focused,
                revision = revision.value,
                palette = palette,
                foreground = foreground,
                background = background,
                highlightColor = theme.highlightColor(night),
                strings = config.strings,
                haptics = config.haptics,
                onRequestMedia = onRequestMedia,
                sheet = sheet,
            )
        }

        // ── Bottom sheets (menu: sheet) ─────────────────────────────────────
        // Drawn OVER the toolbar, so the sheet is not clipped by the column
        // and the scrim covers the whole screen.
        sheet.value?.let { kind ->
            val controller = focused.value
            val marks = controller?.activeMarks() ?: MarkSet()
            val activeBlock = controller?.activeBlock() ?: "p"
            @Suppress("UNUSED_EXPRESSION") revision.value

            fun run(tool: String) {
                when (tool) {
                    "textColor", "highlight" -> {
                        palette.value = tool
                        sheet.value = null
                    }
                    "link" -> {
                        sheet.value = null
                        runTool(tool, controller, palette, activity, config.strings, onRequestMedia)
                    }
                    in WysiwygEditorFunctions.INSERT_TOOLS -> {
                        sheet.value = null
                        onRequestMedia(tool)
                    }
                    else -> runTool(tool, controller, palette, activity, config.strings, onRequestMedia)
                }
            }

            @Composable
            fun row(tool: String, label: String? = null) {
                SheetRow(
                    tool = tool,
                    label = label ?: localized(config.strings, TOOL_LABEL_KEYS[tool] ?: tool, tool),
                    active = isToolActive(tool, marks, activeBlock, palette.value),
                    foreground = foreground,
                    highlight = theme.highlightColor(night),
                    haptics = config.haptics,
                ) { run(tool) }
            }

            // Only tools the host enabled appear, and an empty section is not
            // drawn — the sheet reflects the config, not everything we can do.
            fun enabled(tools: List<String>) = tools.filter { it in config.toolbar }

            if (kind == "format") {
                WysiwygSheet(
                    title = localized(config.strings, "menuFormat", "Format"),
                    background = background,
                    foreground = foreground,
                    onDismiss = { sheet.value = null },
                ) {
                    SheetSection(localized(config.strings, "sectionTextStyle", "Text style"), foreground)
                    // Body is always offered: without it there is no way back
                    // to plain text once a heading has been applied.
                    row("p", localized(config.strings, "styleBody", "Body"))
                    enabled(SHEET_TEXT_STYLE_TOOLS).forEach { row(it) }

                    val lists = enabled(SHEET_LIST_TOOLS)
                    if (lists.isNotEmpty()) {
                        SheetSection(localized(config.strings, "sectionLists", "Lists"), foreground)
                        lists.forEach { row(it) }
                    }

                    val marksTools = enabled(SHEET_FORMAT_TOOLS)
                    if (marksTools.isNotEmpty()) {
                        SheetSection(localized(config.strings, "sectionFormat", "Formatting"), foreground)
                        marksTools.forEach { row(it) }
                    }
                }
            } else {
                WysiwygSheet(
                    title = localized(config.strings, "menuInsert", "Insert"),
                    background = background,
                    foreground = foreground,
                    onDismiss = { sheet.value = null },
                ) {
                    enabled(SHEET_INSERT_TOOLS).forEach { row(it) }
                }
            }
        }
    }
}

/**
 * The readout beneath the content. `maxLength` always shows as "n/max" (it is
 * a limit, not a statistic); the optional `counts` add statistics beside it.
 */
internal fun countsReadout(
    config: WysiwygEditorFunctions.EditorConfig,
    characters: Int,
    words: Int,
): String {
    val parts = mutableListOf<String>()

    if (config.maxLength > 0) {
        parts.add("$characters/${config.maxLength}")
    } else if (config.counts.contains("characters")) {
        parts.add(localized(config.strings, "countCharacters", "{n} chars", n = characters))
    }
    if (config.counts.contains("words")) {
        parts.add(localized(config.strings, "countWords", "{n} words", n = words))
    }
    if (config.counts.contains("readingTime")) {
        val minutes = maxOf(1, Math.ceil(words / 200.0).toInt())
        parts.add(localized(config.strings, "countReadingTime", "{n} min", n = minutes))
    }

    return parts.joinToString("  ·  ")
}

/**
 * Decode an image for a media card.
 *
 * Handles a local file (what the picker/cropper hands us) and an http(s) URL
 * (what a re-opened, already-uploaded document contains). Downsampled so a
 * full-resolution camera photo cannot blow up memory in a scrolling document.
 * Hand-rolled rather than pulling in an image library — the plugin stays
 * dependency-free, like the rest of it.
 */
internal fun decodeMediaImage(source: String, maxPixels: Int = 1200): android.graphics.Bitmap? {
    return try {
        val bytes: ByteArray = if (source.startsWith("http://", true) || source.startsWith("https://", true)) {
            val connection = (java.net.URL(source).openConnection() as java.net.HttpURLConnection).apply {
                connectTimeout = 8000
                readTimeout = 8000
                instanceFollowRedirects = true
            }
            try {
                if (connection.responseCode !in 200..299) return null
                connection.inputStream.readBytes()
            } finally {
                connection.disconnect()
            }
        } else {
            val file = java.io.File(source.removePrefix("file://"))
            if (!file.exists()) return null
            file.readBytes()
        }

        val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
        android.graphics.BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > maxPixels) sample *= 2

        android.graphics.BitmapFactory.decodeByteArray(
            bytes, 0, bytes.size,
            android.graphics.BitmapFactory.Options().apply { inSampleSize = sample },
        )
    } catch (e: Exception) {
        Log.w("WysiwygEditor", "media decode failed for $source: ${e.message}")
        null
    }
}

/**
 * A media block inside the document.
 *
 * Deliberately NOT editable text: it renders the block and its pending upload
 * state. Decoding actual image bytes is the next step; today it shows what the
 * block is, its caption, and whether it is still uploading — which is what the
 * shell needs to prove.
 */
/**
 * Which toolbar glyph stands in for a block on its card. Normative — the iOS
 * card uses the same mapping, so a document looks the same on both.
 */
internal fun cardIconKey(type: String): String = when (type) {
    "image" -> "image"
    "video" -> "video"
    "file" -> "file"
    "embed" -> "link"
    "poll" -> "orderedList"
    else -> "bulletList"
}

@Composable
private fun MediaCard(
    block: WysiwygBlock,
    foreground: Color,
    accent: Color,
    strings: Map<String, String> = emptyMap(),
) {
    if (block.type == "divider") {
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 14.dp)
                .height(1.dp)
                .background(foreground.copy(alpha = 0.25f)),
        )
        return
    }

    val pending = (block.attrs["src"].orEmpty().isEmpty() &&
        block.attrs["uploadId"].orEmpty().isNotEmpty())

    val label = when (block.type) {
        "image" -> block.attrs["alt"]?.takeIf { it.isNotEmpty() } ?: "Image"
        "video" -> "Video"
        "file" -> block.attrs["name"]?.takeIf { it.isNotEmpty() } ?: "File"
        "embed" -> block.attrs["url"].orEmpty()
        "poll" -> block.attrs["question"]?.takeIf { it.isNotEmpty() } ?: "Poll"
        else -> block.type
    }
    val caption = block.attrs["caption"].orEmpty()

    // Prefer the public url; fall back to the local file so a freshly picked
    // image shows immediately, before any upload finishes.
    val source = block.attrs["src"]?.takeIf { it.isNotEmpty() }
        ?: block.attrs["localPath"].orEmpty()
    val bitmap = androidx.compose.runtime.remember(source) {
        androidx.compose.runtime.mutableStateOf<android.graphics.Bitmap?>(null)
    }

    if (source.isNotEmpty() && (block.type == "image" || block.type == "video")) {
        LaunchedEffect(source) {
            val decoded = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                decodeMediaImage(if (block.type == "video") block.attrs["poster"].orEmpty().ifEmpty { source } else source)
            }
            bitmap.value = decoded
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(foreground.copy(alpha = 0.06f))
            .padding(horizontal = 14.dp, vertical = 14.dp),
    ) {
        bitmap.value?.let { image ->
            Image(
                bitmap = image.asImageBitmap(),
                contentDescription = block.attrs["alt"].orEmpty(),
                contentScale = ContentScale.FillWidth,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(8.dp)),
            )
            Box(modifier = Modifier.height(10.dp))
        }

        Row(verticalAlignment = Alignment.CenterVertically) {
            Canvas(modifier = Modifier.size(20.dp)) {
                val icon = TOOL_ICONS[cardIconKey(block.type)]
                if (icon != null) {
                    drawPath(
                        path = buildIconPath(icon.path, size.width),
                        color = accent,
                        style = Stroke(width = 2f * size.width / 24f, cap = StrokeCap.Round, join = StrokeJoin.Round),
                    )
                }
            }
            Box(modifier = Modifier.width(10.dp))
            BasicText(
                text = label,
                style = TextStyle(color = foreground, fontSize = 15.sp, fontWeight = FontWeight.Medium),
            )
        }

        if (block.type == "poll" && block.options.isNotEmpty()) {
            for (option in block.options) {
                Box(modifier = Modifier.height(6.dp))
                BasicText(
                    text = "•  ${option.label}",
                    style = TextStyle(color = foreground.copy(alpha = 0.75f), fontSize = 14.sp),
                )
            }
        }

        if (caption.isNotEmpty()) {
            Box(modifier = Modifier.height(6.dp))
            BasicText(
                text = caption,
                style = TextStyle(color = foreground.copy(alpha = 0.6f), fontSize = 13.sp),
            )
        }

        if (pending) {
            Box(modifier = Modifier.height(6.dp))
            BasicText(
                text = localized(strings, "uploading", "Uploading…"),
                style = TextStyle(color = accent, fontSize = 12.sp, fontWeight = FontWeight.Medium),
            )
        }
    }
}

@Composable
private fun BarButton(label: String, color: Color, weight: FontWeight, onClick: () -> Unit) {
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 6.dp),
    ) {
        BasicText(text = label, style = TextStyle(color = color, fontSize = 16.sp, fontWeight = weight))
    }
}

// ── Toolbar ─────────────────────────────────────────────────────────────────

/**
 * Which string key labels each tool in a bottom sheet.
 *
 * Mirrors `WysiwygEditor::TOOL_LABEL_KEYS` in PHP and `toolLabelKeys` in
 * Swift — headings and quote read as text STYLES, so they take the `style*`
 * keys and sit in their own section.
 */
internal val TOOL_LABEL_KEYS = mapOf(
    "bold" to "toolBold",
    "italic" to "toolItalic",
    "underline" to "toolUnderline",
    "strikethrough" to "toolStrikethrough",
    "h1" to "styleH1",
    "h2" to "styleH2",
    "h3" to "styleH3",
    "bulletList" to "toolBulletList",
    "orderedList" to "toolOrderedList",
    "blockquote" to "styleQuote",
    "link" to "toolLink",
    "code" to "toolCode",
    "textColor" to "toolTextColor",
    "highlight" to "toolHighlight",
    "image" to "toolImage",
    "video" to "toolVideo",
    "file" to "toolFile",
    "clearFormat" to "toolClearFormat",
)

/** Sheet sections, in display order. Normative — Swift uses the same lists. */
internal val SHEET_TEXT_STYLE_TOOLS = listOf("h1", "h2", "h3", "blockquote")
internal val SHEET_LIST_TOOLS = listOf("bulletList", "orderedList")
internal val SHEET_FORMAT_TOOLS =
    listOf("bold", "italic", "underline", "strikethrough", "code", "textColor", "highlight", "clearFormat")
internal val SHEET_INSERT_TOOLS = listOf("image", "video", "file", "link")

/**
 * The tick drawn beside an active row. Same 24x24 grid as the tool glyphs,
 * and the same path string on iOS.
 */
internal const val CHECK_ICON_PATH = "M5 13L9 17L19 7"

/**
 * Whether [tool] is currently in effect. Shared by the toolbar and the sheets,
 * so a tool cannot look active in one and inactive in the other.
 */
internal fun isToolActive(tool: String, marks: MarkSet, block: String, palette: String?): Boolean =
    when (tool) {
        "bold" -> marks.bold
        "italic" -> marks.italic
        "underline" -> marks.underline
        "strikethrough" -> marks.strike
        "code" -> marks.code
        "link" -> marks.link != null
        "textColor" -> marks.color != null || palette == "textColor"
        "highlight" -> marks.highlight != null || palette == "highlight"
        "h1", "h2", "h3", "blockquote" -> block == tool
        "bulletList" -> block == "ul"
        "orderedList" -> block == "ol"
        "p" -> block !in listOf("h1", "h2", "h3", "ul", "ol", "blockquote")
        else -> false
    }

@Composable
private fun ToolbarRow(
    activity: FragmentActivity,
    config: WysiwygEditorFunctions.EditorConfig,
    controllerState: androidx.compose.runtime.MutableState<EditorController?>,
    revision: Int,
    palette: androidx.compose.runtime.MutableState<String?>,
    foreground: Color,
    background: Color,
    highlightColor: Color,
    strings: Map<String, String>,
    haptics: Boolean,
    onRequestMedia: (String) -> Unit,
    sheet: androidx.compose.runtime.MutableState<String?> =
        androidx.compose.runtime.mutableStateOf(null),
) {
    val controller = controllerState.value
    // Reading `revision` here is what makes the bar recompose on caret moves.
    @Suppress("UNUSED_EXPRESSION") revision

    val marks = controller?.activeMarks() ?: MarkSet()
    val block = controller?.activeBlock() ?: "p"
    // Passed in: the toolbar has no colour-scheme of its own.

    Column(modifier = Modifier.fillMaxWidth().background(background)) {
        Box(modifier = Modifier.fillMaxWidth().height(1.dp).background(foreground.copy(alpha = 0.12f)))
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            ToolButton("undo", false, controller?.canUndo == true, foreground, highlightColor, haptics) {
                controller?.undo()
            }
            ToolButton("redo", false, controller?.canRedo == true, foreground, highlightColor, haptics) {
                controller?.redo()
            }
            Box(
                modifier = Modifier
                    .padding(horizontal = 6.dp)
                    .width(1.dp)
                    .height(22.dp)
                    .background(foreground.copy(alpha = 0.15f)),
            )

            // Sheet mode keeps the marks people reach for constantly one tap
            // away and puts the rest behind Format / Insert, rather than off
            // the right edge of a bar nobody scrolls.
            val shown = if (config.menu == "sheet") {
                config.toolbar.filter { it == "bold" || it == "italic" }
            } else {
                config.toolbar
            }

            for (tool in shown) {
                ToolButton(
                    tool,
                    isToolActive(tool, marks, block, palette.value),
                    true,
                    foreground,
                    highlightColor,
                    haptics,
                ) {
                    runTool(tool, controller, palette, activity, strings, onRequestMedia)
                }
            }

            if (config.menu == "sheet") {
                val formatTools = SHEET_TEXT_STYLE_TOOLS + SHEET_LIST_TOOLS + SHEET_FORMAT_TOOLS
                if (config.toolbar.any { it in formatTools }) {
                    LabelledToolButton(
                        "textColor",
                        localized(strings, "menuFormat", "Format"),
                        sheet.value == "format",
                        foreground,
                        highlightColor,
                        haptics,
                    ) { sheet.value = if (sheet.value == "format") null else "format" }
                }
                if (config.toolbar.any { it in SHEET_INSERT_TOOLS }) {
                    LabelledToolButton(
                        "image",
                        localized(strings, "menuInsert", "Insert"),
                        sheet.value == "insert",
                        foreground,
                        highlightColor,
                        haptics,
                    ) { sheet.value = if (sheet.value == "insert") null else "insert" }
                }
            }
        }
    }
}

/**
 * Run a tool. Shared by the toolbar and both sheets so a tool cannot behave
 * differently depending on where it was tapped from.
 */
private fun runTool(
    tool: String,
    controller: EditorController?,
    palette: androidx.compose.runtime.MutableState<String?>,
    activity: FragmentActivity,
    strings: Map<String, String>,
    onRequestMedia: (String) -> Unit,
) {
    when (tool) {
        "bold", "italic", "underline", "strikethrough", "code" -> controller?.toggleInline(tool)
        "p", "h1", "h2", "h3", "bulletList", "orderedList", "blockquote" -> controller?.applyBlock(tool)
        "clearFormat" -> controller?.clearFormat()
        in WysiwygEditorFunctions.INSERT_TOOLS -> onRequestMedia(tool)
        "textColor" -> palette.value = if (palette.value == "textColor") null else "textColor"
        "highlight" -> palette.value = if (palette.value == "highlight") null else "highlight"
        "link" -> controller?.let { c ->
            showLinkDialog(activity, c.currentLink(), strings, onDismiss = { c.refocus() }) { url ->
                c.setLink(url)
            }
        }
    }
}

/**
 * A wider button carrying a glyph AND a word — used for Format / Insert, where
 * an icon alone would not say which sheet opens.
 */
@Composable
private fun LabelledToolButton(
    icon: String,
    label: String,
    active: Boolean,
    foreground: Color,
    highlight: Color,
    haptics: Boolean,
    onClick: () -> Unit,
) {
    val view = androidx.compose.ui.platform.LocalView.current
    val tint = if (active) highlight else foreground.copy(alpha = 0.78f)
    val path = TOOL_ICONS[icon]

    Row(
        modifier = Modifier
            .height(34.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (active) highlight.copy(alpha = 0.16f) else Color.Transparent)
            .clickable {
                if (haptics) {
                    view.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                }
                onClick()
            }
            .padding(horizontal = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(6.dp),
    ) {
        if (path != null) {
            Canvas(modifier = Modifier.size(18.dp)) {
                drawPath(
                    path = buildIconPath(path.path, size.width),
                    color = tint,
                    style = Stroke(
                        width = path.stroke * size.width / 24f,
                        cap = StrokeCap.Round,
                        join = StrokeJoin.Round,
                    ),
                )
            }
        }
        BasicText(
            text = label,
            style = TextStyle(color = tint, fontSize = 15.sp, fontWeight = FontWeight.Medium),
        )
    }
}

@Composable
private fun ToolButton(
    tool: String,
    active: Boolean,
    enabled: Boolean,
    foreground: Color,
    highlight: Color,
    haptics: Boolean = true,
    onClick: () -> Unit,
) {
    val view = androidx.compose.ui.platform.LocalView.current
    val icon = TOOL_ICONS[tool] ?: return
    val tint = when {
        active -> highlight
        enabled -> foreground.copy(alpha = 0.78f)
        else -> foreground.copy(alpha = 0.28f)
    }

    Box(
        modifier = Modifier
            .size(38.dp)
            .clip(RoundedCornerShape(8.dp))
            .background(if (active) highlight.copy(alpha = 0.16f) else Color.Transparent)
            .clickable(enabled = enabled) {
                // A toggle you cannot see the result of (bold with no
                // selection) should still feel like it happened.
                if (haptics) {
                    view.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                }
                onClick()
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(modifier = Modifier.size(21.dp)) {
            drawPath(
                path = buildIconPath(icon.path, size.width),
                color = tint,
                style = Stroke(
                    width = icon.stroke * size.width / 24f,
                    cap = StrokeCap.Round,
                    join = StrokeJoin.Round,
                ),
            )
        }
    }
}

/**
 * A hand-rolled bottom sheet: scrim plus a panel anchored to the bottom.
 *
 * Deliberately not `ModalBottomSheet`, so the panel is directly comparable
 * with the iOS one — same corner radius, same grabber, same row metrics.
 */
@Composable
private fun WysiwygSheet(
    title: String,
    background: Color,
    foreground: Color,
    onDismiss: () -> Unit,
    content: @Composable () -> Unit,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.35f))
            .clickable(
                indication = null,
                interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
            ) { onDismiss() },
        contentAlignment = Alignment.BottomCenter,
    ) {
        val screenHeight = androidx.compose.ui.platform.LocalConfiguration.current.screenHeightDp.dp

        Column(
            modifier = Modifier
                .fillMaxWidth()
                // A bottom sheet that grows to the full screen is just a page.
                .heightIn(max = screenHeight * 0.6f)
                .clip(RoundedCornerShape(topStart = 18.dp, topEnd = 18.dp))
                .background(background)
                // Swallow taps on the panel itself, so only the scrim closes it.
                .clickable(
                    indication = null,
                    interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                ) {}
                .verticalScroll(rememberScrollState())
                .padding(bottom = 24.dp),
        ) {
            Box(
                modifier = Modifier
                    .padding(top = 10.dp, bottom = 8.dp)
                    .align(Alignment.CenterHorizontally)
                    .clip(RoundedCornerShape(2.dp))
                    .background(foreground.copy(alpha = 0.25f))
                    .width(36.dp)
                    .height(4.dp),
            )
            BasicText(
                text = title,
                style = TextStyle(color = foreground, fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
                modifier = Modifier.padding(horizontal = 20.dp).padding(bottom = 6.dp),
            )
            content()
        }
    }
}

/** A full-width row: glyph, label, and a tick when the tool is in effect. */
@Composable
private fun SheetRow(
    tool: String,
    label: String,
    active: Boolean,
    foreground: Color,
    highlight: Color,
    haptics: Boolean,
    onClick: () -> Unit,
) {
    val view = androidx.compose.ui.platform.LocalView.current
    val icon = TOOL_ICONS[tool]

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .height(48.dp)
            .background(if (active) highlight.copy(alpha = 0.10f) else Color.Transparent)
            .clickable {
                if (haptics) {
                    view.performHapticFeedback(android.view.HapticFeedbackConstants.KEYBOARD_TAP)
                }
                onClick()
            }
            .padding(horizontal = 20.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(14.dp),
    ) {
        if (icon != null) {
            Canvas(modifier = Modifier.size(20.dp)) {
                drawPath(
                    path = buildIconPath(icon.path, size.width),
                    color = if (active) highlight else foreground.copy(alpha = 0.75f),
                    style = Stroke(
                        width = icon.stroke * size.width / 24f,
                        cap = StrokeCap.Round,
                        join = StrokeJoin.Round,
                    ),
                )
            }
        }
        BasicText(
            text = label,
            style = TextStyle(color = foreground, fontSize = 16.sp),
            modifier = Modifier.weight(1f),
        )
        if (active) {
            Canvas(modifier = Modifier.size(18.dp)) {
                drawPath(
                    path = buildIconPath(CHECK_ICON_PATH, size.width),
                    color = highlight,
                    style = Stroke(
                        width = 2f * size.width / 24f,
                        cap = StrokeCap.Round,
                        join = StrokeJoin.Round,
                    ),
                )
            }
        }
    }
}

/** Section heading inside a sheet. */
@Composable
private fun SheetSection(title: String, foreground: Color) {
    BasicText(
        text = title.uppercase(),
        style = TextStyle(
            color = foreground.copy(alpha = 0.45f),
            fontSize = 12.sp,
            fontWeight = FontWeight.SemiBold,
        ),
        modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, top = 14.dp, bottom = 4.dp),
    )
}

@Composable
private fun PaletteRow(colors: List<String>, foreground: Color, onPick: (String?) -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = androidx.compose.foundation.layout.Arrangement.spacedBy(10.dp),
    ) {
        // "None" — clears the colour rather than applying one.
        Box(
            modifier = Modifier
                .size(28.dp)
                .clip(RoundedCornerShape(14.dp))
                .background(Color.Transparent)
                .clickable { onPick(null) },
            contentAlignment = Alignment.Center,
        ) {
            Canvas(modifier = Modifier.size(24.dp)) {
                drawPath(
                    path = buildIconPath("M4 20L20 4", size.width),
                    color = foreground.copy(alpha = 0.6f),
                    style = Stroke(width = 2f * size.width / 24f, cap = StrokeCap.Round),
                )
            }
        }

        for (hex in colors) {
            Box(
                modifier = Modifier
                    .size(28.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(Color(android.graphics.Color.parseColor(hex)))
                    .clickable { onPick(hex) },
            )
        }
    }
}

// ── Link dialog ─────────────────────────────────────────────────────────────

/**
 * Prompt for a URL, pre-filled when the caret sits inside an existing link.
 * A bare host gets an https:// prefix; something that looks like an address
 * becomes a mailto:. Anything else is rejected by the serializer's scheme
 * allow-list, so no javascript: URL can reach the document.
 */
private fun showLinkDialog(
    activity: FragmentActivity,
    current: String?,
    strings: Map<String, String>,
    onDismiss: () -> Unit,
    onApply: (String?) -> Unit,
) {
    val input = android.widget.EditText(activity).apply {
        setText(current ?: "")
        hint = localized(strings, "linkPlaceholder", "https://example.com")
        setSingleLine()
        inputType = android.text.InputType.TYPE_CLASS_TEXT or
            android.text.InputType.TYPE_TEXT_VARIATION_URI
    }
    val padded = FrameLayout(activity).apply {
        val pad = (16 * activity.resources.displayMetrics.density).toInt()
        setPadding(pad, pad / 2, pad, 0)
        addView(input)
    }

    val builder = AlertDialog.Builder(activity)
        .setTitle(localized(strings, "linkTitle", "Add Link"))
        .setView(padded)
        .setPositiveButton(localized(strings, "save", "Save")) { _, _ ->
            onApply(normalizeUrl(input.text.toString()))
        }
        .setNegativeButton(localized(strings, "cancel", "Cancel"), null)

    if (current != null) {
        builder.setNeutralButton(localized(strings, "linkRemove", "Remove")) { _, _ -> onApply(null) }
    }

    builder.setOnDismissListener { onDismiss() }
    builder.show()
}

private fun normalizeUrl(raw: String): String? {
    val trimmed = raw.trim()
    if (trimmed.isEmpty()) return null
    val lower = trimmed.lowercase()
    return when {
        lower.startsWith("http://") || lower.startsWith("https://") ||
            lower.startsWith("mailto:") || lower.startsWith("tel:") -> trimmed
        trimmed.contains('@') && !trimmed.contains(' ') -> "mailto:$trimmed"
        else -> "https://$trimmed"
    }
}
