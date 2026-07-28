import Foundation
import UIKit
import SwiftUI

// =============================================================================
// WysiwygEditor — iOS native WYSIWYG rich text editor
// =============================================================================
//
// A fully-native rich text editor (SwiftUI + UITextView/TextKit 1):
//   • Inline marks — bold, italic, underline, strikethrough, inline code,
//     links, text color, highlight.
//   • Blocks — paragraph, H1–H3, bullet / ordered lists, blockquote.
//   • Configurable toolbar (ordered subset), undo/redo, placeholder,
//     live character counter with maxLength, host-app theme overrides.
//
// Layout (top → bottom): [Cancel | title | Save] · editable content area ·
// optional counter · (color palette row) · horizontally scrolling formatting
// toolbar pinned above the keyboard. On "Save" the document is serialized to
// the normalised HTML contract shared with the Android implementation and
// returned via the `ContentSaved` event; cancelling (with a discard confirm
// when edited) fires `EditCancelled`. Exactly one terminal event per session.
//
// The HTML parser/serializer is hand-written (no NSAttributedString(html:))
// so both platforms emit byte-identical HTML for the same document.
// =============================================================================

// MARK: - Bridge function

enum WysiwygEditorFunctions {
    /// The editor currently on screen. InsertMedia / UpdateUpload arrive as
    /// separate bridge calls while the editor is open, so they need a way to
    /// reach it. Cleared when the editor closes.
    static weak var live: WysiwygDocumentModel?

    /// Insert a media block at the caret. The host calls this after picking
    /// (and optionally cropping) the media — the editor never opens a picker.
    class InsertMedia: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let kind = parameters["kind"] as? String else { return [:] }
            var attrs: [String: String] = [:]
            if let raw = parameters["attributes"] as? [String: Any] {
                for (key, value) in raw {
                    if let text = value as? String { attrs[key] = text }
                }
            }
            DispatchQueue.main.async {
                WysiwygEditorFunctions.live?.insertMedia(kind: kind, attrs: attrs)
            }
            return [:]
        }
    }

    /// Report upload progress / completion / failure for an inserted block.
    class UpdateUpload: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            guard let uploadId = parameters["uploadId"] as? String else { return [:] }
            let state = parameters["state"] as? String ?? "progress"
            let src = parameters["src"] as? String ?? ""
            let message = parameters["message"] as? String ?? ""
            DispatchQueue.main.async {
                WysiwygEditorFunctions.live?.updateUpload(
                    uploadId: uploadId, state: state, src: src, message: message
                )
            }
            return [:]
        }
    }

    class Open: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            let config = WysiwygConfig(parameters)
            DispatchQueue.main.async { WysiwygEditorPresenter.shared.present(config: config) }
            return [:]
        }
    }
}

// MARK: - Events

private enum WysiwygEvents {
    static let saved = "Vipertecpro\\WysiwygEditor\\Events\\ContentSaved"
    static let cancelled = "Vipertecpro\\WysiwygEditor\\Events\\EditCancelled"
    static let mediaRequested = "Vipertecpro\\WysiwygEditor\\Events\\MediaRequested"
}

// MARK: - Theme

/// Host-app theme overrides. Every color is optional: `nil` falls back to the
/// editor's built-in system-adaptive default, so the editor blends into ANY
/// app — the host decides, not the plugin.
struct WysiwygTheme {
    let background: UIColor?   // editor screen background
    let text: UIColor?         // content text, titles, inactive icons
    let accent: UIColor?       // the Save button / caret / link display
    let highlight: UIColor?    // active toolbar buttons

    init(_ p: [String: Any]?, light: [String: Any]? = nil, dark: [String: Any]? = nil) {
        background = UIColor(wysiwygHex: p?["background"] as? String)
        text = UIColor(wysiwygHex: p?["text"] as? String)
        accent = UIColor(wysiwygHex: p?["accent"] as? String)
        highlight = UIColor(wysiwygHex: p?["highlight"] as? String)
        self.light = WysiwygTheme.palette(light)
        self.dark = WysiwygTheme.palette(dark)
    }

    /// One colour-scheme palette from PHP: editor key → colour.
    private static func palette(_ raw: [String: Any]?) -> [String: UIColor] {
        guard let raw else { return [:] }
        var out: [String: UIColor] = [:]
        for key in ["background", "text", "accent", "highlight"] {
            if let color = UIColor(wysiwygHex: raw[key] as? String) { out[key] = color }
        }
        return out
    }

    /// The HOST app's palette per colour scheme, resolved in PHP from its
    /// NativeUI theme tokens. Used when the caller gave no explicit colour, so
    /// an unconfigured editor still looks like part of the app.
    var light: [String: UIColor] = [:]
    var dark: [String: UIColor] = [:]

    private func host(_ key: String) -> Color? {
        let night = UITraitCollection.current.userInterfaceStyle == .dark
        return (night ? dark : light)[key].map(Color.init)
    }

    // Resolved SwiftUI colors: explicit → host theme → built-in default.
    var backgroundColor: Color { background.map(Color.init) ?? host("background") ?? Color(.systemBackground) }
    var textColor: Color { text.map(Color.init) ?? host("text") ?? .primary }
    var accentColor: Color {
        accent.map(Color.init) ?? host("accent") ?? Color(red: 0.92, green: 0.47, blue: 0.18)
    }
    var highlightColor: Color { highlight.map(Color.init) ?? host("highlight") ?? .green }

    /// Host palette for the UIKit side. Must mirror `host(_:)` — the text
    /// engine renders the document itself, so if these skipped the host theme
    /// the chrome would adopt the app's colours while the text stayed default.
    private func hostUI(_ key: String) -> UIColor? {
        let night = UITraitCollection.current.userInterfaceStyle == .dark
        return (night ? dark : light)[key]
    }

    // Resolved UIKit colors for the text engine.
    var backgroundUIColor: UIColor { background ?? hostUI("background") ?? .systemBackground }
    var textUIColor: UIColor { text ?? hostUI("text") ?? .label }
    var secondaryTextUIColor: UIColor {
        (text ?? hostUI("text"))?.withAlphaComponent(0.6) ?? .secondaryLabel
    }
    var accentUIColor: UIColor {
        accent ?? hostUI("accent") ?? UIColor(red: 0.92, green: 0.47, blue: 0.18, alpha: 1)
    }
}

extension UIColor {
    /// #RGB / #RRGGBB / #RRGGBBAA (leading '#' optional). Returns nil on junk.
    /// (Named `wysiwygHex` — not plain `hex` — so this file can coexist with
    /// sibling plugins that ship their own UIColor hex initializer.)
    convenience init?(wysiwygHex: String?) {
        guard var s = wysiwygHex?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let divisor: CGFloat = 255
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / divisor
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / divisor
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / divisor
        let a = hasAlpha ? CGFloat(v & 0xFF) / divisor : 1
        self.init(red: r, green: g, blue: b, alpha: a)
    }
}

// MARK: - Config

struct WysiwygConfig {
    /// The `full` preset order — also the whitelist for the toolbar option.
    static let insertTools = ["image", "video", "file"]
    static let allTools = [
        "bold", "italic", "underline", "strikethrough", "h1", "h2", "h3",
        "bulletList", "orderedList", "blockquote", "link", "code",
        "textColor", "highlight", "image", "video", "file", "clearFormat",
    ]

    let content: String
    let toolbar: [String]
    let title: String
    let placeholder: String
    let maxLength: Int
    let counts: [String]
    let theme: WysiwygTheme
    let id: String?

    init(_ p: [String: Any]) {
        content = p["content"] as? String ?? ""
        let requested = (p["toolbar"] as? [String])?.filter { Self.allTools.contains($0) } ?? Self.allTools
        toolbar = requested.isEmpty ? Self.allTools : requested
        title = p["title"] as? String ?? ""
        placeholder = p["placeholder"] as? String ?? ""
        maxLength = max(0, (p["maxLength"] as? NSNumber)?.intValue ?? 0)
        counts = p["counts"] as? [String] ?? []
        theme = WysiwygTheme(p["theme"] as? [String: Any],
                             light: p["themeLight"] as? [String: Any],
                             dark: p["themeDark"] as? [String: Any])
        id = p["id"] as? String
    }
}

// MARK: - Custom attribute keys

/// Custom attributes are the single source of truth for serialization — fonts
/// and colors are derived DISPLAY, never parsed back (so an h1's intrinsic
/// bold is never confused with a <strong> mark, and URL round-trips are exact).
extension NSAttributedString.Key {
    /// Paragraph block type on EVERY character of the paragraph (incl. its
    /// trailing newline): "p" | "h1" | "h2" | "h3" | "ul" | "ol" | "blockquote".
    static let wysiwygBlock = NSAttributedString.Key("wysiwygBlock")
    /// Marks the non-content list-marker prefix ("•\u{00A0}" / "1.\u{00A0}").
    static let wysiwygMarker = NSAttributedString.Key("wysiwygMarker")
    static let wysiwygBold = NSAttributedString.Key("wysiwygBold")
    static let wysiwygItalic = NSAttributedString.Key("wysiwygItalic")
    static let wysiwygCode = NSAttributedString.Key("wysiwygCode")
    /// The href string, verbatim (a URL object would re-encode it).
    static let wysiwygLink = NSAttributedString.Key("wysiwygLink")
    /// "#RRGGBB" uppercase — explicit text color (only when user-chosen).
    static let wysiwygTextColor = NSAttributedString.Key("wysiwygTextColor")
    /// "#RRGGBB" uppercase — highlight background color.
    static let wysiwygHighlight = NSAttributedString.Key("wysiwygHighlight")
}

// MARK: - Document model

/// The inline marks of one run of text, in a serialization-friendly form.
/// Nesting order (outermost → innermost) is fixed by the HTML contract:
/// link → color → highlight → strong → em → u → s → code.
struct MarkSet: Equatable {
    var link: String?
    var color: String?      // "#RRGGBB"
    var highlight: String?  // "#RRGGBB"
    var bold = false
    var italic = false
    var underline = false
    var strike = false
    var code = false

    var isPlain: Bool { self == MarkSet() }
}

struct WysiwygRun: Equatable {
    var text: String
    var marks: MarkSet
}

/// A poll choice. Ids are stable so a host can attribute votes to an option.
struct PollOption: Equatable {
    var id: String
    var label: String
}

/// One block of the document.
///
/// TEXT blocks (p/h1-h3/ul/ol/blockquote) carry `runs` and are exactly the v1
/// model. MEDIA blocks (image/video/file/embed/poll/divider) carry `attrs`
/// instead — a flat string map rather than a field per type, so adding a block
/// type does not ripple through both platforms' serializers.
///
/// `id` is stable for the block's lifetime and exists so hosts can map upload
/// progress or comments to a specific block. It never appears in HTML.
struct WysiwygBlock {
    var type: String        // p | h1…h3 | ul | ol | blockquote | image | video | …
    var runs: [WysiwygRun]
    var id: String = ""
    var attrs: [String: String] = [:]
    var options: [PollOption] = []

    var isEmpty: Bool { runs.allSatisfy { $0.text.isEmpty } }
    var plainText: String { runs.map(\.text).joined() }
    var isText: Bool { Self.knownTypes.contains(type) }

    static let knownTypes: Set<String> = ["p", "h1", "h2", "h3", "ul", "ol", "blockquote"]
    static let mediaTypes: Set<String> = ["image", "video", "file", "embed", "poll", "divider"]

    /// Attribute keys per media type, in SERIALIZATION order (normative).
    static let mediaAttrs: [String: [String]] = [
        "image": ["src", "localPath", "alt", "caption", "width", "height", "uploadId"],
        "video": ["src", "localPath", "poster", "caption", "uploadId"],
        "file": ["src", "localPath", "name", "size", "mime", "uploadId"],
        "embed": ["url", "provider", "html"],
        "poll": ["question", "multiple", "closesAt"],
        "divider": [],
    ]
}

// MARK: - HTML coder

/// Hand-written HTML parser + serializer implementing the plugin's normative
/// HTML contract (see README). Both directions are pure functions over
/// `[WysiwygBlock]` so the round-trip is deterministic and identical to the
/// Android implementation. NSAttributedString(html:) is deliberately NOT used.
enum HtmlCoder {

    // MARK: parse

    /// Tolerant scanner: aliases normalised (b→strong, i→em, del/strike→s,
    /// div→p, h4-h6→h3), <br> splits blocks, unknown tags ignored (text kept),
    /// <script>/<style> skipped entirely, inter-block whitespace ignored,
    /// entities decoded, unsafe link schemes dropped (text kept).
    static func parse(_ html: String) -> [WysiwygBlock] {
        var blocks: [WysiwygBlock] = []
        var current: WysiwygBlock?
        var openedByBr = false
        var listStack: [String] = []
        // The media block currently being assembled from a <figure>, if any.
        var mediaBlock: WysiwygBlock?
        var inFigcaption = false
        var markStack: [(tag: String, apply: (inout MarkSet) -> Void)] = []
        let chars = Array(html)
        let n = chars.count
        var i = 0

        func marksNow() -> MarkSet {
            var m = MarkSet()
            for entry in markStack { entry.apply(&m) }
            return m
        }
        // Unconditionally append the open block (used by <br>, which WANTS
        // intentional empty blocks committed).
        func commit() {
            if let block = current { blocks.append(block) }
            current = nil
            openedByBr = false
        }
        // Close the open block, dropping a still-empty block that only exists
        // because a <br> split opened it (so `<p>x<br></p>` is one block, not two).
        func closeBlock() {
            if openedByBr, current?.isEmpty ?? true { current = nil; openedByBr = false }
            else { commit() }
        }
        func open(_ type: String, byBr: Bool = false) {
            closeBlock()
            current = WysiwygBlock(type: type, runs: [])
            openedByBr = byBr
        }
        func appendText(_ decoded: String) {
            let text = collapseWhitespace(decoded)
            if mediaBlock != nil {
                // Inside a <figure>: only the caption is content; anything else
                // (whitespace between the img and figcaption) is layout noise.
                if inFigcaption, var media = mediaBlock {
                    media.attrs["caption"] = (media.attrs["caption"] ?? "") + text
                    mediaBlock = media
                }
                return
            }
            if current == nil {
                // No open block: whitespace between blocks is ignored; real
                // text opens an implicit paragraph (tolerance).
                if text.allSatisfy({ $0 == " " || $0.isWhitespace }) { return }
                open("p")
            }
            guard !text.isEmpty else { return }
            let marks = marksNow()
            if var last = current!.runs.last, last.marks == marks {
                last.text += text
                current!.runs[current!.runs.count - 1] = last
            } else {
                current!.runs.append(WysiwygRun(text: text, marks: marks))
            }
        }
        /// Skip everything up to (and including) `</tag ...>` — for script/style.
        func skipRawContent(_ tag: String) {
            let closing = Array("</" + tag)
            while i < n {
                if chars[i] == "<" {
                    var match = true
                    for (k, c) in closing.enumerated() {
                        let idx = i + k
                        if idx >= n || String(chars[idx]).lowercased() != String(c) { match = false; break }
                    }
                    if match {
                        var j = i
                        while j < n, chars[j] != ">" { j += 1 }
                        i = min(j + 1, n)
                        return
                    }
                }
                i += 1
            }
        }
        func canonicalInline(_ name: String) -> String {
            switch name {
            case "b": return "strong"
            case "i": return "em"
            case "del", "strike": return "s"
            default: return name
            }
        }
        func handleOpen(_ name: String, _ attrText: String) {
            switch name {
            case "script", "style":
                skipRawContent(name)
            case "br":
                let type = current?.type ?? "p"
                commit()
                open(type, byBr: true)
            case "hr":
                closeBlock()
                blocks.append(WysiwygBlock(type: "divider", runs: []))
            case "figure":
                closeBlock()
                let a = attributes(from: attrText)
                if let payload = a["data-poll"] {
                    mediaBlock = JsonCoder.decode(payload).first ?? WysiwygBlock(type: "poll", runs: [])
                } else if let url = a["data-embed"] {
                    var embed = WysiwygBlock(type: "embed", runs: [])
                    embed.attrs["url"] = url
                    if let provider = a["data-provider"], !provider.isEmpty {
                        embed.attrs["provider"] = provider
                    }
                    mediaBlock = embed
                } else {
                    // Type is decided by whatever <img>/<video> it contains.
                    mediaBlock = WysiwygBlock(type: "figure", runs: [])
                }
                if let pendingId = a["data-pending"], !pendingId.isEmpty {
                    mediaBlock?.attrs["uploadId"] = pendingId
                }
            case "img", "video":
                let a = attributes(from: attrText)
                var target = mediaBlock ?? WysiwygBlock(type: name, runs: [])
                target.type = (name == "img") ? "image" : "video"
                if let src = a["src"], !src.isEmpty { target.attrs["src"] = src }
                if let alt = a["alt"], !alt.isEmpty { target.attrs["alt"] = alt }
                if let poster = a["poster"], !poster.isEmpty { target.attrs["poster"] = poster }
                if mediaBlock == nil {
                    // A bare <img>/<video> outside a figure is still a block.
                    closeBlock()
                    blocks.append(target)
                } else {
                    mediaBlock = target
                }
            case "figcaption":
                inFigcaption = true
            case "p", "div":
                open("p")
            case "h1":
                open("h1")
            case "h2":
                open("h2")
            case "h3", "h4", "h5", "h6":
                open("h3")
            case "blockquote":
                open("blockquote")
            case "ul":
                closeBlock()
                listStack.append("ul")
            case "ol":
                closeBlock()
                listStack.append("ol")
            case "li":
                open(listStack.last ?? "p")
            case "a":
                let href = allowedHref(attributes(from: attrText)["href"])
                markStack.append((tag: "a", apply: { if let href { $0.link = href } }))
            case "span":
                let color = cssColor("color", in: attributes(from: attrText)["style"])
                markStack.append((tag: "span", apply: { if let color { $0.color = color } }))
            case "mark":
                let bg = cssColor("background-color", in: attributes(from: attrText)["style"]) ?? "#FDE68A"
                markStack.append((tag: "mark", apply: { $0.highlight = bg }))
            case "strong", "b":
                markStack.append((tag: "strong", apply: { $0.bold = true }))
            case "em", "i":
                markStack.append((tag: "em", apply: { $0.italic = true }))
            case "u":
                markStack.append((tag: "u", apply: { $0.underline = true }))
            case "s", "del", "strike":
                markStack.append((tag: "s", apply: { $0.strike = true }))
            case "code":
                markStack.append((tag: "code", apply: { $0.code = true }))
            default:
                break // unknown tag: ignored, its text content still flows through
            }
        }
        func handleClose(_ name: String) {
            switch name {
            case "figure":
                if let media = mediaBlock, media.type != "figure" { blocks.append(media) }
                mediaBlock = nil
                inFigcaption = false
            case "figcaption":
                inFigcaption = false
            case "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "li":
                closeBlock()
            case "ul", "ol":
                closeBlock()
                if !listStack.isEmpty { listStack.removeLast() }
            case "a", "span", "mark", "strong", "b", "em", "i", "u", "s", "del", "strike", "code":
                let canonical = canonicalInline(name)
                if let idx = markStack.lastIndex(where: { $0.tag == canonical }) {
                    markStack.remove(at: idx)
                }
            default:
                break
            }
        }
        func handleTag(_ raw: String) {
            var body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            let isClose = body.hasPrefix("/")
            if isClose { body.removeFirst() }
            if body.hasSuffix("/") { body.removeLast() }
            let bodyChars = Array(body)
            var k = 0
            while k < bodyChars.count, bodyChars[k].isLetter || bodyChars[k].isNumber { k += 1 }
            guard k > 0 else { return }
            let name = String(bodyChars[0..<k]).lowercased()
            let attrText = String(bodyChars[k...])
            if isClose { handleClose(name) } else { handleOpen(name, attrText) }
        }

        while i < n {
            if chars[i] == "<" {
                if i + 3 < n, chars[i + 1] == "!", chars[i + 2] == "-", chars[i + 3] == "-" {
                    // <!-- comment -->
                    var j = i + 4
                    while j + 2 < n, !(chars[j] == "-" && chars[j + 1] == "-" && chars[j + 2] == ">") { j += 1 }
                    i = j + 2 < n ? j + 3 : n
                    continue
                }
                if i + 1 < n, chars[i + 1] == "!" {
                    // <!doctype …>
                    var j = i
                    while j < n, chars[j] != ">" { j += 1 }
                    i = min(j + 1, n)
                    continue
                }
                // find the tag-closing '>' (quote-aware for attribute values)
                var j = i + 1
                var quote: Character?
                while j < n {
                    let c = chars[j]
                    if let q = quote { if c == q { quote = nil } }
                    else if c == "\"" || c == "'" { quote = c }
                    else if c == ">" { break }
                    j += 1
                }
                guard j < n else {
                    appendText(decodeEntities(String(chars[i...])))
                    break
                }
                let inner = String(chars[(i + 1)..<j])
                i = j + 1
                handleTag(inner)
            } else {
                var j = i
                while j < n, chars[j] != "<" { j += 1 }
                appendText(decodeEntities(String(chars[i..<j])))
                i = j
            }
        }
        closeBlock()
        return blocks
    }

    // MARK: serialize

    /// Emit the normalised HTML + the plain-text rendition. `<p><br></p>` for
    /// empty paragraphs, consecutive list items grouped into ONE <ul>/<ol>,
    /// no whitespace between blocks — and a document that is nothing but a
    /// single empty paragraph IS the empty document ("", "").
    static func emit(_ blocks: [WysiwygBlock]) -> (html: String, text: String) {
        if blocks.isEmpty { return ("", "") }
        if blocks.count == 1, blocks[0].type == "p", blocks[0].isEmpty { return ("", "") }

        var html = ""
        var lines: [String] = []
        var i = 0
        while i < blocks.count {
            let block = blocks[i]
            if WysiwygBlock.mediaTypes.contains(block.type) {
                html += mediaHtml(block)
                lines.append(mediaText(block))
                i += 1
                continue
            }
            switch block.type {
            case "ul", "ol":
                let type = block.type
                html += "<\(type)>"
                var itemNumber = 0
                var j = i
                while j < blocks.count, blocks[j].type == type {
                    itemNumber += 1
                    html += "<li>" + inlineHtml(blocks[j].runs) + "</li>"
                    lines.append((type == "ul" ? "- " : "\(itemNumber). ") + blocks[j].plainText)
                    j += 1
                }
                html += "</\(type)>"
                i = j
            default:
                let tag = WysiwygBlock.knownTypes.contains(block.type) ? block.type : "p"
                if tag == "p", block.isEmpty {
                    html += "<p><br></p>"
                } else {
                    html += "<\(tag)>" + inlineHtml(block.runs) + "</\(tag)>"
                }
                lines.append(block.plainText)
                i += 1
            }
        }
        return (html, lines.joined(separator: "\n"))
    }

    /// Media blocks as HTML. `src` is the PUBLIC url — a block whose upload has
    /// not finished exports with `data-pending` and no src rather than leaking
    /// a device path into published HTML, so the host can find unfinished
    /// uploads instead of silently shipping a broken image.
    static func mediaHtml(_ block: WysiwygBlock) -> String {
        let src = block.attrs["src"] ?? ""
        let caption = block.attrs["caption"] ?? ""
        let uploadId = block.attrs["uploadId"] ?? ""
        let pending = (src.isEmpty && !uploadId.isEmpty)
            ? " data-pending=\"" + escapeAttr(uploadId) + "\""
            : ""
        let figcaption = caption.isEmpty ? "" : "<figcaption>" + escapeText(caption) + "</figcaption>"

        switch block.type {
        case "divider":
            return "<hr>"
        case "image":
            var attrs = ""
            if !src.isEmpty { attrs += " src=\"" + escapeAttr(src) + "\"" }
            attrs += " alt=\"" + escapeAttr(block.attrs["alt"] ?? "") + "\""
            return "<figure\(pending)><img\(attrs)>\(figcaption)</figure>"
        case "video":
            var attrs = ""
            if !src.isEmpty { attrs += " src=\"" + escapeAttr(src) + "\"" }
            if let poster = block.attrs["poster"], !poster.isEmpty {
                attrs += " poster=\"" + escapeAttr(poster) + "\""
            }
            return "<figure\(pending)><video\(attrs) controls></video>\(figcaption)</figure>"
        case "file":
            return "<p><a href=\"" + escapeAttr(src) + "\" download>"
                + escapeText(block.attrs["name"] ?? "") + "</a></p>"
        case "embed":
            let provider = block.attrs["provider"] ?? ""
            let providerAttr = provider.isEmpty ? "" : " data-provider=\"" + escapeAttr(provider) + "\""
            return "<figure data-embed=\"" + escapeAttr(block.attrs["url"] ?? "") + "\""
                + providerAttr + "></figure>"
        case "poll":
            // The whole block round-trips as escaped JSON — HTML has nowhere
            // else to keep option ids.
            return "<figure data-poll=\"" + escapeAttr(JsonCoder.encode([block])) + "\"></figure>"
        default:
            return ""
        }
    }

    /// The plain-text stand-in for a media block (used for excerpts/search).
    static func mediaText(_ block: WysiwygBlock) -> String {
        switch block.type {
        case "divider": return "---"
        case "image":
            let caption = block.attrs["caption"] ?? ""
            return caption.isEmpty ? (block.attrs["alt"] ?? "") : caption
        case "video": return block.attrs["caption"] ?? ""
        case "file": return block.attrs["name"] ?? ""
        case "embed": return block.attrs["url"] ?? ""
        case "poll": return block.attrs["question"] ?? ""
        default: return ""
        }
    }

    /// Merge adjacent identical runs, then wrap them in the fixed nesting
    /// order (link → color → highlight → strong → em → u → s → code) by
    /// recursively grouping consecutive runs that share the mark at each level.
    static func inlineHtml(_ runs: [WysiwygRun]) -> String {
        var merged: [WysiwygRun] = []
        for run in runs where !run.text.isEmpty {
            if var last = merged.last, last.marks == run.marks {
                last.text += run.text
                merged[merged.count - 1] = last
            } else {
                merged.append(run)
            }
        }
        return emitLevel(merged[...], level: 0)
    }

    /// The mark examined at each nesting level; nil means "not marked".
    private static func markValue(_ m: MarkSet, level: Int) -> String? {
        switch level {
        case 0: return m.link
        case 1: return m.color
        case 2: return m.highlight
        case 3: return m.bold ? "1" : nil
        case 4: return m.italic ? "1" : nil
        case 5: return m.underline ? "1" : nil
        case 6: return m.strike ? "1" : nil
        default: return m.code ? "1" : nil
        }
    }

    private static func emitLevel(_ runs: ArraySlice<WysiwygRun>, level: Int) -> String {
        if level >= 8 {
            return runs.map { escapeText($0.text) }.joined()
        }
        var out = ""
        var i = runs.startIndex
        while i < runs.endIndex {
            let value = markValue(runs[i].marks, level: level)
            var j = i + 1
            while j < runs.endIndex, markValue(runs[j].marks, level: level) == value { j += 1 }
            let inner = emitLevel(runs[i..<j], level: level + 1)
            if let value {
                switch level {
                case 0: out += "<a href=\"\(escapeAttr(value))\">\(inner)</a>"
                case 1: out += "<span style=\"color:\(value)\">\(inner)</span>"
                case 2: out += "<mark style=\"background-color:\(value)\">\(inner)</mark>"
                case 3: out += "<strong>\(inner)</strong>"
                case 4: out += "<em>\(inner)</em>"
                case 5: out += "<u>\(inner)</u>"
                case 6: out += "<s>\(inner)</s>"
                default: out += "<code>\(inner)</code>"
                }
            } else {
                out += inner
            }
            i = j
        }
        return out
    }

    // MARK: text helpers

    static func escapeText(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.append(c)
            }
        }
        return out
    }

    static func escapeAttr(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let chars = Array(s)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "&" {
                // entities are short — look ahead a bounded distance for ';'
                var semi = -1
                var j = i + 1
                while j < chars.count, j - i <= 10 {
                    if chars[j] == ";" { semi = j; break }
                    j += 1
                }
                if semi > i + 1, let decoded = decodeEntity(String(chars[(i + 1)..<semi])) {
                    out += decoded
                    i = semi + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    private static func decodeEntity(_ name: String) -> String? {
        switch name.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return "\u{00A0}"
        default: break
        }
        if name.hasPrefix("#") {
            let digits = String(name.dropFirst())
            let value: UInt32?
            if digits.lowercased().hasPrefix("x") { value = UInt32(digits.dropFirst(), radix: 16) }
            else { value = UInt32(digits) }
            if let value, let scalar = Unicode.Scalar(value) { return String(Character(scalar)) }
        }
        return nil
    }

    /// Runs of whitespace that contain a line break / tab (i.e. source-code
    /// formatting) collapse to one space; runs of plain spaces are preserved
    /// so user-typed content round-trips verbatim.
    static func collapseWhitespace(_ s: String) -> String {
        guard s.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\t" }) else { return s }
        var out = ""
        var run = ""
        var runHasBreak = false
        for c in s {
            if c == " " || c == "\n" || c == "\r" || c == "\t" {
                run.append(c)
                if c != " " { runHasBreak = true }
            } else {
                if !run.isEmpty { out += runHasBreak ? " " : run; run = ""; runHasBreak = false }
                out.append(c)
            }
        }
        if !run.isEmpty { out += runHasBreak ? " " : run }
        return out
    }

    /// Very small attribute scanner: name[=value] pairs, quoted or bare.
    static func attributes(from s: String) -> [String: String] {
        var result: [String: String] = [:]
        let chars = Array(s)
        let n = chars.count
        var i = 0
        while i < n {
            while i < n, chars[i].isWhitespace { i += 1 }
            var name = ""
            while i < n, !chars[i].isWhitespace, chars[i] != "=" { name.append(chars[i]); i += 1 }
            while i < n, chars[i].isWhitespace { i += 1 }
            var value = ""
            if i < n, chars[i] == "=" {
                i += 1
                while i < n, chars[i].isWhitespace { i += 1 }
                if i < n, chars[i] == "\"" || chars[i] == "'" {
                    let q = chars[i]
                    i += 1
                    while i < n, chars[i] != q { value.append(chars[i]); i += 1 }
                    if i < n { i += 1 }
                } else {
                    while i < n, !chars[i].isWhitespace { value.append(chars[i]); i += 1 }
                }
            }
            if !name.isEmpty { result[name.lowercased()] = decodeEntities(value) }
        }
        return result
    }

    /// Extract `property: #hex` from an inline style, canonicalised to
    /// uppercase 6-digit "#RRGGBB" (3-digit shorthand expanded). Nil otherwise.
    static func cssColor(_ property: String, in style: String?) -> String? {
        guard let style else { return nil }
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == property else { continue }
            return normalizeHex(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// "#abc" / "#AABBCC" → "#AABBCC". Nil for anything else.
    static func normalizeHex(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return "#" + s.uppercased()
    }

    /// Keep only http(s)/mailto/tel hrefs (input tolerance — no auto-fixing).
    static func allowedHref(_ href: String?) -> String? {
        guard let href = href?.trimmingCharacters(in: .whitespacesAndNewlines), !href.isEmpty else { return nil }
        let lower = href.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") {
            return href
        }
        return nil
    }
}

/// Whitespace-delimited words across the whole document.
func countWords(_ blocks: [WysiwygBlock]) -> Int {
    blocks.reduce(0) { total, block in
        total + block.plainText
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\u{00A0}" })
            .count
    }
}

// MARK: - Segments

/// How a document is laid out for editing. Consecutive TEXT blocks collapse
/// into one editor (the v1 engine, unchanged); each media block gets its own
/// view. See docs/DOCUMENT-MODEL.md — this is what keeps caret handling to the
/// rare text↔media boundary instead of every paragraph break.
enum Segment {
    /// A run of text blocks sharing one editor.
    case text([WysiwygBlock])
    /// A single media block rendered as its own card.
    case media(WysiwygBlock)
}

/// Group a block list into segments, preserving document order.
func segmentsOf(_ blocks: [WysiwygBlock]) -> [Segment] {
    var segments: [Segment] = []

    for block in blocks {
        if block.isText {
            if case .text(var run) = segments.last {
                run.append(block)
                segments[segments.count - 1] = .text(run)
            } else {
                segments.append(.text([block]))
            }
        } else {
            segments.append(.media(block))
        }
    }

    // An empty document still needs somewhere to type.
    if segments.isEmpty { segments.append(.text([WysiwygBlock(type: "p", runs: [])])) }

    return segments
}

/// Flatten segments back into a block list for serialization.
func blocksOf(_ segments: [Segment]) -> [WysiwygBlock] {
    segments.flatMap { segment -> [WysiwygBlock] in
        switch segment {
        case .text(let blocks): return blocks
        case .media(let block): return [block]
        }
    }
}

// MARK: - JSON coder

/// The FIDELITY format: unlike HTML it carries block ids, upload state and poll
/// options. See docs/DOCUMENT-MODEL.md.
///
/// The writer is hand-rolled rather than `JSONSerialization` for two reasons:
/// platform JSON writers make no guarantee about key ORDER, so the two
/// platforms would emit different bytes for the same document and the parity
/// harness could not compare them; and staying dependency-free keeps the coder
/// pure Foundation, so it runs off-device in the test harness.
enum JsonCoder {

    // MARK: encode

    static func encode(_ blocks: [WysiwygBlock]) -> String {
        var out = "{\"version\":2,\"blocks\":["
        for (index, block) in blocks.enumerated() {
            if index > 0 { out += "," }
            out += encodeBlock(block)
        }
        out += "]}"
        return out
    }

    private static func encodeBlock(_ block: WysiwygBlock) -> String {
        var out = "{\"id\":" + quote(block.id)
        out += ",\"type\":" + quote(block.type)

        if block.isText {
            out += ",\"runs\":["
            var first = true
            for run in block.runs where !run.text.isEmpty {
                if !first { out += "," }
                first = false
                out += "{\"text\":" + quote(run.text)
                out += ",\"marks\":" + encodeMarks(run.marks) + "}"
            }
            out += "]"
        } else {
            // Fixed key order per type keeps both platforms byte-identical.
            for key in WysiwygBlock.mediaAttrs[block.type] ?? [] {
                guard let value = block.attrs[key] else { continue }
                out += "," + quote(key) + ":" + quote(value)
            }
            if block.type == "poll" {
                out += ",\"options\":["
                for (index, option) in block.options.enumerated() {
                    if index > 0 { out += "," }
                    out += "{\"id\":" + quote(option.id)
                    out += ",\"label\":" + quote(option.label) + "}"
                }
                out += "]"
            }
        }

        return out + "}"
    }

    /// Only marks that are SET are emitted, in the contract's nesting order.
    private static func encodeMarks(_ marks: MarkSet) -> String {
        var parts: [String] = []
        if let link = marks.link { parts.append("\"link\":" + quote(link)) }
        if let color = marks.color { parts.append("\"color\":" + quote(color)) }
        if let highlight = marks.highlight { parts.append("\"highlight\":" + quote(highlight)) }
        if marks.bold { parts.append("\"bold\":true") }
        if marks.italic { parts.append("\"italic\":true") }
        if marks.underline { parts.append("\"underline\":true") }
        if marks.strike { parts.append("\"strike\":true") }
        if marks.code { parts.append("\"code\":true") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }

    // MARK: decode

    /// Tolerant reader: unknown keys ignored, malformed input yields no blocks.
    static func decode(_ json: String) -> [WysiwygBlock] {
        var scanner = JsonScanner(json)
        guard let root = scanner.parseValue() as? [String: Any],
              let rawBlocks = root["blocks"] as? [Any] else { return [] }

        var blocks: [WysiwygBlock] = []

        for raw in rawBlocks {
            guard let map = raw as? [String: Any],
                  let type = map["type"] as? String,
                  WysiwygBlock.knownTypes.contains(type) || WysiwygBlock.mediaTypes.contains(type)
            else { continue }

            var block = WysiwygBlock(type: type, runs: [], id: map["id"] as? String ?? "")

            if block.isText {
                for rawRun in map["runs"] as? [Any] ?? [] {
                    guard let runMap = rawRun as? [String: Any],
                          let text = runMap["text"] as? String, !text.isEmpty else { continue }
                    block.runs.append(WysiwygRun(text: text,
                                                 marks: decodeMarks(runMap["marks"] as? [String: Any])))
                }
            } else {
                for key in WysiwygBlock.mediaAttrs[type] ?? [] {
                    if let value = map[key] { block.attrs[key] = stringify(value) }
                }
                for rawOption in map["options"] as? [Any] ?? [] {
                    guard let optionMap = rawOption as? [String: Any] else { continue }
                    block.options.append(PollOption(id: optionMap["id"] as? String ?? "",
                                                    label: optionMap["label"] as? String ?? ""))
                }
            }

            blocks.append(block)
        }

        return blocks
    }

    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let b = value as? Bool { return b ? "true" : "false" }
        if let d = value as? Double {
            return d == d.rounded() && d.isFinite ? String(Int(d)) : String(d)
        }
        return "\(value)"
    }

    private static func decodeMarks(_ map: [String: Any]?) -> MarkSet {
        guard let map else { return MarkSet() }
        func flag(_ key: String) -> Bool { (map[key] as? Bool) == true }
        return MarkSet(
            link: map["link"] as? String,
            color: map["color"] as? String,
            highlight: map["highlight"] as? String,
            bold: flag("bold"),
            italic: flag("italic"),
            underline: flag("underline"),
            strike: flag("strike"),
            code: flag("code")
        )
    }
}

/// Minimal recursive-descent JSON reader — objects, arrays, strings, numbers,
/// booleans and null. Enough for this document model, nothing more.
struct JsonScanner {
    private let chars: [Character]
    private var i = 0

    init(_ source: String) { chars = Array(source) }

    mutating func parseValue() -> Any? {
        skipWhitespace()
        guard i < chars.count else { return nil }
        switch chars[i] {
        case "{": return parseObject()
        case "[": return parseArray()
        case "\"": return parseString()
        case "t": return literal("true", true)
        case "f": return literal("false", false)
        case "n": return literal("null", nil)
        default: return parseNumber()
        }
    }

    private mutating func skipWhitespace() {
        while i < chars.count, chars[i].isWhitespace { i += 1 }
    }

    private mutating func literal(_ word: String, _ value: Any?) -> Any? {
        i += word.count
        return value
    }

    private mutating func parseObject() -> [String: Any] {
        var map: [String: Any] = [:]
        i += 1 // '{'
        skipWhitespace()
        if i < chars.count, chars[i] == "}" { i += 1; return map }
        while i < chars.count {
            skipWhitespace()
            let key = parseString()
            skipWhitespace()
            guard i < chars.count, chars[i] == ":" else { break }
            i += 1
            if let value = parseValue() { map[key] = value }
            skipWhitespace()
            if i < chars.count, chars[i] == "," { i += 1; continue }
            if i < chars.count, chars[i] == "}" { i += 1; break }
            break
        }
        return map
    }

    private mutating func parseArray() -> [Any] {
        var list: [Any] = []
        i += 1 // '['
        skipWhitespace()
        if i < chars.count, chars[i] == "]" { i += 1; return list }
        while i < chars.count {
            if let value = parseValue() { list.append(value) }
            skipWhitespace()
            if i < chars.count, chars[i] == "," { i += 1; continue }
            if i < chars.count, chars[i] == "]" { i += 1; break }
            break
        }
        return list
    }

    private mutating func parseString() -> String {
        guard i < chars.count, chars[i] == "\"" else { return "" }
        i += 1
        var out = ""
        while i < chars.count {
            let c = chars[i]
            if c == "\"" { i += 1; return out }
            if c == "\\" {
                i += 1
                guard i < chars.count else { break }
                switch chars[i] {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    let start = i + 1
                    let end = min(i + 5, chars.count)
                    if start < end, let value = UInt32(String(chars[start..<end]), radix: 16),
                       let scalar = Unicode.Scalar(value) {
                        out.append(Character(scalar))
                    }
                    i += 4
                default: out.append(chars[i])
                }
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    private mutating func parseNumber() -> Double {
        let start = i
        while i < chars.count, chars[i].isNumber || "-+.eE".contains(chars[i]) { i += 1 }
        return Double(String(chars[start..<i])) ?? 0
    }
}

// MARK: - Styler

/// Maps the abstract document model to themed NSAttributedString display
/// attributes and back. Display (fonts, colors) is always DERIVED from the
/// custom keys — never the reverse — so serialization is exact.
struct WysiwygStyler {
    let theme: WysiwygTheme

    static let ulMarker = "\u{2022}\u{00A0}"                       // "•<nbsp>"
    static func olMarker(_ n: Int) -> String { "\(n).\u{00A0}" }   // "1.<nbsp>"

    // MARK: fonts & paragraph styles

    /// Typography: body 16 · h1 28 bold · h2 22 bold · h3 18 semibold.
    func fontSize(for block: String) -> CGFloat {
        switch block {
        case "h1": return 28
        case "h2": return 22
        case "h3": return 18
        default: return 16
        }
    }

    func font(block: String, marks: MarkSet) -> UIFont {
        let size = fontSize(for: block)
        if marks.code {
            return UIFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
        }
        let weight: UIFont.Weight
        switch block {
        case "h1", "h2": weight = .bold
        case "h3": weight = marks.bold ? .bold : .semibold
        default: weight = marks.bold ? .bold : .regular
        }
        var font = UIFont.systemFont(ofSize: size, weight: weight)
        if marks.italic || block == "blockquote" {
            let traits = font.fontDescriptor.symbolicTraits.union(.traitItalic)
            if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) {
                font = UIFont(descriptor: descriptor, size: size)
            }
        }
        return font
    }

    func paragraphStyle(for block: String) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        switch block {
        case "ul", "ol":
            style.headIndent = 22 // wrapped lines align past the marker
        case "blockquote":
            style.firstLineHeadIndent = 16
            style.headIndent = 16
        case "h1", "h2", "h3":
            style.paragraphSpacingBefore = 4
        default:
            break
        }
        return style
    }

    // MARK: model → attributes

    func attributes(block: String, marks: MarkSet) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [:]
        a[.wysiwygBlock] = block
        a[.font] = font(block: block, marks: marks)
        a[.paragraphStyle] = paragraphStyle(for: block)
        if let hex = marks.color, let color = UIColor(wysiwygHex: hex) {
            a[.wysiwygTextColor] = hex
            a[.foregroundColor] = color
        } else if block == "blockquote" {
            a[.foregroundColor] = theme.secondaryTextUIColor
        } else {
            a[.foregroundColor] = theme.textUIColor
        }
        if marks.bold { a[.wysiwygBold] = true }
        if marks.italic { a[.wysiwygItalic] = true }
        if marks.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if marks.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if marks.code {
            a[.wysiwygCode] = true
            a[.backgroundColor] = theme.textUIColor.withAlphaComponent(0.08)
        }
        if let hex = marks.highlight {
            a[.wysiwygHighlight] = hex
            if let color = UIColor(wysiwygHex: hex) {
                a[.backgroundColor] = color.withAlphaComponent(0.55) // keeps text legible on dark themes
            }
        }
        if let link = marks.link {
            a[.wysiwygLink] = link
            if let url = URL(string: link) { a[.link] = url } // display only (tinted via linkTextAttributes)
        }
        return a
    }

    func markerAttributes(block: String) -> [NSAttributedString.Key: Any] {
        [
            .wysiwygBlock: block,
            .wysiwygMarker: true,
            .font: UIFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular),
            .paragraphStyle: paragraphStyle(for: block),
            .foregroundColor: theme.secondaryTextUIColor,
        ]
    }

    // MARK: attributes → model

    func marks(from attrs: [NSAttributedString.Key: Any]) -> MarkSet {
        var m = MarkSet()
        m.link = attrs[.wysiwygLink] as? String
        m.color = attrs[.wysiwygTextColor] as? String
        m.highlight = attrs[.wysiwygHighlight] as? String
        m.bold = attrs[.wysiwygBold] as? Bool ?? false
        m.italic = attrs[.wysiwygItalic] as? Bool ?? false
        m.underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
        m.strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
        m.code = attrs[.wysiwygCode] as? Bool ?? false
        return m
    }

    // MARK: blocks → attributed string

    func attributed(_ blocks: [WysiwygBlock]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var olCount = 0
        var prevType = ""
        for (idx, block) in blocks.enumerated() {
            if block.type == "ol" { olCount = prevType == "ol" ? olCount + 1 : 1 }
            if block.type == "ul" {
                out.append(NSAttributedString(string: Self.ulMarker, attributes: markerAttributes(block: "ul")))
            } else if block.type == "ol" {
                out.append(NSAttributedString(string: Self.olMarker(olCount), attributes: markerAttributes(block: "ol")))
            }
            for run in block.runs where !run.text.isEmpty {
                out.append(NSAttributedString(string: run.text,
                                              attributes: attributes(block: block.type, marks: run.marks)))
            }
            if idx < blocks.count - 1 {
                out.append(NSAttributedString(string: "\n",
                                              attributes: attributes(block: block.type, marks: MarkSet())))
            }
            prevType = block.type
        }
        return out
    }

    // MARK: attributed string → blocks

    func blocks(from attributed: NSAttributedString) -> [WysiwygBlock] {
        let s = attributed.string as NSString
        guard s.length > 0 else { return [] }
        var result: [WysiwygBlock] = []
        var index = 0
        while index < s.length {
            let pr = s.paragraphRange(for: NSRange(location: index, length: 0))
            var content = pr
            if content.length > 0, s.character(at: NSMaxRange(content) - 1) == 0x0A {
                content.length -= 1
            }
            var type = "p"
            if pr.length > 0 {
                type = attributed.attribute(.wysiwygBlock, at: pr.location, effectiveRange: nil) as? String ?? "p"
            }
            if !WysiwygBlock.knownTypes.contains(type) { type = "p" }
            var runs: [WysiwygRun] = []
            if content.length > 0 {
                attributed.enumerateAttributes(in: content, options: []) { attrs, range, _ in
                    if attrs[.wysiwygMarker] != nil { return } // list markers are chrome, not content
                    let text = s.substring(with: range).replacingOccurrences(of: "\n", with: "")
                    guard !text.isEmpty else { return }
                    let m = marks(from: attrs)
                    if var last = runs.last, last.marks == m {
                        last.text += text
                        runs[runs.count - 1] = last
                    } else {
                        runs.append(WysiwygRun(text: text, marks: m))
                    }
                }
            }
            result.append(WysiwygBlock(type: type, runs: runs))
            index = NSMaxRange(pr)
        }
        // A trailing "\n" means the caret sits on one more (empty) paragraph.
        if s.hasSuffix("\n") { result.append(WysiwygBlock(type: "p", runs: [])) }
        return result
    }
}

/// The readout beneath the content. `maxLength` always shows as "n/max" (it is
/// a limit, not a statistic); the optional `counts` add statistics beside it.
func countsReadout(_ config: WysiwygConfig, _ characters: Int, _ words: Int) -> String {
    var parts: [String] = []

    if config.maxLength > 0 {
        parts.append("\(characters)/\(config.maxLength)")
    } else if config.counts.contains("characters") {
        parts.append("\(characters) chars")
    }
    if config.counts.contains("words") { parts.append("\(words) words") }
    if config.counts.contains("readingTime") {
        parts.append("\(max(1, Int(ceil(Double(words) / 200.0)))) min")
    }

    return parts.joined(separator: "  ·  ")
}

// MARK: - Editor model

/// Owns the UITextView document: toolbar actions, typing/selection rules,
/// list-marker management and serialization. Published state drives SwiftUI.
final class WysiwygEditorModel: NSObject, ObservableObject {
    let config: WysiwygConfig
    let styler: WysiwygStyler
    let initialAttributed: NSAttributedString
    /// The initial content re-serialized through the normaliser — the baseline
    /// the discard-confirm compares against.
    let initialNormalizedHtml: String

    weak var textView: UITextView?
    weak var placeholderLabel: UILabel?

    @Published var activeMarks = MarkSet()
    @Published var activeBlock = "p"
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var charCount = 0
    @Published var wordCount = 0

    /// Re-entrancy guards: delegate callbacks fired by our own programmatic
    /// edits must not re-trigger the pipeline.
    private var isMutating = false
    private var isNormalizing = false
    /// Set when Enter is pressed at the END of a heading/blockquote — the next
    /// paragraph starts as plain body text.
    private var makeNextParagraphPlain = false

    convenience init(config: WysiwygConfig) {
        self.init(config: config, blocks: HtmlCoder.parse(config.content))
    }

    /// Seed from a specific run of blocks — one model per TEXT segment.
    init(config: WysiwygConfig, blocks: [WysiwygBlock]) {
        self.config = config
        self.styler = WysiwygStyler(theme: config.theme)
        self.initialAttributed = styler.attributed(blocks)
        self.initialNormalizedHtml = HtmlCoder.emit(blocks).html
        super.init()
    }

    /// This segment's blocks, live from the text view.
    func blocks() -> [WysiwygBlock] {
        guard let tv = textView else { return HtmlCoder.parse(initialNormalizedHtml) }
        return styler.blocks(from: tv.attributedText)
    }

    // MARK: serialization

    func serialize() -> (html: String, text: String) {
        guard let tv = textView else { return (initialNormalizedHtml, "") }
        return HtmlCoder.emit(styler.blocks(from: tv.attributedText))
    }

    var hasChanges: Bool { serialize().html != initialNormalizedHtml }

    // MARK: storage helpers

    private var storage: NSTextStorage? { textView?.textStorage }
    private var nsText: NSString? { textView.map { $0.textStorage.string as NSString } }

    private func paragraphRange(at location: Int) -> NSRange {
        guard let s = nsText else { return NSRange(location: 0, length: 0) }
        let loc = min(max(0, location), s.length)
        return s.paragraphRange(for: NSRange(location: loc, length: 0))
    }

    private func blockType(of pr: NSRange) -> String {
        guard let st = storage, pr.length > 0, pr.location < st.length else { return "p" }
        let type = st.attribute(.wysiwygBlock, at: pr.location, effectiveRange: nil) as? String ?? "p"
        return WysiwygBlock.knownTypes.contains(type) ? type : "p"
    }

    /// Length of the leading list-marker prefix of the paragraph (0 if none).
    private func markerLength(of pr: NSRange) -> Int {
        guard let st = storage else { return 0 }
        var len = 0
        while pr.location + len < NSMaxRange(pr),
              st.attribute(.wysiwygMarker, at: pr.location + len, effectiveRange: nil) != nil {
            len += 1
        }
        return len
    }

    /// The user-content part of a paragraph: marker and trailing newline excluded.
    private func contentRange(of pr: NSRange) -> NSRange {
        guard let s = nsText else { return pr }
        var r = pr
        if r.length > 0, s.character(at: NSMaxRange(r) - 1) == 0x0A { r.length -= 1 }
        let m = markerLength(of: pr)
        r.location += m
        r.length = max(0, r.length - m)
        return r
    }

    /// Plain characters (markers and newlines excluded) in `range`.
    private func plainCount(in range: NSRange) -> Int {
        guard let st = storage, range.length > 0 else { return 0 }
        var count = 0
        st.enumerateAttribute(.wysiwygMarker, in: range, options: []) { value, r, _ in
            if value != nil { return }
            let sub = (st.string as NSString).substring(with: r)
            count += sub.reduce(0) { $0 + ($1 == "\n" ? 0 : 1) }
        }
        return count
    }

    private func totalPlainCount() -> Int {
        guard let st = storage else { return 0 }
        return plainCount(in: NSRange(location: 0, length: st.length))
    }

    // MARK: published-state refresh

    func refreshState() {
        guard let tv = textView, let st = storage else { return }
        let sel = tv.selectedRange
        let pr = paragraphRange(at: sel.location)
        if pr.length > 0 {
            activeBlock = blockType(of: pr)
        } else {
            // Empty trailing paragraph: trust the pending typing attributes.
            activeBlock = (tv.typingAttributes[.wysiwygBlock] as? String) ?? "p"
        }
        let contentStart = pr.location + markerLength(of: pr)
        var m = MarkSet()
        var refIndex: Int?
        if sel.length > 0 {
            refIndex = sel.location < st.length ? sel.location : nil
        } else if sel.location > contentStart {
            refIndex = sel.location - 1
        }
        if let idx = refIndex, idx < st.length {
            let attrs = st.attributes(at: idx, effectiveRange: nil)
            if attrs[.wysiwygMarker] == nil { m = styler.marks(from: attrs) }
        }
        // Don't drag a link along when typing right after its last character.
        if sel.length == 0, m.link != nil {
            if sel.location >= st.length {
                m.link = nil
            } else if (st.attribute(.wysiwygLink, at: sel.location, effectiveRange: nil) as? String) != m.link {
                m.link = nil
            }
        }
        activeMarks = m
        tv.typingAttributes = styler.attributes(block: activeBlock, marks: m)
        charCount = totalPlainCount()
        wordCount = storage.map { countWords(styler.blocks(from: $0)) } ?? 0
        canUndo = tv.undoManager?.canUndo ?? false
        canRedo = tv.undoManager?.canRedo ?? false
        placeholderLabel?.isHidden = st.length > 0
    }

    // MARK: delegate entry points

    func selectionChanged() {
        guard !isMutating, let tv = textView else { return }
        var sel = tv.selectedRange
        let pr = paragraphRange(at: sel.location)
        let markerEnd = pr.location + markerLength(of: pr)
        // Keep the caret out of the list-marker prefix.
        if sel.length == 0, sel.location < markerEnd, markerEnd <= (nsText?.length ?? 0) {
            sel.location = markerEnd
            tv.selectedRange = sel // re-fires the delegate; state refreshes then
            return
        }
        refreshState()
    }

    func shouldChange(_ range: NSRange, _ text: String) -> Bool {
        guard textView != nil else { return true }

        // maxLength — counts PLAIN characters (markers & newlines excluded).
        if config.maxLength > 0, !text.isEmpty {
            let inserted = text.reduce(0) { $0 + ($1 == "\n" ? 0 : 1) }
            if inserted > 0 {
                let deleted = plainCount(in: range)
                if charCount - deleted + inserted > config.maxLength { return false }
            }
        }

        if text == "\n" { return handleNewline(range) }

        // Backspacing into a list marker un-lists the item instead of eating
        // the marker character by character.
        if text.isEmpty, range.length == 1, let st = storage, range.location < st.length,
           st.attribute(.wysiwygMarker, at: range.location, effectiveRange: nil) != nil {
            convertParagraphs(in: NSRange(location: range.location, length: 0), to: "p")
            return false
        }
        return true
    }

    func didChange() {
        guard !isMutating else { return }
        if makeNextParagraphPlain {
            makeNextParagraphPlain = false
            if let tv = textView {
                let pr = paragraphRange(at: tv.selectedRange.location)
                if pr.length > 0 { setBlockAttributes(pr, to: "p") }
                tv.typingAttributes = styler.attributes(block: "p", marks: MarkSet())
            }
        }
        normalizeLists()
        refreshState()
    }

    private func didChangeExternally() {
        normalizeLists()
        refreshState()
    }

    // MARK: Enter key

    private func handleNewline(_ range: NSRange) -> Bool {
        guard let tv = textView else { return true }
        let pr = paragraphRange(at: range.location)
        let block = blockType(of: pr)
        switch block {
        case "ul", "ol":
            if contentRange(of: pr).length == 0 {
                // Enter on an EMPTY list item leaves the list (standard behavior).
                convertParagraphs(in: NSRange(location: range.location, length: 0), to: "p")
                return false
            }
            // Continue the list: newline + fresh marker inserted through the
            // input system (stays undoable); the number is fixed by renumbering.
            let marker = block == "ul" ? WysiwygStyler.ulMarker : WysiwygStyler.olMarker(1)
            isMutating = true
            tv.selectedRange = range
            tv.typingAttributes = styler.attributes(block: block, marks: MarkSet())
            tv.insertText("\n" + marker)
            let cursor = tv.selectedRange.location
            let markerLen = (marker as NSString).length
            if cursor >= markerLen {
                storage?.setAttributes(styler.markerAttributes(block: block),
                                       range: NSRange(location: cursor - markerLen, length: markerLen))
            }
            isMutating = false
            normalizeLists()
            refreshState()
            placeholderLabel?.isHidden = true
            return false
        case "h1", "h2", "h3", "blockquote":
            // Enter at the END of the block: the next paragraph is body text.
            // Mid-block Enter splits into two blocks of the same type.
            let content = contentRange(of: pr)
            if range.location >= NSMaxRange(content) { makeNextParagraphPlain = true }
            return true
        default:
            return true
        }
    }

    // MARK: inline marks

    private func applyMarks(in range: NSRange, _ transform: (inout MarkSet) -> Void) {
        guard let tv = textView, let st = storage else { return }
        if range.length == 0 {
            var m = activeMarks
            transform(&m)
            activeMarks = m
            tv.typingAttributes = styler.attributes(block: activeBlock, marks: m)
            return
        }
        st.beginEditing()
        st.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            if attrs[.wysiwygMarker] != nil { return }
            var m = styler.marks(from: attrs)
            transform(&m)
            let block = attrs[.wysiwygBlock] as? String ?? "p"
            st.setAttributes(styler.attributes(block: block, marks: m), range: r)
        }
        st.endEditing()
        refreshState()
    }

    private func applyToSelection(_ transform: (inout MarkSet) -> Void) {
        guard let tv = textView else { return }
        applyMarks(in: tv.selectedRange, transform)
    }

    func toggleInline(_ tool: String) {
        let target: Bool
        switch tool {
        case "bold": target = !activeMarks.bold
        case "italic": target = !activeMarks.italic
        case "underline": target = !activeMarks.underline
        case "strikethrough": target = !activeMarks.strike
        case "code": target = !activeMarks.code
        default: return
        }
        applyToSelection { m in
            switch tool {
            case "bold": m.bold = target
            case "italic": m.italic = target
            case "underline": m.underline = target
            case "strikethrough": m.strike = target
            case "code": m.code = target
            default: break
            }
        }
    }

    func applyTextColor(_ hex: String?) {
        applyToSelection { $0.color = hex }
    }

    func applyHighlight(_ hex: String?) {
        applyToSelection { $0.highlight = hex }
    }

    func clearFormat() {
        applyToSelection { $0 = MarkSet() }
    }

    // MARK: blocks

    func applyBlock(_ tool: String) {
        let target: String
        switch tool {
        case "bulletList": target = "ul"
        case "orderedList": target = "ol"
        default: target = tool // h1 / h2 / h3 / blockquote
        }
        guard WysiwygBlock.knownTypes.contains(target), let tv = textView else { return }
        let newBlock = activeBlock == target ? "p" : target
        convertParagraphs(in: tv.selectedRange, to: newBlock)
    }

    /// Re-style content characters of `range` for `block`, preserving marks.
    private func setBlockAttributes(_ range: NSRange, to block: String) {
        guard let st = storage, range.length > 0 else { return }
        st.beginEditing()
        st.enumerateAttributes(in: range, options: []) { attrs, r, _ in
            if attrs[.wysiwygMarker] != nil {
                st.addAttribute(.wysiwygBlock, value: block, range: r)
                return
            }
            st.setAttributes(styler.attributes(block: block, marks: styler.marks(from: attrs)), range: r)
        }
        st.endEditing()
    }

    /// Convert every paragraph touched by `selection` to `newBlock`. Marker
    /// insertion/removal is delegated to the renumbering pass.
    private func convertParagraphs(in selection: NSRange, to newBlock: String) {
        guard let tv = textView, let st = storage else { return }
        isMutating = true
        defer {
            isMutating = false
            normalizeLists()
            refreshState()
        }

        // Empty document: block lives only in the typing attributes; a list
        // gets its marker materialised immediately so the item is visible.
        if st.length == 0 {
            tv.typingAttributes = styler.attributes(block: newBlock, marks: activeMarks)
            activeBlock = newBlock
            if newBlock == "ul" || newBlock == "ol" {
                let marker = newBlock == "ul" ? WysiwygStyler.ulMarker : WysiwygStyler.olMarker(1)
                st.append(NSAttributedString(string: marker, attributes: styler.markerAttributes(block: newBlock)))
                tv.selectedRange = NSRange(location: st.length, length: 0)
                tv.undoManager?.removeAllActions()
            }
            return
        }

        let s = st.string as NSString
        let loc = min(selection.location, s.length)
        let len = min(selection.length, s.length - loc)
        let span = s.paragraphRange(for: NSRange(location: loc, length: len))

        if span.length == 0 {
            // Caret on the empty trailing paragraph.
            tv.typingAttributes = styler.attributes(block: newBlock, marks: activeMarks)
            activeBlock = newBlock
            if newBlock == "ul" || newBlock == "ol" {
                let marker = newBlock == "ul" ? WysiwygStyler.ulMarker : WysiwygStyler.olMarker(1)
                st.insert(NSAttributedString(string: marker, attributes: styler.markerAttributes(block: newBlock)),
                          at: span.location)
                tv.selectedRange = NSRange(location: span.location + (marker as NSString).length, length: 0)
                tv.undoManager?.removeAllActions()
            }
            return
        }

        var idx = span.location
        while idx < NSMaxRange(span) {
            let pr = s.paragraphRange(for: NSRange(location: idx, length: 0))
            setBlockAttributes(pr, to: newBlock) // attribute-only: lengths stable
            idx = NSMaxRange(pr)
            if pr.length == 0 { break }
        }
    }

    // MARK: list normalization

    /// One robust pass that makes the visible document consistent again after
    /// ANY edit: inserts missing list markers, removes markers on non-list
    /// paragraphs, renumbers ordered lists, deletes stray marker fragments
    /// left by multi-paragraph deletions, and re-unifies the block attribute
    /// of merged paragraphs. Text mutations here reset the undo stack (the
    /// undo manager cannot replay around them safely).
    private func normalizeLists() {
        guard let tv = textView, let st = storage, !isNormalizing else { return }
        isNormalizing = true
        defer { isNormalizing = false }

        var mutated = false
        var sel = tv.selectedRange
        var idx = 0
        var olCount = 0
        var prevType = ""

        func shiftSelection(edited: NSRange, delta: Int) {
            if sel.location >= NSMaxRange(edited) {
                sel.location += delta
            } else if sel.location > edited.location {
                sel.location = edited.location + max(0, edited.length + delta)
            }
        }

        while idx < st.length {
            let s = st.string as NSString
            let pr = s.paragraphRange(for: NSRange(location: idx, length: 0))
            if pr.length == 0 { break }
            let block = blockType(of: pr)

            var contentEnd = NSMaxRange(pr)
            if contentEnd > pr.location, s.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }

            // Leading marker prefix.
            var lead = 0
            while pr.location + lead < contentEnd,
                  st.attribute(.wysiwygMarker, at: pr.location + lead, effectiveRange: nil) != nil {
                lead += 1
            }

            // Stray marker fragments mid-paragraph (after merged deletes) → remove.
            var scan = pr.location + lead
            var stray: NSRange?
            while scan < contentEnd {
                var eff = NSRange(location: 0, length: 0)
                let isMarker = st.attribute(.wysiwygMarker, at: scan, longestEffectiveRange: &eff,
                                            in: NSRange(location: scan, length: contentEnd - scan)) != nil
                if isMarker { stray = eff; break }
                scan = NSMaxRange(eff)
            }
            if let stray {
                st.deleteCharacters(in: stray)
                mutated = true
                shiftSelection(edited: stray, delta: -stray.length)
                continue // re-process this paragraph from the same location
            }

            // Correct marker text for this block type (numbering consecutive <ol>s).
            olCount = block == "ol" ? (prevType == "ol" ? olCount + 1 : 1) : 0
            let desired: String
            switch block {
            case "ul": desired = WysiwygStyler.ulMarker
            case "ol": desired = WysiwygStyler.olMarker(olCount)
            default: desired = ""
            }
            let markerRange = NSRange(location: pr.location, length: lead)
            if s.substring(with: markerRange) != desired {
                st.replaceCharacters(in: markerRange,
                                     with: NSAttributedString(string: desired,
                                                              attributes: styler.markerAttributes(block: block)))
                mutated = true
                shiftSelection(edited: markerRange, delta: (desired as NSString).length - lead)
            }

            // Re-unify the block attribute if a merge mixed two paragraphs.
            let s2 = st.string as NSString
            let pr2 = s2.paragraphRange(for: NSRange(location: pr.location, length: 0))
            if pr2.length > 0 {
                var eff = NSRange(location: 0, length: 0)
                _ = st.attribute(.wysiwygBlock, at: pr2.location, longestEffectiveRange: &eff, in: pr2)
                if NSMaxRange(eff) < NSMaxRange(pr2) { setBlockAttributes(pr2, to: block) }
            }
            prevType = block
            idx = NSMaxRange(pr2)
            if pr2.length == 0 { break }
        }

        if mutated {
            sel.location = max(0, min(sel.location, st.length))
            sel.length = min(sel.length, st.length - sel.location)
            tv.selectedRange = sel
            tv.undoManager?.removeAllActions()
        }
    }

    // MARK: links

    func linkTapped() {
        guard let tv = textView, let st = storage else { return }
        var range = tv.selectedRange
        var existing: String?
        if range.length == 0 {
            let probe = range.location > 0 ? range.location - 1 : range.location
            if st.length > 0, probe < st.length,
               let link = st.attribute(.wysiwygLink, at: probe, effectiveRange: nil) as? String {
                var eff = NSRange(location: 0, length: 0)
                _ = st.attribute(.wysiwygLink, at: probe, longestEffectiveRange: &eff,
                                 in: NSRange(location: 0, length: st.length))
                range = eff
                existing = link
            }
        } else if range.location < st.length,
                  let link = st.attribute(.wysiwygLink, at: range.location, effectiveRange: nil) as? String {
            existing = link
        }
        presentLinkDialog(existing: existing, range: range)
    }

    private func presentLinkDialog(existing: String?, range: NSRange) {
        let alert = UIAlertController(title: existing == nil ? "Add Link" : "Edit Link",
                                      message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = "https://example.com"
            tf.text = existing
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if existing != nil {
            alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
                self?.applyMarks(in: range) { $0.link = nil }
            })
        }
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            guard let url = Self.sanitizeLink(alert?.textFields?.first?.text ?? "") else { return }
            if range.length == 0 {
                self.insertLinkedText(url, at: range.location)
            } else {
                self.applyMarks(in: range) { $0.link = url }
            }
        })
        WysiwygEditorPresenter.topController()?.present(alert, animated: true)
    }

    /// http(s)/mailto/tel pass through; a bare host gets https:// prepended;
    /// any other explicit scheme is rejected.
    static func sanitizeLink(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let lower = s.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://")
            || lower.hasPrefix("mailto:") || lower.hasPrefix("tel:") {
            return s
        }
        if s.contains("://") { return nil }
        return "https://" + s
    }

    /// No selection and no existing link: insert the URL itself as link text.
    private func insertLinkedText(_ url: String, at location: Int) {
        guard let tv = textView, let st = storage else { return }
        if config.maxLength > 0, charCount + url.count > config.maxLength { return }
        var marks = activeMarks
        marks.link = url
        let loc = min(location, st.length)
        st.insert(NSAttributedString(string: url, attributes: styler.attributes(block: activeBlock, marks: marks)),
                  at: loc)
        tv.selectedRange = NSRange(location: loc + (url as NSString).length, length: 0)
        tv.undoManager?.removeAllActions()
        didChangeExternally()
    }

    // MARK: undo / redo

    func undo() {
        textView?.undoManager?.undo()
        didChangeExternally()
    }

    func redo() {
        textView?.undoManager?.redo()
        didChangeExternally()
    }
}

// MARK: - Document model (segments)

/**
 Owns the whole document: one editor model per TEXT segment, the media blocks
 between them, and which segment currently has the caret.

 The toolbar, counters and Save all act through this, so they do not need to
 know how many editors exist. See docs/DOCUMENT-MODEL.md.
 */
/// A segment plus a STABLE id. Editor models are keyed by this rather than by
/// list position, so inserting media mid-document does not silently re-point
/// every model after it.
struct SegmentEntry: Identifiable {
    let id: Int
    var segment: Segment
}

final class WysiwygDocumentModel: ObservableObject {
    let config: WysiwygConfig
    @Published private(set) var entries: [SegmentEntry] = []
    /// Editor models keyed by segment ENTRY ID (TEXT segments only).
    private(set) var models: [Int: WysiwygEditorModel] = [:]
    private var nextId = 0

    /// The segment the caret is in — what the toolbar drives.
    @Published var focused: WysiwygEditorModel?
    @Published var charCount = 0
    @Published var wordCount = 0
    /// Bumped whenever a segment changes, so the toolbar re-reads active state.
    @Published var revision = 0

    private let initialNormalizedHtml: String

    init(config: WysiwygConfig) {
        self.config = config
        let parsed = HtmlCoder.parse(config.content)
        self.initialNormalizedHtml = HtmlCoder.emit(parsed).html

        for segment in segmentsOf(parsed) {
            let entry = SegmentEntry(id: nextId, segment: segment)
            nextId += 1
            entries.append(entry)
            if case .text(let blocks) = segment {
                models[entry.id] = WysiwygEditorModel(config: config, blocks: blocks)
            }
        }

        refreshCounts()
        focused = entries.compactMap { models[$0.id] }.first
    }

    func model(for entry: SegmentEntry) -> WysiwygEditorModel? { models[entry.id] }

    /// Reassemble the document from every segment in order.
    func blocks() -> [WysiwygBlock] {
        entries.flatMap { entry -> [WysiwygBlock] in
            switch entry.segment {
            case .text(let seeded): return models[entry.id]?.blocks() ?? seeded
            case .media(let block): return [block]
            }
        }
    }

    // MARK: media

    /// Place a media block after the focused segment, then give the user a
    /// fresh paragraph below so typing can continue.
    func insertMedia(kind: String, attrs: [String: String]) {
        var block = WysiwygBlock(type: kind, runs: [])
        block.attrs = attrs

        let at = entries.firstIndex { models[$0.id] === focused }
        let insertAt = at.map { $0 + 1 } ?? entries.count

        let mediaEntry = SegmentEntry(id: nextId, segment: .media(block))
        nextId += 1
        let textEntry = SegmentEntry(id: nextId, segment: .text([WysiwygBlock(type: "p", runs: [])]))
        nextId += 1
        models[textEntry.id] = WysiwygEditorModel(config: config, blocks: [WysiwygBlock(type: "p", runs: [])])

        entries.insert(contentsOf: [mediaEntry, textEntry], at: insertAt)
        segmentChanged()
    }

    /// Report upload progress / completion / failure for an inserted block.
    func updateUpload(uploadId: String, state: String, src: String, message: String) {
        guard let index = entries.firstIndex(where: { entry in
            if case .media(let block) = entry.segment { return block.attrs["uploadId"] == uploadId }
            return false
        }) else { return }

        guard case .media(var block) = entries[index].segment else { return }

        switch state {
        case "completed":
            if !src.isEmpty { block.attrs["src"] = src }
            block.attrs.removeValue(forKey: "uploadId")
        case "failed":
            block.attrs["uploadError"] = message.isEmpty ? "Upload failed" : message
        default:
            block.attrs["uploadProgress"] = src
        }

        entries[index].segment = .media(block)
        segmentChanged()
    }

    func serialize() -> (html: String, text: String) { HtmlCoder.emit(blocks()) }

    var hasChanges: Bool { serialize().html != initialNormalizedHtml }

    func refreshCounts() {
        let document = blocks()
        charCount = document.reduce(0) { $0 + $1.plainText.count }
        wordCount = countWords(document)
    }

    /// A segment changed: refresh the aggregate readouts and the toolbar.
    func segmentChanged() {
        refreshCounts()
        revision &+= 1
    }
}

// MARK: - UITextView wrapper

private struct RichTextView: UIViewRepresentable {
    let model: WysiwygEditorModel
    /// Segments live in a scroll view, so each editor grows to fit instead of
    /// scrolling internally.
    @Binding var height: CGFloat
    /// Only the first editor takes the keyboard when the screen opens.
    var autoFocus: Bool = true
    var onFocus: () -> Void = {}
    var onChange: () -> Void = {}

    func makeUIView(context: Context) -> UITextView {
        let theme = model.config.theme
        let tv = UITextView()
        tv.backgroundColor = .clear
        tv.allowsEditingTextAttributes = false
        tv.delegate = context.coordinator
        tv.font = UIFont.systemFont(ofSize: 16)
        tv.textColor = theme.textUIColor
        tv.tintColor = theme.accentUIColor
        tv.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        tv.keyboardDismissMode = .interactive
        tv.linkTextAttributes = [
            .foregroundColor: theme.accentUIColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.attributedText = model.initialAttributed
        tv.typingAttributes = model.styler.attributes(block: "p", marks: MarkSet())
        // The outer ScrollView scrolls; each editor sizes to its content.
        tv.isScrollEnabled = false

        // Placeholder — a plain overlaid label, hidden as soon as there is text.
        let placeholder = UILabel()
        placeholder.text = model.config.placeholder
        placeholder.font = UIFont.systemFont(ofSize: 16)
        placeholder.textColor = theme.textUIColor.withAlphaComponent(0.35)
        placeholder.frame = CGRect(x: 17, y: 14, width: UIScreen.main.bounds.width - 60, height: 22)
        placeholder.isHidden = !model.initialAttributed.string.isEmpty
        tv.addSubview(placeholder)

        model.textView = tv
        model.placeholderLabel = placeholder
        DispatchQueue.main.async {
            model.refreshState()
            recalculateHeight(tv)
            if autoFocus { tv.becomeFirstResponder() }
        }
        return tv
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        recalculateHeight(uiView)
    }

    /// Grow the editor to fit its content so the outer ScrollView can scroll
    /// the whole document rather than each segment scrolling separately.
    private func recalculateHeight(_ tv: UITextView) {
        let width = tv.bounds.width
        guard width > 0 else { return }
        let fitted = tv.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        if abs(fitted - height) > 1 {
            DispatchQueue.main.async { height = fitted }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model, onFocus: onFocus, onChange: onChange)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        let model: WysiwygEditorModel
        let onFocus: () -> Void
        let onChange: () -> Void

        init(model: WysiwygEditorModel, onFocus: @escaping () -> Void, onChange: @escaping () -> Void) {
            self.model = model
            self.onFocus = onFocus
            self.onChange = onChange
        }

        /// The toolbar follows the caret between segments.
        func textViewDidBeginEditing(_ textView: UITextView) { onFocus() }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText text: String) -> Bool {
            model.shouldChange(range, text)
        }

        func textViewDidChange(_ textView: UITextView) {
            model.didChange()
            onChange()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            model.selectionChanged()
        }

        // Links are edited via the toolbar dialog, never opened from the editor.
        func textView(_ textView: UITextView, shouldInteractWith URL: URL,
                      in characterRange: NSRange, interaction: UITextItemInteraction) -> Bool {
            false
        }
    }
}

// MARK: - Keyboard watcher

/// Publishes the keyboard height so the toolbar can sit right above it
/// (SwiftUI on iOS 15 has no built-in keyboardAdaptive modifier).
private final class KeyboardWatcher: NSObject, ObservableObject {
    @Published var height: CGFloat = 0

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(frameChanged(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        center.addObserver(self, selector: #selector(willHide(_:)),
                           name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func frameChanged(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        height = max(0, UIScreen.main.bounds.maxY - frame.origin.y)
    }

    @objc private func willHide(_ note: Notification) { height = 0 }
}

// MARK: - Editor screen

private enum PaletteKind { case text, highlight }

private struct EditorScreen: View {
    @ObservedObject var document: WysiwygDocumentModel
    let onCancel: () -> Void
    let onSave: (String, String) -> Void

    @StateObject private var keyboard = KeyboardWatcher()
    @State private var showDiscard = false
    @State private var palette: PaletteKind?
    /// Measured height per TEXT segment — each editor grows to fit.
    @State private var heights: [Int: CGFloat] = [:]

    private var theme: WysiwygTheme { document.config.theme }

    /// The first text segment takes the keyboard when the screen opens.
    private var firstTextId: Int {
        document.entries.first { if case .text = $0.segment { return true } else { return false } }?.id ?? -1
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(document.entries) { entry in
                            segmentView(entry: entry)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if !countsReadout(document.config, document.charCount, document.wordCount).isEmpty {
                    counter
                }
                if let kind = palette, let focused = document.focused {
                    PaletteRow(kind: kind, theme: theme) { hex in
                        if kind == .text { focused.applyTextColor(hex) } else { focused.applyHighlight(hex) }
                        palette = nil
                    }
                }
                if let focused = document.focused {
                    ToolbarRow(model: focused, palette: $palette)
                }
            }
            .padding(.bottom, max(0, keyboard.height - geo.safeAreaInsets.bottom))
        }
        .background(theme.backgroundColor.ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .alert("Discard changes?", isPresented: $showDiscard) {
            Button("Keep Editing", role: .cancel) {}
            Button("Discard", role: .destructive) { onCancel() }
        } message: {
            Text("Your edits will be lost.")
        }
    }

    @ViewBuilder
    private func segmentView(entry: SegmentEntry) -> some View {
        switch entry.segment {
        case .media(let block):
            MediaCardView(block: block, theme: theme)
        case .text:
            if let model = document.model(for: entry) {
                RichTextView(
                    model: model,
                    height: heightBinding(entry.id),
                    autoFocus: entry.id == firstTextId,
                    onFocus: { document.focused = model },
                    onChange: { document.segmentChanged() }
                )
                .frame(height: heights[entry.id] ?? 48)
            }
        }
    }

    private func heightBinding(_ index: Int) -> Binding<CGFloat> {
        Binding(get: { heights[index] ?? 48 }, set: { heights[index] = $0 })
    }

    private var topBar: some View {
        ZStack {
            HStack {
                Button("Cancel") { document.hasChanges ? (showDiscard = true) : onCancel() }
                    .font(.system(size: 16))
                    .foregroundColor(theme.textColor)
                Spacer()
                Button("Save") {
                    let out = document.serialize()
                    onSave(out.html, out.text)
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(theme.accentColor)
            }
            Text(document.config.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(theme.textColor)
                .lineLimit(1)
                .padding(.horizontal, 76)
        }
        .frame(height: 52)
        .padding(.horizontal, 16)
    }

    private var counter: some View {
        let over = document.config.maxLength > 0 && document.charCount >= document.config.maxLength
        return HStack {
            Spacer()
            Text(countsReadout(document.config, document.charCount, document.wordCount))
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(over ? .red : theme.textColor.opacity(0.5))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

// MARK: - Media card

/**
 A media block inside the document.

 Deliberately NOT editable text: it renders the block and its pending upload
 state. Mirrors the Android MediaCard.
 */
private struct MediaCardView: View {
    let block: WysiwygBlock
    let theme: WysiwygTheme

    private var pending: Bool {
        (block.attrs["src"] ?? "").isEmpty && !(block.attrs["uploadId"] ?? "").isEmpty
    }

    private var label: String {
        switch block.type {
        case "image": return (block.attrs["alt"]?.isEmpty == false) ? block.attrs["alt"]! : "Image"
        case "video": return "Video"
        case "file": return (block.attrs["name"]?.isEmpty == false) ? block.attrs["name"]! : "File"
        case "embed": return block.attrs["url"] ?? ""
        case "poll": return (block.attrs["question"]?.isEmpty == false) ? block.attrs["question"]! : "Poll"
        default: return block.type
        }
    }

    var body: some View {
        if block.type == "divider" {
            Rectangle()
                .fill(theme.textColor.opacity(0.25))
                .frame(height: 1)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    IconShape(data: toolIcons[block.type == "poll" ? "orderedList" : "bulletList"]?.path ?? "")
                        .stroke(style: StrokeStyle(lineWidth: 2 * 20 / 24, lineCap: .round, lineJoin: .round))
                        .foregroundColor(theme.accentColor)
                        .frame(width: 20, height: 20)
                    Text(label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(theme.textColor)
                }

                if block.type == "poll" {
                    ForEach(block.options, id: \.id) { option in
                        Text("•  \(option.label)")
                            .font(.system(size: 14))
                            .foregroundColor(theme.textColor.opacity(0.75))
                    }
                }

                if let caption = block.attrs["caption"], !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundColor(theme.textColor.opacity(0.6))
                }

                if pending {
                    Text("Uploading…")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.textColor.opacity(0.06)))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

// MARK: - Toolbar icons

/// One toolbar glyph: outline path data in a 24×24 box, plus its stroke weight.
///
/// The path strings below are the SINGLE SOURCE OF TRUTH for the toolbar's
/// appearance and are duplicated VERBATIM in the Android file — that is
/// deliberate. Platform icon sets (SF Symbols / Material) have no common
/// subset, so drawing the same vectors on both sides is the only way the two
/// toolbars can actually match. Keep the two copies in sync when editing.
private struct ToolIcon {
    let path: String
    var stroke: CGFloat = 2
}

private let toolIcons: [String: ToolIcon] = [
    "undo": ToolIcon(path: "M9 7L4 12L9 17M4 12L14 12C17.3 12 20 14.7 20 18"),
    "redo": ToolIcon(path: "M15 7L20 12L15 17M20 12L10 12C6.7 12 4 14.7 4 18"),
    "bold": ToolIcon(path: "M8 5L8 19M8 5L13 5C15.2 5 17 6.8 17 9C17 11.2 15.2 12 13 12L8 12"
        + "M8 12L14 12C16.2 12 18 13.8 18 16C18 18.2 16.2 19 14 19L8 19"),
    "italic": ToolIcon(path: "M10 5L18 5M6 19L14 19M14.5 5L9.5 19"),
    "underline": ToolIcon(path: "M6 4L6 11C6 14.3 8.7 17 12 17C15.3 17 18 14.3 18 11L18 4M5 20L19 20"),
    "strikethrough": ToolIcon(path: "M16 7C16 5.3 14.2 4 12 4C9.8 4 8 5.3 8 7C8 8.7 9.8 10 12 10"
        + "M12 14C14.2 14 16 15.3 16 17C16 18.7 14.2 20 12 20C9.8 20 8 18.7 8 17M4 12L20 12"),
    "h1": ToolIcon(path: "M4 6L4 18M4 12L11 12M11 6L11 18M15 9.5L17.5 8L17.5 18"),
    "h2": ToolIcon(path: "M4 6L4 18M4 12L11 12M11 6L11 18"
        + "M15 9.5C15 8.4 16 7.5 17.2 7.5C18.7 7.5 19.7 8.6 19.7 10C19.7 12.5 15 14.5 15 18L19.7 18"),
    "h3": ToolIcon(path: "M4 6L4 18M4 12L11 12M11 6L11 18"
        + "M15 8L19.5 8L16.8 11.5C18.6 11.5 19.9 12.7 19.9 14.5C19.9 16.5 18.5 18 16.7 18C15.8 18 15.2 17.7 14.8 17.2"),
    "bulletList": ToolIcon(path: "M4 7L4.01 7M9 7L20 7M4 12L4.01 12M9 12L20 12M4 17L4.01 17M9 17L20 17"),
    "orderedList": ToolIcon(path: "M3.6 5.2L4.7 4.6L4.7 8.4"
        + "M3.2 11.1C3.2 10.4 3.8 9.9 4.5 9.9C5.3 9.9 5.8 10.5 5.8 11.2C5.8 12.4 3.2 13.2 3.2 14.5L5.9 14.5"
        + "M3.3 15.9L5.9 15.9L4.5 17.7C5.3 17.7 6 18.3 6 19.1C6 19.9 5.4 20.5 4.6 20.5C4 20.5 3.6 20.3 3.3 20"
        + "M9 6.5L20 6.5M9 12.2L20 12.2M9 18L20 18", stroke: 1.5),
    "blockquote": ToolIcon(path: "M4 5L4 19M9 8L20 8M9 12L20 12M9 16L17 16"),
    "link": ToolIcon(path: "M9.5 12L14.5 12"
        + "M10 8L7.5 8C5.3 8 3.5 9.8 3.5 12C3.5 14.2 5.3 16 7.5 16L10 16"
        + "M14 8L16.5 8C18.7 8 20.5 9.8 20.5 12C20.5 14.2 18.7 16 16.5 16L14 16"),
    "code": ToolIcon(path: "M9 8L4.5 12L9 16M15 8L19.5 12L15 16"),
    "textColor": ToolIcon(path: "M5 15L10 5L15 15M6.8 11.6L13.2 11.6M4 19.5L20 19.5"),
    "highlight": ToolIcon(path: "M15 4L20 9L10 19L5 19L5 14L15 4M13 6L18 11"),
    "clearFormat": ToolIcon(path: "M5 15L10 5L15 15M6.8 11.6L13.2 11.6M4 4L20 20"),
    // Insert tools: a framed picture, a play triangle, a paperclip.
    "image": ToolIcon(path: "M3.5 5.5L20.5 5.5L20.5 18.5L3.5 18.5L3.5 5.5"
        + "M3.5 15L8.5 10.5L12.5 14L15.5 11.5L20.5 16M15.5 9.2L15.51 9.2"),
    "video": ToolIcon(path: "M3.5 6L16 6L16 18L3.5 18L3.5 6M16 10.5L20.5 8L20.5 16L16 13.5"),
    "file": ToolIcon(path: "M16.5 7.5L9 15C7.6 16.4 7.6 18.6 9 20C10.4 21.4 12.6 21.4 14 20L19.5 14.5"
        + "C21.6 12.4 21.6 9.1 19.5 7C17.4 4.9 14.1 4.9 12 7L6.5 12.5"),
]

/**
 Parse the mini path language into a SwiftUI Path, scaled from the 24×24
 design box. Supported commands (a deliberately tiny SVG subset, so the
 renderer on each platform stays short): M x y · L x y · C x1 y1 x2 y2 x y · Z.
 A near-zero-length line with a round cap renders as a dot (used by the lists).
 Unknown commands are ignored rather than trapping — a malformed glyph should
 never crash the editor.
 */
private struct IconShape: Shape {
    let data: String

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let k = min(rect.width, rect.height) / 24
        var args: [CGFloat] = []
        var command: Character = " "
        let chars = Array(data)
        var i = 0

        func expected(_ c: Character) -> Int {
            switch c {
            case "M", "L": return 2
            case "C": return 6
            default: return 0
            }
        }

        func emit() {
            switch command {
            case "M":
                if args.count >= 2 { path.move(to: CGPoint(x: args[0] * k, y: args[1] * k)) }
            case "L":
                if args.count >= 2 { path.addLine(to: CGPoint(x: args[0] * k, y: args[1] * k)) }
            case "C":
                if args.count >= 6 {
                    path.addCurve(to: CGPoint(x: args[4] * k, y: args[5] * k),
                                  control1: CGPoint(x: args[0] * k, y: args[1] * k),
                                  control2: CGPoint(x: args[2] * k, y: args[3] * k))
                }
            default:
                break
            }
            args.removeAll()
        }

        while i < chars.count {
            let c = chars[i]
            if c.isLetter {
                args.removeAll()
                command = Character(c.uppercased())
                if command == "Z" { path.closeSubpath() }
                i += 1
            } else if c == " " || c == "," {
                i += 1
            } else {
                let start = i
                if chars[i] == "-" { i += 1 }
                while i < chars.count, chars[i].isNumber || chars[i] == "." { i += 1 }
                args.append(CGFloat(Double(String(chars[start..<i])) ?? 0))
                if args.count == expected(command) { emit() }
            }
        }

        return path
    }
}

// MARK: - Formatting toolbar

private struct ToolbarRow: View {
    @ObservedObject var model: WysiwygEditorModel
    @Binding var palette: PaletteKind?

    private var theme: WysiwygTheme { model.config.theme }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                // Undo / redo are always present, ahead of the configured tools.
                button("undo", active: false, enabled: model.canUndo) { model.undo() }
                button("redo", active: false, enabled: model.canRedo) { model.redo() }
                Rectangle()
                    .fill(theme.textColor.opacity(0.15))
                    .frame(width: 1, height: 22)
                    .padding(.horizontal, 6)
                ForEach(model.config.toolbar, id: \.self) { tool in
                    toolButton(tool)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(theme.backgroundColor.overlay(theme.textColor.opacity(0.04)))
        .overlay(Rectangle().fill(theme.textColor.opacity(0.12)).frame(height: 0.5), alignment: .top)
    }

    @ViewBuilder
    private func toolButton(_ tool: String) -> some View {
        switch tool {
        case "bold":
            button("bold", active: model.activeMarks.bold) { model.toggleInline("bold") }
        case "italic":
            button("italic", active: model.activeMarks.italic) { model.toggleInline("italic") }
        case "underline":
            button("underline", active: model.activeMarks.underline) { model.toggleInline("underline") }
        case "strikethrough":
            button("strikethrough", active: model.activeMarks.strike) { model.toggleInline("strikethrough") }
        case "h1":
            button("h1", active: model.activeBlock == "h1") { model.applyBlock("h1") }
        case "h2":
            button("h2", active: model.activeBlock == "h2") { model.applyBlock("h2") }
        case "h3":
            button("h3", active: model.activeBlock == "h3") { model.applyBlock("h3") }
        case "bulletList":
            button("bulletList", active: model.activeBlock == "ul") { model.applyBlock("bulletList") }
        case "orderedList":
            button("orderedList", active: model.activeBlock == "ol") { model.applyBlock("orderedList") }
        case "blockquote":
            button("blockquote", active: model.activeBlock == "blockquote") { model.applyBlock("blockquote") }
        case "link":
            button("link", active: model.activeMarks.link != nil) { model.linkTapped() }
        case "code":
            button("code", active: model.activeMarks.code) {
                model.toggleInline("code")
            }
        case "textColor":
            button("textColor", active: model.activeMarks.color != nil || palette == .text) {
                palette = palette == .text ? nil : .text
            }
        case "highlight":
            button("highlight", active: model.activeMarks.highlight != nil || palette == .highlight) {
                palette = palette == .highlight ? nil : .highlight
            }
        case "clearFormat":
            button("clearFormat", active: false) { model.clearFormat() }
        case "image", "video", "file":
            button(tool, active: false) { requestMedia(tool) }
        default:
            EmptyView()
        }
    }

    /// Draws the SHARED vector glyph for `tool` — deliberately not an SF
    /// Symbol, so the toolbar is identical to Android's (see ToolIcon).
    /// Ask the HOST to pick media — the editor ships no picker.
    private func requestMedia(_ kind: String) {
        var payload: [String: Any] = ["kind": kind]
        if let id = model.config.id { payload["id"] = id }
        LaravelBridge.shared.send?(WysiwygEvents.mediaRequested, payload)
    }

    private func button(_ tool: String, active: Bool, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        let icon = toolIcons[tool] ?? ToolIcon(path: "")
        let glyph: CGFloat = 21

        return Button(action: action) {
            IconShape(data: icon.path)
                .stroke(style: StrokeStyle(lineWidth: icon.stroke * glyph / 24,
                                           lineCap: .round, lineJoin: .round))
                .foregroundColor(active ? theme.highlightColor
                                        : theme.textColor.opacity(enabled ? 0.78 : 0.28))
                .frame(width: glyph, height: glyph)
                .frame(width: 38, height: 34)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(active ? theme.highlightColor.opacity(0.16) : Color.clear))
        }
        .disabled(!enabled)
    }
}

// MARK: - Color palette row

private struct PaletteRow: View {
    let kind: PaletteKind
    let theme: WysiwygTheme
    let onPick: (String?) -> Void

    /// Fixed palettes — SAME values as the Android implementation (normative).
    static let textColors = ["#EF4444", "#F97316", "#EAB308", "#22C55E", "#3B82F6", "#A855F7"]
    static let highlights = ["#FDE68A", "#FED7AA", "#BBF7D0", "#BFDBFE", "#E9D5FF", "#FBCFE8"]

    var body: some View {
        HStack(spacing: 14) {
            Button { onPick(nil) } label: {
                Image(systemName: "slash.circle")
                    .font(.system(size: 22))
                    .foregroundColor(theme.textColor.opacity(0.6))
            }
            ForEach(kind == .text ? Self.textColors : Self.highlights, id: \.self) { hex in
                Button { onPick(hex) } label: {
                    Circle()
                        .fill(Color(UIColor(wysiwygHex: hex) ?? .gray))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(theme.textColor.opacity(0.25), lineWidth: 1))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(theme.backgroundColor.overlay(theme.textColor.opacity(0.06)))
    }
}

// MARK: - Presenter

final class WysiwygEditorPresenter {
    static let shared = WysiwygEditorPresenter()
    private var hosting: UIHostingController<AnyView>?
    private var finished = false

    func present(config: WysiwygConfig) {
        // Re-entrancy guard: only one editor at a time. A second Open (e.g. a
        // double-tap) is rejected with a cancel for its OWN id, so it can't
        // orphan the live editor or lose an event.
        guard hosting == nil else { send(WysiwygEvents.cancelled, ["id": config.id]); return }

        finished = false
        let document = WysiwygDocumentModel(config: config)
        // Reachable by the InsertMedia / UpdateUpload bridge functions while open.
        WysiwygEditorFunctions.live = document
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = config.theme.backgroundUIColor
        host.rootView = AnyView(EditorScreen(
            document: document,
            onCancel: { [weak self] in
                self?.finish(WysiwygEvents.cancelled, ["id": config.id])
            },
            onSave: { [weak self] html, text in
                self?.finish(WysiwygEvents.saved, ["html": html, "text": text, "id": config.id])
            }
        ))
        hosting = host
        // Present once the top view controller is idle. When Open is called
        // right after another modal is dismissed, iOS SILENTLY refuses the
        // presentation — so we retry until it's ready.
        presentWhenReady(host, id: config.id, attempts: 0)
    }

    private func presentWhenReady(_ host: UIViewController, id: String?, attempts: Int) {
        guard let top = Self.topController(), !top.isBeingDismissed, !top.isBeingPresented else {
            guard attempts < 25 else { finish(WysiwygEvents.cancelled, ["id": id]); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.presentWhenReady(host, id: id, attempts: attempts + 1)
            }
            return
        }
        top.present(host, animated: true)
    }

    private func dismiss() {
        hosting?.dismiss(animated: true)
        hosting = nil
    }

    /// Deliver EXACTLY ONE terminal event for the current editor, then tear it
    /// down. Guards against Save racing Cancel firing two events per session.
    private func finish(_ event: String, _ payload: [String: Any?]) {
        guard !finished else { return }
        finished = true
        dismiss()
        send(event, payload)
    }

    private func send(_ event: String, _ payload: [String: Any?]) {
        var clean: [String: Any] = [:]
        for (k, v) in payload {
            if let v, !(v is NSNull) { clean[k] = v }
        }
        LaravelBridge.shared.send?(event, clean)
    }

    static func topController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
