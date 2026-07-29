import Foundation
import AVKit
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

    /**
     Show a media block full-screen.

     Lives here rather than in the host app because the platform has no video
     element to build a viewer out of, and because the editor already decodes
     images and plays video for its own cards — a host rendering SAVED content
     should not have to write that twice.
     */
    class Preview: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            let kind = parameters["kind"] as? String ?? "image"
            let source = parameters["source"] as? String ?? ""
            let caption = parameters["caption"] as? String ?? ""

            guard !source.isEmpty else { return [:] }

            DispatchQueue.main.async {
                WysiwygMediaPreview.present(kind: kind, source: source, caption: caption)
            }

            return [:]
        }
    }

    /// Update one host row while the editor is open.
    class SetAccessory: BridgeFunction {
        func execute(parameters: [String: Any]) throws -> [String: Any] {
            let accessory = parameters["accessory"] as? String ?? ""
            let label = parameters["label"] as? String ?? ""
            let value = parameters["value"] as? String ?? ""

            guard !accessory.isEmpty else { return [:] }

            DispatchQueue.main.async {
                WysiwygEditorFunctions.live?.setAccessory(id: accessory, label: label, value: value)
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
    static let mediaEditRequested = "Vipertecpro\\WysiwygEditor\\Events\\MediaEditRequested"
    static let accessoryTapped = "Vipertecpro\\WysiwygEditor\\Events\\AccessoryTapped"
    static let draftRequested = "Vipertecpro\\WysiwygEditor\\Events\\DraftRequested"
    static let toolTapped = "Vipertecpro\\WysiwygEditor\\Events\\ToolTapped"
    static let changed = "Vipertecpro\\WysiwygEditor\\Events\\ContentChanged"
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
    static let insertTools = ["image", "camera", "video", "file"]
    static let allTools = [
        "bold", "italic", "underline", "strikethrough", "h1", "h2", "h3",
        "bulletList", "orderedList", "blockquote", "link", "code",
        "textColor", "highlight", "image", "camera", "video", "file",
        "poll", "divider", "embed", "clearFormat",
    ]

    let content: String
    let contentJson: String
    let toolbar: [String]
    let title: String
    let placeholder: String
    let maxLength: Int
    let counts: [String]
    let menu: String
    let countStyle: String
    let maxLengthMode: String
    let saveStyle: String
    let cancelMode: String
    let cancelStyle: String
    let mediaLayout: String
    let maxMedia: Int
    let pollOptionMaxLength: Int
    let pollMinOptions: Int
    let pollMaxOptions: Int
    /// Label key -> minutes. Ordered by the ordering of the keys in PHP.
    let pollDurations: [(key: String, minutes: Int)]
    let history: Bool
    /// Rows the HOST owns, drawn under the media. See WysiwygAccessory.
    let accessories: [WysiwygAccessory]
    /// Extra toolbar buttons the host defines — see WysiwygCustomTool.
    let customTools: [WysiwygCustomTool]
    /// The author's picture, beside what they are writing.
    let avatar: String
    let typography: WysiwygTypography
    let spacing: WysiwygSpacing
    let validation: [String: Any]
    let strings: [String: String]
    let changeDebounce: Int
    let haptics: Bool
    let theme: WysiwygTheme
    let id: String?

    init(_ p: [String: Any]) {
        content = p["content"] as? String ?? ""
        contentJson = p["contentJson"] as? String ?? ""
        // An explicit empty list means NO toolbar; a list of names we do not
        // know falls back, so a typo cannot silently strip the bar.
        if let asked = p["toolbar"] as? [String] {
            let known = asked.filter { Self.allTools.contains($0) }
            toolbar = asked.isEmpty ? [] : (known.isEmpty ? Self.allTools : known)
        } else {
            toolbar = Self.allTools
        }
        title = p["title"] as? String ?? ""
        placeholder = p["placeholder"] as? String ?? ""
        maxLength = max(0, (p["maxLength"] as? NSNumber)?.intValue ?? 0)
        counts = p["counts"] as? [String] ?? []
        menu = p["menu"] as? String ?? "toolbar"
        countStyle = p["countStyle"] as? String ?? "text"
        maxLengthMode = p["maxLengthMode"] as? String ?? "hard"
        saveStyle = p["saveStyle"] as? String ?? "text"
        cancelMode = p["cancelMode"] as? String ?? "discard"
        cancelStyle = p["cancelStyle"] as? String ?? "text"
        mediaLayout = p["mediaLayout"] as? String ?? "blocks"
        maxMedia = max(0, (p["maxMedia"] as? NSNumber)?.intValue ?? 4)
        pollOptionMaxLength = max(1, (p["pollOptionMaxLength"] as? NSNumber)?.intValue ?? 25)
        pollMinOptions = max(2, (p["pollMinOptions"] as? NSNumber)?.intValue ?? 2)
        pollMaxOptions = max(2, (p["pollMaxOptions"] as? NSNumber)?.intValue ?? 4)
        // JSON objects have no order, so the shortest-first ordering the
        // durations are declared in has to be restored by sorting.
        let durations = (p["pollDurations"] as? [String: Any]) ?? [:]
        pollDurations = durations
            .compactMap { key, value in
                (value as? NSNumber).map { (key: key, minutes: $0.intValue) }
            }
            .sorted { $0.minutes < $1.minutes }
        history = (p["history"] as? NSNumber)?.boolValue ?? true
        accessories = ((p["accessories"] as? [[String: Any]]) ?? []).map(WysiwygAccessory.init)
        customTools = ((p["customTools"] as? [[String: Any]]) ?? []).map(WysiwygCustomTool.init)
        avatar = p["avatar"] as? String ?? ""
        typography = WysiwygTypography(p["typography"] as? [String: Any])
        spacing = WysiwygSpacing(named: p["spacing"] as? String ?? "comfortable")
        validation = p["validation"] as? [String: Any] ?? [:]
        strings = p["strings"] as? [String: String] ?? [:]
        changeDebounce = max(0, (p["changeDebounce"] as? NSNumber)?.intValue ?? 0)
        haptics = (p["haptics"] as? NSNumber)?.boolValue ?? true
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
    /// Shading on characters past `maxLength` in soft mode. Ours, not the
    /// user's highlight mark — clearing it must not clear theirs.
    static let wysiwygOverflow = NSAttributedString.Key("wysiwygOverflow")
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
        // durationMinutes is what the AUTHOR chose; closesAt is what a
        // host computes from it. Both travel, because the editor owns no
        // clock and cannot turn one into the other.
        "poll": ["question", "multiple", "durationMinutes", "closesAt"],
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
        case "embed":
            // A host that fetched a preview passes a title; otherwise the URL
            // is all we honestly have.
            if let title = block.attrs["title"], !title.isEmpty { return title }
            return block.attrs["url"] ?? ""
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

/// A user-visible string, translated by the host when it supplied one.
///
/// `{n}` / `{max}` / `{type}` placeholders are substituted here so the host's
/// translation controls word order, which matters in languages where the
/// number does not come first.
func localized(
    _ strings: [String: String],
    _ key: String,
    _ fallback: String,
    n: Any? = nil,
    max: Any? = nil,
    type: String? = nil
) -> String {
    var out = strings[key] ?? fallback
    if let n { out = out.replacingOccurrences(of: "{n}", with: "\(n)") }
    if let max { out = out.replacingOccurrences(of: "{max}", with: "\(max)") }
    if let type { out = out.replacingOccurrences(of: "{type}", with: type) }
    return out
}

/// Declarative save-time rules. Evaluated natively so a failing document never
/// makes the round-trip to PHP just to be rejected.
///
/// Returns the first violation as a human-readable message, or nil when the
/// document may be saved.
func validateDocument(
    _ blocks: [WysiwygBlock],
    _ rules: [String: Any],
    _ strings: [String: String] = [:]
) -> String? {
    if rules.isEmpty { return nil }

    let words = countWords(blocks)

    if let min = (rules["minWords"] as? NSNumber)?.intValue, min > 0, words < min {
        return localized(strings, "ruleMinWords",
                         "At least {max} words needed — you have {n}.", n: words, max: min)
    }
    if let max = (rules["maxWords"] as? NSNumber)?.intValue, max > 0, words > max {
        return localized(strings, "ruleMaxWords",
                         "At most {max} words allowed — you have {n}.", n: words, max: max)
    }
    if let max = (rules["maxImages"] as? NSNumber)?.intValue {
        let images = blocks.filter { $0.type == "image" }.count
        if images > max {
            return localized(strings, "ruleMaxImages",
                             "At most {max} image(s) allowed — you have {n}.", n: images, max: max)
        }
    }
    if let required = rules["requiredBlocks"] as? [String] {
        for type in required where !blocks.contains(where: { $0.type == type }) {
            return localized(strings, "ruleRequiredBlock", "This needs at least one {type}.", type: type)
        }
    }

    return nil
}

// MARK: - Embeds

/**
 Which service an embed URL points at, or "" when it is not one we recognise.

 Deliberately derived from the URL and NOTHING else. The plugin makes no
 network requests — fetching OpenGraph tags to build a preview would quietly
 turn a zero-permission editor into one that phones out from inside the user's
 document. A host that wants a rich preview fetches it with its own network and
 auth and passes `title` / `thumbnail` to `insertMedia`.

 Normative: Kotlin's `embedProvider` returns the same string for the same URL,
 and the parity harness asserts it.
 */
func embedProvider(_ url: String) -> String {
    let lower = url.lowercased()

    // Match on the HOST only, so a path like /youtube.com/fake cannot spoof it.
    var host = lower
    if let range = host.range(of: "://") { host = String(host[range.upperBound...]) }
    if let slash = host.firstIndex(of: "/") { host = String(host[..<slash]) }
    if let colon = host.firstIndex(of: ":") { host = String(host[..<colon]) }
    if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
    if host.hasPrefix("m.") { host = String(host.dropFirst(2)) }

    switch host {
    case "youtube.com", "youtu.be", "youtube-nocookie.com": return "YouTube"
    case "vimeo.com", "player.vimeo.com": return "Vimeo"
    case "twitter.com", "x.com": return "X"
    case "open.spotify.com", "spotify.com": return "Spotify"
    case "soundcloud.com": return "SoundCloud"
    case "codepen.io": return "CodePen"
    case "gist.github.com", "github.com": return "GitHub"
    case "figma.com": return "Figma"
    case "loom.com": return "Loom"
    case "tiktok.com": return "TikTok"
    case "instagram.com": return "Instagram"
    case "maps.google.com", "google.com": return "Google Maps"
    default: return ""
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
                // A blank answer is not an answer. The composer keeps empty
                // rows so you can type into them; the saved document must not.
                let answers = block.options.filter {
                    !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                for (index, option) in answers.enumerated() {
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

// MARK: - Host accessories

/**
 One row the host application put in the composer.

 The editor draws it and reports the tap; it does not know or care what the
 row means. That is the whole point — "Tag people" is the app's feature backed
 by the app's data, and an editor that tried to own it would be guessing.
 */
/**
 One toolbar button the host application added.

 The editor draws it and reports the tap. It cannot know what a GIF picker or
 a scheduler should do — those are the app's features, backed by the app's
 services.
 */
struct WysiwygCustomTool: Identifiable {
    let id: String
    let icon: String
    let label: String

    init(_ p: [String: Any]) {
        id = p["id"] as? String ?? ""
        icon = p["icon"] as? String ?? ""
        label = p["label"] as? String ?? ""
    }
}

struct WysiwygAccessory: Identifiable {
    let id: String
    var label: String
    var value: String
    let icon: String

    init(_ p: [String: Any]) {
        id = p["id"] as? String ?? ""
        label = p["label"] as? String ?? ""
        value = p["value"] as? String ?? ""
        icon = p["icon"] as? String ?? ""
    }
}

// MARK: - Typography & spacing

/**
 Type settings.

 The heading ramp is DERIVED from the body size with fixed multipliers rather
 than configured separately, so a host that wants larger text sets one number
 and the proportions hold. The multipliers are normative — Kotlin uses the
 same three — and the default base of 16 reproduces the 28 / 22 / 18 ramp the
 editor used before the option existed.
 */
struct WysiwygTypography {
    let fontFamily: String
    let base: CGFloat
    let lineHeight: CGFloat

    init(_ p: [String: Any]?) {
        fontFamily = (p?["fontFamily"] as? String) ?? ""
        base = CGFloat((p?["fontSize"] as? NSNumber)?.doubleValue ?? 16)
        lineHeight = CGFloat((p?["lineHeight"] as? NSNumber)?.doubleValue ?? 1.15)
    }

    func size(for block: String) -> CGFloat {
        switch block {
        case "h1": return (base * 1.75).rounded()
        case "h2": return (base * 1.375).rounded()
        case "h3": return (base * 1.125).rounded()
        default: return base
        }
    }

}

/// Editing density. Points here, dp on Android — the same numbers either way.
struct WysiwygSpacing {
    let horizontal: CGFloat
    let vertical: CGFloat
    let paragraph: CGFloat

    init(named: String) {
        switch named {
        case "compact": (horizontal, vertical, paragraph) = (12, 8, 4)
        case "roomy": (horizontal, vertical, paragraph) = (20, 18, 10)
        default: (horizontal, vertical, paragraph) = (16, 12, 6)
        }
    }
}

// MARK: - Styler

extension WysiwygTypography {
    /// The host app's font at `size`, falling back to the system font when the
    /// name does not resolve — a theme naming a font the app never bundled
    /// should not leave the editor with no text.
    ///
    /// Split from the rest of WysiwygTypography deliberately: everything above
    /// the Styler marker is compiled by the parity harness WITHOUT UIKit, so
    /// the size ramp can be asserted off-device. Anything touching UIFont has
    /// to live below the line.
    func font(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        if !fontFamily.isEmpty, let named = UIFont(name: fontFamily, size: size) {
            let descriptor = named.fontDescriptor.addingAttributes([
                .traits: [UIFontDescriptor.TraitKey.weight: weight],
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return UIFont.systemFont(ofSize: size, weight: weight)
    }
}

/// Maps the abstract document model to themed NSAttributedString display
/// attributes and back. Display (fonts, colors) is always DERIVED from the
/// custom keys — never the reverse — so serialization is exact.
struct WysiwygStyler {
    let theme: WysiwygTheme
    var typography = WysiwygTypography(nil)
    var spacing = WysiwygSpacing(named: "comfortable")

    static let ulMarker = "\u{2022}\u{00A0}"                       // "•<nbsp>"
    static func olMarker(_ n: Int) -> String { "\(n).\u{00A0}" }   // "1.<nbsp>"

    // MARK: fonts & paragraph styles

    /// Derived from the configured body size — see WysiwygTypography.
    func fontSize(for block: String) -> CGFloat { typography.size(for: block) }

    func font(block: String, marks: MarkSet) -> UIFont {
        let size = fontSize(for: block)
        // Code stays monospaced whatever the host font is: a proportional
        // face defeats the point of marking something as code.
        if marks.code {
            return UIFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
        }
        let weight: UIFont.Weight
        switch block {
        case "h1", "h2": weight = .bold
        case "h3": weight = marks.bold ? .bold : .semibold
        default: weight = marks.bold ? .bold : .regular
        }
        var font = typography.font(size: size, weight: weight)
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
        style.paragraphSpacing = spacing.paragraph
        style.lineHeightMultiple = typography.lineHeight
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
        parts.append(localized(config.strings, "countCharacters", "{n} chars", n: characters))
    }
    if config.counts.contains("words") {
        parts.append(localized(config.strings, "countWords", "{n} words", n: words))
    }
    if config.counts.contains("readingTime") {
        let minutes = max(1, Int(ceil(Double(words) / 200.0)))
        parts.append(localized(config.strings, "countReadingTime", "{n} min", n: minutes))
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
        self.styler = WysiwygStyler(theme: config.theme,
                                    typography: config.typography,
                                    spacing: config.spacing)
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

    /**
     Shade whatever runs past `maxLength`.

     Soft mode lets the writer overrun deliberately; the ring says by how much,
     and this says exactly WHICH words have to go. Without it the ring reports
     a number the writer then has to find by counting.

     Only the characters that COUNT are counted — list markers are chrome, so
     a bulleted line does not shift the boundary.
     */
    private func markOverflow() {
        guard let st = storage, config.maxLength > 0, config.maxLengthMode == "soft" else { return }

        let whole = NSRange(location: 0, length: st.length)
        st.removeAttribute(.wysiwygOverflow, range: whole)
        st.removeAttribute(.backgroundColor, range: whole)

        // Put back the backgrounds that are not ours: a user highlight, and
        // the tint inline code carries.
        st.enumerateAttribute(.wysiwygHighlight, in: whole) { value, range, _ in
            if let hex = value as? String, let color = UIColor(wysiwygHex: hex) {
                st.addAttribute(.backgroundColor, value: color.withAlphaComponent(0.55), range: range)
            }
        }
        st.enumerateAttribute(.wysiwygCode, in: whole) { value, range, _ in
            if value != nil {
                st.addAttribute(.backgroundColor,
                                value: styler.theme.textUIColor.withAlphaComponent(0.08),
                                range: range)
            }
        }

        var plain = 0
        var start: Int?
        st.enumerateAttributes(in: whole) { attrs, range, stop in
            if attrs[.wysiwygMarker] != nil { return }
            let text = (st.string as NSString).substring(with: range)
            for (offset, character) in text.enumerated() where character != "\n" {
                plain += 1
                if plain > config.maxLength {
                    start = range.location + offset
                    stop.pointee = true

                    return
                }
            }
        }

        guard let start, start < st.length else { return }

        let overflow = NSRange(location: start, length: st.length - start)
        st.addAttribute(.wysiwygOverflow, value: true, range: overflow)
        st.addAttribute(.backgroundColor, value: UIColor.systemRed.withAlphaComponent(0.28),
                        range: overflow)
    }

    func refreshState() {
        markOverflow()
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
        // In `soft` mode the keystroke is allowed through: the overflow is
        // marked and SAVE is blocked instead. Refusing it hides the problem,
        // because the writer cannot see how much they have to cut.
        if config.maxLength > 0, config.maxLengthMode == "hard", !text.isEmpty {
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
        let alert = UIAlertController(title: localized(config.strings, "linkTitle", "Add Link"),
                                      message: nil, preferredStyle: .alert)
        alert.addTextField { tf in
            tf.placeholder = localized(self.config.strings, "linkPlaceholder", "https://example.com")
            tf.text = existing
            tf.keyboardType = .URL
            tf.autocapitalizationType = .none
            tf.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: localized(config.strings, "cancel", "Cancel"), style: .cancel))
        if existing != nil {
            alert.addAction(UIAlertAction(title: localized(config.strings, "linkRemove", "Remove"),
                                          style: .destructive) { [weak self] _ in
                self?.applyMarks(in: range) { $0.link = nil }
            })
        }
        alert.addAction(UIAlertAction(title: localized(config.strings, "save", "Save"),
                                      style: .default) { [weak self, weak alert] _ in
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

    /// Length of this segment's styled text — where a following segment's
    /// content lands once the two are merged.
    var styledLength: Int {
        textView?.textStorage.length ?? initialAttributed.length
    }

    /// Swap this segment's whole content, putting the caret at `caretAt`.
    ///
    /// Used when a media card between two text segments is deleted and the two
    /// have to become one. Only the surviving segment is rebuilt, so every
    /// other segment keeps its own undo history.
    func replaceDocument(_ blocks: [WysiwygBlock], caretAt: Int) {
        guard let tv = textView else { return }
        isMutating = true
        tv.attributedText = styler.attributed(blocks)
        isMutating = false
        let safe = min(max(0, caretAt), tv.textStorage.length)
        tv.selectedRange = NSRange(location: safe, length: 0)
        didChangeExternally()
    }

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
        // JSON first: it is the canonical form, and HTML deliberately cannot
        // carry a device path, so a document re-opened from HTML would lose
        // every image whose upload had not finished.
        let parsed = config.contentJson.isEmpty
            ? HtmlCoder.parse(config.content)
            : JsonCoder.decode(config.contentJson)
        self.initialNormalizedHtml = HtmlCoder.emit(parsed).html

        for segment in segmentsOf(parsed) {
            let entry = SegmentEntry(id: nextId, segment: segment)
            nextId += 1
            entries.append(entry)
            if case .text(let blocks) = segment {
                models[entry.id] = WysiwygEditorModel(config: config, blocks: blocks)
            }
        }

        accessories = config.accessories
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

        insertBlock(block)
    }

    /// Block types the strip carries. A poll is content you EDIT, and a
    /// divider is punctuation — neither is a file you attached, so neither
    /// belongs in a row of thumbnails.
    static let strippableTypes: Set<String> = ["image", "video", "file"]

    /// Attachments, in insertion order — what the strip lays out.
    var mediaEntries: [SegmentEntry] {
        entries.filter {
            if case .media(let block) = $0.segment {
                return Self.strippableTypes.contains(block.type)
            }
            return false
        }
    }

    /// Whether another attachment is allowed. `maxMedia == 0` means no cap.
    var canAttachMore: Bool {
        config.maxMedia == 0 || mediaEntries.count < config.maxMedia
    }

    /// Drop one attachment. Any empty text segment left stranded beside it
    /// goes too, so removing the last photo does not leave a blank card.
    func removeEntry(id: Int) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }

        entries.remove(at: index)
        models.removeValue(forKey: id)
        segmentChanged()
    }

    /// Insert an empty poll with the fewest answers that make one.
    func insertPoll() {
        var block = WysiwygBlock(type: "poll", runs: [])
        block.attrs["question"] = ""
        block.attrs["durationMinutes"] = String(config.pollDurations.first?.minutes ?? 1440)
        block.options = (1...config.pollMinOptions).map { PollOption(id: "o\($0)", label: "") }
        insertBlock(block)
    }

    // MARK: poll editing

    /// Edit one answer. The cap is not enforced here: the card SHOWS the
    /// overrun instead, the same way the character ring does, so the author
    /// can see what has to go rather than losing the keystroke.
    func setPollOption(id: Int, option index: Int, label: String) {
        guard let position = entries.firstIndex(where: { $0.id == id }),
              case .media(var block) = entries[position].segment,
              block.options.indices.contains(index) else { return }

        block.options[index].label = label
        entries[position].segment = .media(block)
        segmentChanged()
    }

    func addPollOption(id: Int) {
        guard let position = entries.firstIndex(where: { $0.id == id }),
              case .media(var block) = entries[position].segment,
              block.options.count < config.pollMaxOptions else { return }

        block.options.append(PollOption(id: "o\(block.options.count + 1)", label: ""))
        entries[position].segment = .media(block)
        segmentChanged()
    }

    /// Step to the next offered length. A tap cycling through three choices
    /// beats a picker for something with three choices.
    func cyclePollDuration(id: Int) {
        guard let position = entries.firstIndex(where: { $0.id == id }),
              case .media(var block) = entries[position].segment,
              !config.pollDurations.isEmpty else { return }

        let current = Int(block.attrs["durationMinutes"] ?? "") ?? config.pollDurations[0].minutes
        let index = config.pollDurations.firstIndex { $0.minutes == current } ?? 0
        let next = config.pollDurations[(index + 1) % config.pollDurations.count]

        block.attrs["durationMinutes"] = String(next.minutes)
        entries[position].segment = .media(block)
        segmentChanged()
    }

    /// A picture for one answer. The editor ships no picker, so this asks the
    /// host the same way the toolbar does.
    func requestPollOptionMedia(id: Int, option index: Int) {
        var payload: [String: Any] = ["kind": "image", "pollEntry": id, "pollOption": index]
        if let identifier = config.id { payload["id"] = identifier }
        LaravelBridge.shared.send?(WysiwygEvents.mediaRequested, payload)
    }

    /// Does this poll have anything worth warning about before it is removed?
    func pollHasContent(id: Int) -> Bool {
        guard let position = entries.firstIndex(where: { $0.id == id }),
              case .media(let block) = entries[position].segment else { return false }

        if !(block.attrs["question"] ?? "").isEmpty { return true }

        return block.options.contains { !$0.label.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Set a block's alt text — the description a screen reader reads out.
    func setAlt(id: Int, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case .media(var block) = entries[index].segment else { return }

        block.attrs["alt"] = text
        entries[index].segment = .media(block)
        segmentChanged()
    }

    /// Place a composed block after the focused segment, then give the user a
    /// fresh paragraph below so typing can continue.
    ///
    /// In `strip` layout the block is appended instead: attachments there
    /// belong to the post rather than to a position in the prose, and no
    /// paragraph is needed after them.
    func insertBlock(_ block: WysiwygBlock) {
        if config.mediaLayout == "strip", Self.strippableTypes.contains(block.type) {
            guard canAttachMore else { return }

            entries.append(SegmentEntry(id: nextId, segment: .media(block)))
            nextId += 1
            segmentChanged()

            return
        }

        insertBlockInFlow(block)
    }

    private func insertBlockInFlow(_ block: WysiwygBlock) {
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

    /**
     Backspace pressed with the caret at the very start of a text segment.

     If a media card sits directly above, it is deleted — matching what Notes
     and Docs do, where backspacing into an image removes it rather than doing
     nothing. When that leaves two text segments touching, they merge into one
     and the caret lands on the join.

     Returns true when the keystroke was consumed.
     */
    func handleBackspaceAtStart(entryId: Int) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryId }), index > 0 else { return false }
        guard case .media = entries[index - 1].segment else { return false }

        entries.remove(at: index - 1)
        let position = index - 1

        // Two text segments are now adjacent — fold the lower one into the
        // upper one so the document keeps ONE editor per run of text.
        if position > 0, case .text = entries[position - 1].segment,
           let above = models[entries[position - 1].id], let mine = models[entryId] {
            let join = above.styledLength + 1
            above.replaceDocument(above.blocks() + mine.blocks(), caretAt: join)
            models.removeValue(forKey: entryId)
            entries.remove(at: position)
            focused = above
            DispatchQueue.main.async { above.textView?.becomeFirstResponder() }
        }

        segmentChanged()
        return true
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

    /// The host's rows, live — `setAccessory` edits these in place so
    /// "Add location" can become the place that was picked.
    @Published var accessories: [WysiwygAccessory] = []

    func setAccessory(id: String, label: String, value: String) {
        guard let index = accessories.firstIndex(where: { $0.id == id }) else { return }

        if !label.isEmpty { accessories[index].label = label }
        accessories[index].value = value
    }

    /// The auto-save seam: emit ContentChanged once the user stops typing, so
    /// the host can persist a draft without the editor owning drafts itself.
    /// Off unless `changeDebounce` > 0.
    var onContentChanged: ((String, String, String) -> Void)?
    private var changeWorkItem: DispatchWorkItem?

    /// A segment changed: refresh the aggregate readouts and the toolbar.
    func segmentChanged() {
        refreshCounts()
        revision &+= 1
        scheduleChangeEvent()
    }

    private func scheduleChangeEvent() {
        guard config.changeDebounce > 0, let emit = onContentChanged else { return }
        changeWorkItem?.cancel()

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let document = self.blocks()
            let out = HtmlCoder.emit(document)
            emit(out.html, out.text, JsonCoder.encode(document))
        }
        changeWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(config.changeDebounce), execute: item
        )
    }
}

// MARK: - UITextView wrapper

/**
 UITextView that reports a backspace pressed at offset 0.

 UIKit does not route that through `shouldChangeTextIn` — there is nothing to
 change — so the only place to see it is `deleteBackward()`. It is what lets a
 media card above be deleted by backspacing into it.
 */
private final class BoundaryTextView: UITextView {
    /// Returning true consumes the keystroke.
    var onBackspaceAtStart: (() -> Bool)?

    override func deleteBackward() {
        if selectedRange.location == 0, selectedRange.length == 0,
           onBackspaceAtStart?() == true {
            return
        }
        super.deleteBackward()
    }
}

private struct RichTextView: UIViewRepresentable {
    let model: WysiwygEditorModel
    /// Segments live in a scroll view, so each editor grows to fit instead of
    /// scrolling internally.
    @Binding var height: CGFloat
    /// Only the first editor takes the keyboard when the screen opens, and
    /// only the first shows the placeholder — otherwise every text segment
    /// under a media card repeats it.
    var autoFocus: Bool = true
    var onFocus: () -> Void = {}
    var onChange: () -> Void = {}
    /// Backspace at offset 0 — returning true consumes it.
    var onBackspaceAtStart: () -> Bool = { false }

    func makeUIView(context: Context) -> UITextView {
        let theme = model.config.theme
        let tv = BoundaryTextView()
        tv.onBackspaceAtStart = onBackspaceAtStart
        tv.backgroundColor = .clear
        tv.allowsEditingTextAttributes = false
        tv.delegate = context.coordinator
        tv.font = model.config.typography.font(size: model.config.typography.base, weight: .regular)
        tv.textColor = theme.textUIColor
        tv.tintColor = theme.accentUIColor
        let inset = model.config.spacing
        tv.textContainerInset = UIEdgeInsets(top: inset.vertical, left: inset.horizontal,
                                             bottom: inset.vertical, right: inset.horizontal)
        tv.keyboardDismissMode = .interactive
        tv.linkTextAttributes = [
            .foregroundColor: theme.accentUIColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        tv.attributedText = model.initialAttributed
        tv.typingAttributes = model.styler.attributes(block: "p", marks: MarkSet())
        // The outer ScrollView scrolls; each editor sizes to its content.
        tv.isScrollEnabled = false
        // A non-scrolling UITextView reports an intrinsic width as wide as its
        // LONGEST LINE. Left alone it hands that width to SwiftUI, which sizes
        // the whole editor to it — so one long paragraph pushes the top bar
        // and toolbar off the screen and the text never wraps. Refusing to
        // resist horizontal compression makes it take the width it is given
        // and wrap inside it, which is the only thing we ever want here.
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.textContainer.widthTracksTextView = true
        tv.textContainer.lineBreakMode = .byWordWrapping

        // Placeholder — a plain overlaid label, hidden as soon as there is text.
        let placeholder = UILabel()
        placeholder.text = autoFocus ? model.config.placeholder : ""
        placeholder.font = model.config.typography.font(size: model.config.typography.base,
                                                        weight: .regular)
        placeholder.textColor = theme.textUIColor.withAlphaComponent(0.35)
        // Sits exactly where the first character will, so it does not jump.
        placeholder.frame = CGRect(x: inset.horizontal + 5, y: inset.vertical,
                                   width: UIScreen.main.bounds.width - inset.horizontal * 2 - 10,
                                   height: model.config.typography.base * 1.4)
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
    let onSave: (String, String, String) -> Void

    @StateObject private var keyboard = KeyboardWatcher()
    @State private var showDiscard = false
    @State private var validationMessage: String?
    @State private var palette: PaletteKind?
    /// Which bottom sheet is open, in `menu: sheet` mode.
    @State private var sheet: SheetKind?
    /// The attachment whose description is being written.
    @State private var describing: SegmentEntry?
    /// The poll awaiting a removal confirm.
    @State private var removingPoll: SegmentEntry?
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
                // The author's picture beside what they are writing, the way
                // every social composer arranges it. Top-aligned, because the
                // text grows downward past it.
                HStack(alignment: .top, spacing: 0) {
                    if !document.config.avatar.isEmpty {
                        AvatarView(source: document.config.avatar, theme: theme)
                            .padding(.leading, 16)
                            .padding(.top, 14)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(flowEntries) { entry in
                                segmentView(entry: entry)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if document.config.mediaLayout == "strip", !document.mediaEntries.isEmpty {
                    MediaStrip(document: document, theme: theme,
                               onEdit: requestMediaEdit,
                               onDescribe: { describing = $0 })
                }

                // The host's own rows, under the media and above the counter —
                // where every composer that has them puts them.
                if !document.accessories.isEmpty {
                    AccessoryRows(document: document, theme: theme) { accessory in
                        var payload: [String: Any] = ["accessory": accessory]
                        if let id = document.config.id { payload["id"] = id }
                        LaravelBridge.shared.send?(WysiwygEvents.accessoryTapped, payload)
                    }
                }

                // The ring rides in the toolbar when there IS one; only the
                // text readout, or a ring with no bar to sit in, takes a row.
                if showsCounterRow {
                    counter
                }
                if let kind = palette, let focused = document.focused {
                    PaletteRow(kind: kind, theme: theme) { hex in
                        if kind == .text { focused.applyTextColor(hex) } else { focused.applyHighlight(hex) }
                        palette = nil
                    }
                }
                if let focused = document.focused, showsToolbar {
                    ToolbarRow(model: focused, palette: $palette, sheet: $sheet,
                               onDocumentTool: { apply($0, focused) },
                               ringCount: ringInBar ? document.charCount : nil,
                               ringLimit: document.config.maxLength)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, max(0, keyboard.height - geo.safeAreaInsets.bottom))
            .overlay(sheetOverlay)
            .onChange(of: describing?.id) { _ in
                guard let entry = describing else { return }
                describing = nil
                promptForAlt(entry)
            }
        }
        .background(theme.backgroundColor.ignoresSafeArea())
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .alert(draftMode
                ? localized(document.config.strings, "draftTitle", "Save post?")
                : localized(document.config.strings, "discardTitle", "Discard changes?"),
               isPresented: $showDiscard) {
            if draftMode {
                // Delete is the destructive one; Save is what a half-written
                // post deserves by default.
                Button(localized(document.config.strings, "draftDelete", "Delete"),
                       role: .destructive) { onCancel() }
                Button(localized(document.config.strings, "draftSave", "Save")) {
                    let blocks = document.blocks()
                    let out = HtmlCoder.emit(blocks)
                    var payload: [String: Any] = [
                        "html": out.html,
                        "text": out.text,
                        "json": JsonCoder.encode(blocks),
                    ]
                    if let id = document.config.id { payload["id"] = id }
                    LaravelBridge.shared.send?(WysiwygEvents.draftRequested, payload)
                    onCancel()
                }
            } else {
                Button(localized(document.config.strings, "keepEditing", "Keep Editing"),
                       role: .cancel) {}
                Button(localized(document.config.strings, "discard", "Discard"),
                       role: .destructive) { onCancel() }
            }
        } message: {
            Text(draftMode
                ? localized(document.config.strings, "draftMessage", "You can finish it later.")
                : localized(document.config.strings, "discardMessage", "Your edits will be lost."))
        }
        .alert(localized(document.config.strings, "pollRemoveTitle", "Are you sure?"),
               isPresented: Binding(
            get: { removingPoll != nil },
            set: { if !$0 { removingPoll = nil } }
        )) {
            Button(localized(document.config.strings, "cancel", "Cancel"), role: .cancel) {
                removingPoll = nil
            }
            Button(localized(document.config.strings, "pollRemove", "Remove"), role: .destructive) {
                if let entry = removingPoll { document.removeEntry(id: entry.id) }
                removingPoll = nil
            }
        } message: {
            Text(localized(document.config.strings, "pollRemoveMessage",
                           "Removing the poll will discard what you have typed."))
        }
        .alert(localized(document.config.strings, "cannotSaveTitle", "Cannot save yet"),
               isPresented: Binding(
            get: { validationMessage != nil },
            set: { if !$0 { validationMessage = nil } }
        )) {
            Button(localized(document.config.strings, "ok", "OK"), role: .cancel) {
                validationMessage = nil
            }
        } message: {
            Text(validationMessage ?? "")
        }
    }

    /// The open sheet, over everything including the toolbar.
    @ViewBuilder
    private var sheetOverlay: some View {
        if let kind = sheet, let focused = document.focused {
            switch kind {
            case .format:
                WysiwygSheet(theme: theme,
                             title: localized(document.config.strings, "menuFormat", "Format"),
                             onDismiss: { sheet = nil }) {
                    formatSheetBody(focused)
                }
            case .insert:
                WysiwygSheet(theme: theme,
                             title: localized(document.config.strings, "menuInsert", "Insert"),
                             onDismiss: { sheet = nil }) {
                    insertSheetBody(focused)
                }
            }
        }
    }

    /**
     Play a video card full-screen.

     Full-screen rather than inline on purpose: an inline player inside an
     editing surface fights the caret and the keyboard for focus, and every
     editor worth copying (Notes, Docs, Notion) shows a still and plays on tap.
     */
    private func playVideo(_ block: WysiwygBlock) {
        let source = block.attrs["src"]?.isEmpty == false
            ? block.attrs["src"]!
            : (block.attrs["localPath"] ?? "")

        guard !source.isEmpty else { return }

        // A local pick is a file path, not a URL, until the host uploads it.
        let url = source.hasPrefix("http") ? URL(string: source)
                                           : URL(fileURLWithPath: source)

        guard let url else { return }

        let controller = AVPlayerViewController()
        controller.player = AVPlayer(url: url)
        WysiwygEditorPresenter.topController()?.present(controller, animated: true) {
            controller.player?.play()
        }
    }

    /// Ask for a URL and insert an embed block for it.
    ///
    /// No preview is fetched — see `embedProvider`. The card shows which
    /// service the link points at, and renders a title / thumbnail only if the
    /// HOST supplied one via `insertMedia`.
    private func promptForEmbed() {
        let strings = document.config.strings
        let alert = UIAlertController(title: localized(strings, "embedTitle", "Embed a link"),
                                      message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = localized(strings, "embedPlaceholder", "https://youtube.com/watch?v=…")
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: localized(strings, "cancel", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: localized(strings, "embedAdd", "Embed"), style: .default) { _ in
            let url = (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            guard !url.isEmpty else { return }

            var block = WysiwygBlock(type: "embed", runs: [])
            block.attrs["url"] = url
            let provider = embedProvider(url)
            if !provider.isEmpty { block.attrs["provider"] = provider }
            document.insertBlock(block)
        })

        WysiwygEditorPresenter.topController()?.present(alert, animated: true)
    }

    /// Only tools the host actually enabled appear, and a section with nothing
    /// in it is not drawn at all — the sheet reflects the config, not a menu of
    /// everything the plugin could do.
    private func enabled(_ tools: [String]) -> [String] {
        tools.filter { document.config.toolbar.contains($0) }
    }

    private func row(_ tool: String, _ model: WysiwygEditorModel,
                     label: String? = nil) -> some View {
        let key = toolLabelKeys[tool] ?? tool
        return SheetRow(tool: tool,
                        label: label ?? localized(document.config.strings, key, tool),
                        active: isActive(tool, model: model, palette: palette),
                        theme: theme) {
            if document.config.haptics {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            apply(tool, model)
        }
    }

    /// Colour tools open the palette, so the sheet gets out of the way. Every
    /// other tool leaves it open, which makes bold-then-italic two taps.
    private func apply(_ tool: String, _ model: WysiwygEditorModel) {
        switch tool {
        case "bold", "italic", "underline", "strikethrough", "code":
            model.toggleInline(tool)
        case "p", "h1", "h2", "h3", "bulletList", "orderedList", "blockquote":
            model.applyBlock(tool)
        case "clearFormat":
            model.clearFormat()
        case "textColor":
            palette = .text
            sheet = nil
        case "highlight":
            palette = .highlight
            sheet = nil
        case "link":
            sheet = nil
            model.linkTapped()
        case let custom where custom.hasPrefix("custom:"):
            sheet = nil
            var payload: [String: Any] = ["tool": String(custom.dropFirst("custom:".count))]
            if let id = document.config.id { payload["id"] = id }
            LaravelBridge.shared.send?(WysiwygEvents.toolTapped, payload)
        case "image", "camera", "video", "file":
            sheet = nil
            var payload: [String: Any] = ["kind": tool]
            if let id = document.config.id { payload["id"] = id }
            LaravelBridge.shared.send?(WysiwygEvents.mediaRequested, payload)
        case "poll":
            // Composed HERE, not by the host: there is nothing to pick and
            // nothing to upload, so a round-trip would buy nothing. Inserted
            // blank and edited in place — a poll IS the post as much as the
            // words are, and writing one behind a sheet hides what it belongs to.
            sheet = nil
            document.insertPoll()
        case "divider":
            sheet = nil
            document.insertBlock(WysiwygBlock(type: "divider", runs: []))
        case "embed":
            sheet = nil
            promptForEmbed()
        default:
            break
        }
    }

    @ViewBuilder
    private func formatSheetBody(_ model: WysiwygEditorModel) -> some View {
        let styles = enabled(sheetTextStyleTools)
        let lists = enabled(sheetListTools)
        let marks = enabled(sheetFormatTools)

        VStack(spacing: 0) {
            // Body is always offered: without it there is no way back to plain
            // text once a heading has been applied.
            SheetSection(title: localized(document.config.strings, "sectionTextStyle", "Text style"),
                         theme: theme)
            row("p", model, label: localized(document.config.strings, "styleBody", "Body"))
            ForEach(styles, id: \.self) { row($0, model) }

            if !lists.isEmpty {
                SheetSection(title: localized(document.config.strings, "sectionLists", "Lists"),
                             theme: theme)
                ForEach(lists, id: \.self) { row($0, model) }
            }

            if !marks.isEmpty {
                SheetSection(title: localized(document.config.strings, "sectionFormat", "Formatting"),
                             theme: theme)
                ForEach(marks, id: \.self) { row($0, model) }
            }
        }
    }

    @ViewBuilder
    private func insertSheetBody(_ model: WysiwygEditorModel) -> some View {
        VStack(spacing: 0) {
            ForEach(enabled(sheetInsertTools), id: \.self) { row($0, model) }
        }
    }

    @ViewBuilder
    private func segmentView(entry: SegmentEntry) -> some View {
        switch entry.segment {
        case .media(let block):
            if block.type == "poll" {
                PollCard(document: document, entry: entry, block: block, theme: theme) {
                    // Only warn when there is something to lose.
                    if document.pollHasContent(id: entry.id) {
                        removingPoll = entry
                    } else {
                        document.removeEntry(id: entry.id)
                    }
                }
            } else {
                MediaCardView(block: block, theme: theme, strings: document.config.strings)
                    .onTapGesture {
                        if block.type == "video" { playVideo(block) }
                    }
            }
        case .text:
            if let model = document.model(for: entry) {
                RichTextView(
                    model: model,
                    height: heightBinding(entry.id),
                    autoFocus: entry.id == firstTextId,
                    onFocus: { document.focused = model },
                    onChange: { document.segmentChanged() },
                    onBackspaceAtStart: { document.handleBackspaceAtStart(entryId: entry.id) }
                )
                .frame(maxWidth: .infinity)
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
                Button {
                    document.hasChanges ? (showDiscard = true) : onCancel()
                } label: {
                    if document.config.cancelStyle == "icon" {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundColor(theme.textColor)
                            .frame(width: 32, height: 32)
                    } else {
                        Text(localized(document.config.strings, "cancel", "Cancel"))
                            .font(.system(size: 16))
                            .foregroundColor(theme.textColor)
                    }
                }
                Spacer()
                saveButton
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

    /// What the document area draws. In `strip` layout media is pulled out of
    /// the flow, so only the text is left here.
    private var flowEntries: [SegmentEntry] {
        guard document.config.mediaLayout == "strip" else { return document.entries }

        return document.entries.filter { entry in
            if case .media(let block) = entry.segment {
                return !WysiwygDocumentModel.strippableTypes.contains(block.type)
            }
            return true
        }
    }

    /// The editor does not crop or filter — that is the picker's job, and the
    /// host already chose which one it uses. Say which block, and step back.
    private func requestMediaEdit(_ block: WysiwygBlock) {
        var payload: [String: Any] = [
            "kind": block.type,
            "uploadId": block.attrs["uploadId"] ?? "",
            "source": block.attrs["src"]?.isEmpty == false
                ? block.attrs["src"]!
                : (block.attrs["localPath"] ?? ""),
        ]
        if let id = document.config.id { payload["id"] = id }
        LaravelBridge.shared.send?(WysiwygEvents.mediaEditRequested, payload)
    }

    /// Ask for the description a screen reader will read out.
    private func promptForAlt(_ entry: SegmentEntry) {
        guard case .media(let block) = entry.segment else { return }

        let strings = document.config.strings
        let alert = UIAlertController(title: localized(strings, "altTitle", "Description"),
                                      message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = localized(strings, "altPlaceholder",
                                          "Describe this for people who cannot see it")
            field.text = block.attrs["alt"]
        }
        alert.addAction(UIAlertAction(title: localized(strings, "cancel", "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: localized(strings, "altSave", "Done"), style: .default) { _ in
            document.setAlt(id: entry.id, text: alert.textFields?.first?.text ?? "")
        })

        WysiwygEditorPresenter.topController()?.present(alert, animated: true)
    }

    /// Backing out offers to keep the document rather than bin it.
    private var draftMode: Bool { document.config.cancelMode == "draft" }

    private var showsToolbar: Bool {
        !(document.config.toolbar.isEmpty && !document.config.history)
    }

    /// A ring needs a limit to count toward; without one it falls back to text.
    private var wantsRing: Bool {
        document.config.countStyle == "ring" && document.config.maxLength > 0
    }

    private var ringInBar: Bool { wantsRing && showsToolbar }

    private var showsCounterRow: Bool {
        if ringInBar { return false }
        if wantsRing { return true }
        return !countsReadout(document.config, document.charCount, document.wordCount).isEmpty
    }

    /// Over the soft cap, empty, or short of a rule — either way saving is
    /// refused, so the button should look refused rather than lie and then
    /// complain.
    ///
    /// Empty counts as refused only for the FILLED style: that shape is a
    /// primary action in a composer, and every composer greys it out until
    /// there is something to send. The plain text button keeps working on an
    /// empty document, because an editor that cannot be closed via Save with
    /// nothing in it would be a regression.
    private var canSave: Bool {
        if overLimit { return false }
        // "Empty" means no text AND no media. A photo with no caption, or a
        // poll on its own, is a perfectly good post — requiring words to go
        // with them would be the editor deciding what a document is.
        if document.blocks().allSatisfy({ $0.isText && $0.isEmpty }) { return false }
        return validateDocument(document.blocks(), document.config.validation,
                                document.config.strings) == nil
    }

    /// `hard` mode never gets here — the keystroke was rejected — so this is
    /// only ever true in `soft` mode.
    private var overLimit: Bool {
        document.config.maxLength > 0 && document.charCount > document.config.maxLength
    }

    @ViewBuilder
    private var saveButton: some View {
        let label = localized(document.config.strings, "save", "Save")
        let filled = document.config.saveStyle == "filled"

        Button {
            let blocks = document.blocks()
            if let problem = validateDocument(blocks, document.config.validation,
                                              document.config.strings) {
                // Blocked natively — a failing document never makes the
                // round-trip to PHP just to be rejected.
                validationMessage = problem
                return
            }
            let out = HtmlCoder.emit(blocks)
            onSave(out.html, out.text, JsonCoder.encode(blocks))
        } label: {
            if filled {
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(theme.backgroundColor)
                    .padding(.horizontal, 16)
                    .frame(height: 34)
                    .background(Capsule().fill(theme.accentColor.opacity(canSave ? 1 : 0.4)))
            } else {
                Text(label)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(theme.accentColor)
            }
        }
        // Only the filled style disables: a plain text button that does
        // nothing when tapped reads as broken, so there it still explains why.
        .disabled(filled && !canSave)
    }

    @ViewBuilder
    private var counter: some View {
        // A ring counts toward a limit, so without one there is nothing to
        // fill and it falls back to the text readout.
        if document.config.countStyle == "ring", document.config.maxLength > 0 {
            HStack {
                Spacer()
                CountRing(count: document.charCount,
                          limit: document.config.maxLength,
                          theme: theme)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
        } else {
            let over = document.config.maxLength > 0 && document.charCount >= document.config.maxLength
            HStack {
                Spacer()
                Text(countsReadout(document.config, document.charCount, document.wordCount))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(over ? .red : theme.textColor.opacity(0.5))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }
}

// MARK: - Poll card

/**
 A poll, edited where it sits.

 Not a modal: a poll IS the post as much as the words are, and writing one
 behind a sheet means you cannot see what you are attaching it to. Every
 platform that runs polls edits them inline for that reason.

 The option cap is enforced by SHOWING the overrun rather than refusing the
 keystroke — the same reasoning as the character ring, and the same red.
 */
private struct PollCard: View {
    @ObservedObject var document: WysiwygDocumentModel
    let entry: SegmentEntry
    let block: WysiwygBlock
    let theme: WysiwygTheme
    let onRemove: () -> Void

    private var strings: [String: String] { document.config.strings }
    private var limit: Int { document.config.pollOptionMaxLength }

    private var durationLabel: String {
        let minutes = Int(block.attrs["durationMinutes"] ?? "") ?? document.config.pollDurations.first?.minutes ?? 1440
        let match = document.config.pollDurations.first { $0.minutes == minutes }

        return localized(strings, match?.key ?? "pollDay1", "1 day")
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(block.options.enumerated()), id: \.element.id) { index, option in
                optionRow(index: index, option: option)
            }

            if block.options.count < document.config.pollMaxOptions {
                Button {
                    document.addPollOption(id: entry.id)
                } label: {
                    Text(localized(strings, "pollAddOption", "Add option"))
                        .font(.system(size: 15))
                        .foregroundColor(theme.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            // How long it runs. The editor records the choice; turning it into
            // a closing time is the host's job, because the editor owns no clock.
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(localized(strings, "pollLength", "Poll length"))
                        .font(.system(size: 13))
                        .foregroundColor(theme.textColor.opacity(0.5))
                    Text(durationLabel)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { document.cyclePollDuration(id: entry.id) }
        }
        .padding(14)
        .overlay(
            RoundedCornerRect(radius: 14)
                .stroke(theme.textColor.opacity(0.2), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(theme.textColor.opacity(0.7))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(theme.textColor.opacity(0.1)))
            }
            .padding(6)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func optionRow(index: Int, option: PollOption) -> some View {
        let remaining = limit - option.label.count
        let over = remaining < 0

        return HStack(spacing: 10) {
            // Each answer may carry its own picture, which is what turns a
            // poll into something you can vote on by sight.
            Button {
                document.requestPollOptionMedia(id: entry.id, option: index)
            } label: {
                ZStack {
                    RoundedCornerRect(radius: 10).fill(theme.textColor.opacity(0.07))
                    IconShape(data: toolIcons["image"]?.path ?? "")
                        .stroke(style: StrokeStyle(lineWidth: 2 * 18 / 24, lineCap: .round, lineJoin: .round))
                        .foregroundColor(theme.textColor.opacity(0.45))
                        .frame(width: 18, height: 18)
                }
                .frame(width: 46, height: 46)
            }

            HStack(spacing: 6) {
                TextField(
                    localized(strings, "pollOption", "Option {n}", n: index + 1),
                    text: Binding(
                        get: { option.label },
                        set: { document.setPollOption(id: entry.id, option: index, label: $0) }
                    )
                )
                .font(.system(size: 15))
                .foregroundColor(theme.textColor)

                // Only once it matters — the same rule as the ring.
                if remaining <= 5 {
                    Text("\(remaining)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(over ? .red : theme.textColor.opacity(0.45))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .overlay(
                RoundedCornerRect(radius: 12)
                    .stroke(over ? Color.red : theme.textColor.opacity(0.2), lineWidth: 1)
            )
        }
    }
}

// MARK: - Accessory rows

/// The host's rows: an icon, a label, and whatever value the app set.
private struct AccessoryRows: View {
    @ObservedObject var document: WysiwygDocumentModel
    let theme: WysiwygTheme
    let onTap: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(document.accessories) { accessory in
                Button {
                    onTap(accessory.id)
                } label: {
                    HStack(spacing: 12) {
                        if !accessory.icon.isEmpty, let icon = toolIcons[accessory.icon] {
                            IconShape(data: icon.path)
                                .stroke(style: StrokeStyle(lineWidth: 2 * 18 / 24,
                                                           lineCap: .round, lineJoin: .round))
                                .foregroundColor(theme.accentColor)
                                .frame(width: 18, height: 18)
                        }

                        Text(accessory.label)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(theme.accentColor)

                        Spacer()

                        if !accessory.value.isEmpty {
                            Text(accessory.value)
                                .font(.system(size: 14))
                                .foregroundColor(theme.textColor.opacity(0.55))
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
            }
        }
    }
}

// MARK: - Avatar

/// The author's picture. Decoded the same way media is, so a local file works
/// as well as a url — an app that has not uploaded an avatar yet still shows
/// one.
private struct AvatarView: View {
    let source: String
    let theme: WysiwygTheme

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Circle().fill(theme.textColor.opacity(0.1))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .clipShape(Circle())
            }
        }
        .frame(width: 40, height: 40)
        .task(id: source) {
            guard !source.isEmpty else { return }
            let path = source
            image = await Task.detached(priority: .userInitiated) {
                decodeMediaImage(path, maxPixels: 160)
            }.value
        }
    }
}

// MARK: - Media strip

/**
 Attachments as a horizontal row of thumbnails under the text.

 What a social composer does, and for a good reason: a photo attached to a
 short post belongs to the POST, not to a position in the prose, and a
 full-width card each would push the writing off the screen before the second
 one landed.

 Each thumbnail carries its own controls, because that is where the user
 expects to find them — remove, a description for people who cannot see it,
 and edit, which hands the job back to the host's own picker.
 */
private struct MediaStrip: View {
    @ObservedObject var document: WysiwygDocumentModel
    let theme: WysiwygTheme
    let onEdit: (WysiwygBlock) -> Void
    let onDescribe: (SegmentEntry) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(document.mediaEntries) { entry in
                    if case .media(let block) = entry.segment {
                        thumbnail(entry: entry, block: block)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func thumbnail(entry: SegmentEntry, block: WysiwygBlock) -> some View {
        ZStack(alignment: .topTrailing) {
            MediaThumbnail(block: block, theme: theme)
                .frame(width: 150, height: 150)
                .clipShape(RoundedCornerRect(radius: 14))

            // Remove, top-right, over a scrim so it reads on any photo.
            Button {
                document.removeEntry(id: entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .padding(6)

            VStack {
                Spacer()
                HStack {
                    Button {
                        onDescribe(entry)
                    } label: {
                        Text(localized(document.config.strings, "altBadge", "+ALT"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                    Spacer()
                    Button {
                        onEdit(block)
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                }
                .padding(6)
            }
            .frame(width: 150, height: 150)
        }
    }
}

/// The picture on a thumbnail: the decoded image, a poster for video, or the
/// block's own glyph when there is nothing to show yet.
private struct MediaThumbnail: View {
    let block: WysiwygBlock
    let theme: WysiwygTheme

    @State private var image: UIImage?

    private var source: String {
        if block.type == "video", let poster = block.attrs["poster"], !poster.isEmpty { return poster }
        if let src = block.attrs["src"], !src.isEmpty { return src }
        return block.attrs["localPath"] ?? ""
    }

    var body: some View {
        ZStack {
            theme.textColor.opacity(0.08)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                IconShape(data: toolIcons[cardIconKey(block.type)]?.path ?? "")
                    .stroke(style: StrokeStyle(lineWidth: 2 * 26 / 24, lineCap: .round, lineJoin: .round))
                    .foregroundColor(theme.textColor.opacity(0.45))
                    .frame(width: 26, height: 26)
            }

            // A poll has no picture at all, so it says what it is.
            if block.type == "poll" {
                VStack {
                    Spacer()
                    Text(block.attrs["question"] ?? "Poll")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.textColor)
                        .lineLimit(2)
                        .padding(8)
                }
            }
        }
        .task(id: source) {
            guard !source.isEmpty, ["image", "video"].contains(block.type) else { return }
            let path = source
            image = await Task.detached(priority: .userInitiated) {
                decodeMediaImage(path, maxPixels: 600)
            }.value
        }
    }
}

/// Rounding all four corners without reaching for `cornerRadius`, which clips
/// differently across the versions this supports.
private struct RoundedCornerRect: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath)
    }
}

// MARK: - Count ring

/**
 A filling circle counting toward `limit`, the way social composers do.

 Three states, because a bare percentage does not tell a writer what to do:
 filling quietly, a warning once the end is in sight, and — past the limit —
 the ring stops growing and shows how far OVER they are, which is the number
 they actually need.
 */
private struct CountRing: View {
    let count: Int
    let limit: Int
    let theme: WysiwygTheme

    /// The last stretch, where X switches its ring to amber.
    private static let warnAt = 20

    private var remaining: Int { limit - count }
    private var over: Bool { remaining < 0 }
    private var nearingEnd: Bool { remaining <= Self.warnAt && !over }

    private var progress: CGFloat {
        guard limit > 0 else { return 0 }
        return min(1, CGFloat(count) / CGFloat(limit))
    }

    private var tint: Color {
        if over { return .red }
        if nearingEnd { return .orange }
        return theme.accentColor
    }

    /// Grows once the count matters, so the number is readable exactly when
    /// the writer starts caring about it.
    private var diameter: CGFloat { nearingEnd || over ? 30 : 22 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(theme.textColor.opacity(0.15), lineWidth: 2)
            Circle()
                .trim(from: 0, to: over ? 1 : progress)
                .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))

            // Only ever the remaining count — a writer near the cap needs to
            // know how much is left, not how much they have used.
            if nearingEnd || over {
                Text("\(remaining)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
            }
        }
        .frame(width: diameter, height: diameter)
        .animation(.easeOut(duration: 0.15), value: diameter)
    }
}

// MARK: - Media card

/**
 A media block inside the document.

 Deliberately NOT editable text: it renders the block and its pending upload
 state. Mirrors the Android MediaCard.
 */
/// Decode an image for a media card.
///
/// Handles a local file (what the picker/cropper hands us) and an http(s) URL
/// Does this path look like a video rather than a still?
func isVideoSource(_ source: String) -> Bool {
    let lower = source.lowercased()

    return ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains { lower.hasSuffix("." + $0) }
}

/// The first watchable frame of a video, for its card and its thumbnail.
///
/// Taken a little way in rather than at zero: many recordings open on a black
/// or half-exposed frame, which makes the card look broken.
func videoPoster(_ source: String, maxPixels: Int) -> UIImage? {
    let url = source.lowercased().hasPrefix("http")
        ? URL(string: source)
        : URL(fileURLWithPath: source.replacingOccurrences(of: "file://", with: ""))

    guard let url else { return nil }

    let generator = AVAssetImageGenerator(asset: AVAsset(url: url))
    generator.appliesPreferredTrackTransform = true   // honour the recording's rotation
    generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)

    let at = CMTime(seconds: 0.5, preferredTimescale: 600)

    guard let cg = try? generator.copyCGImage(at: at, actualTime: nil) else { return nil }

    return UIImage(cgImage: cg)
}

/// (what a re-opened, already-uploaded document contains). Downsampled so a
/// full-resolution camera photo cannot blow up memory in a scrolling document.
/// Hand-rolled rather than pulling in an image library — the plugin stays
/// dependency-free, like the rest of it.
func decodeMediaImage(_ source: String, maxPixels: Int = 1200) -> UIImage? {
    // A video is not an image file — CGImageSource cannot read one, so without
    // this a video card shows a grey placeholder instead of what it contains.
    // AVFoundation is already linked for playback, so the frame is free.
    if isVideoSource(source) { return videoPoster(source, maxPixels: maxPixels) }

    let url: URL?
    if source.lowercased().hasPrefix("http://") || source.lowercased().hasPrefix("https://") {
        url = URL(string: source)
    } else {
        url = URL(fileURLWithPath: source.replacingOccurrences(of: "file://", with: ""))
    }
    guard let url, let data = try? Data(contentsOf: url) else { return nil }

    guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return UIImage(data: data) }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,   // bake EXIF orientation
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
        return UIImage(data: data)
    }
    return UIImage(cgImage: cg)
}

/// Which toolbar glyph stands in for a block on its card. Normative — the
/// Android card uses the same mapping, so a document looks the same on both.
func cardIconKey(_ type: String) -> String {
    switch type {
    case "image": return "image"
    case "video": return "video"
    case "file": return "file"
    case "embed": return "link"
    case "poll": return "poll"
    default: return "bulletList"
    }
}

private struct MediaCardView: View {
    let block: WysiwygBlock
    let theme: WysiwygTheme
    var strings: [String: String] = [:]

    @State private var image: UIImage?

    /// Prefer the public url; fall back to the local file so a freshly picked
    /// image shows immediately, before any upload finishes.
    private var source: String {
        if block.type == "video", let poster = block.attrs["poster"], !poster.isEmpty { return poster }
        // The plugin fetches nothing; a thumbnail is here only because the host
        // put it here.
        if block.type == "embed" { return block.attrs["thumbnail"] ?? "" }
        if let src = block.attrs["src"], !src.isEmpty { return src }
        return block.attrs["localPath"] ?? ""
    }

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
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                HStack(spacing: 10) {
                    IconShape(data: toolIcons[cardIconKey(block.type)]?.path ?? "")
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

                if block.type == "embed" {
                    let provider = block.attrs["provider"] ?? embedProvider(block.attrs["url"] ?? "")
                    if !provider.isEmpty {
                        Text(provider)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(theme.accentColor)
                    }
                }

                if let caption = block.attrs["caption"], !caption.isEmpty {
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundColor(theme.textColor.opacity(0.6))
                }

                if pending {
                    Text(localized(strings, "uploading", "Uploading…"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(theme.textColor.opacity(0.06)))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .task(id: source) {
                guard !source.isEmpty,
                      ["image", "video", "embed"].contains(block.type) else { return }
                let decoded = await Task.detached(priority: .userInitiated) {
                    decodeMediaImage(source)
                }.value
                image = decoded
            }
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
    // Plain body text — offered in the Format sheet as the way BACK from a
    // heading, so it needs a glyph like every other row.
    "p": ToolIcon(path: "M4 6L20 6M4 12L20 12M4 18L14 18"),
    "poll": ToolIcon(path: "M6 19L6 11M12 19L12 5M18 19L18 14"),
    "divider": ToolIcon(path: "M4 12L20 12"),
    "embed": ToolIcon(path: "M4 6L20 6L20 18L4 18ZM10 10L14 12L10 14Z"),
    "link": ToolIcon(path: "M9.5 12L14.5 12"
        + "M10 8L7.5 8C5.3 8 3.5 9.8 3.5 12C3.5 14.2 5.3 16 7.5 16L10 16"
        + "M14 8L16.5 8C18.7 8 20.5 9.8 20.5 12C20.5 14.2 18.7 16 16.5 16L14 16"),
    "code": ToolIcon(path: "M9 8L4.5 12L9 16M15 8L19.5 12L15 16"),
    "textColor": ToolIcon(path: "M5 15L10 5L15 15M6.8 11.6L13.2 11.6M4 19.5L20 19.5"),
    "highlight": ToolIcon(path: "M15 4L20 9L10 19L5 19L5 14L15 4M13 6L18 11"),
    "clearFormat": ToolIcon(path: "M5 15L10 5L15 15M6.8 11.6L13.2 11.6M4 4L20 20"),
    // Insert tools: a framed picture, a play triangle, a paperclip.
    "camera": ToolIcon(path: "M4 8L7 8L9 5L15 5L17 8L20 8L20 19L4 19ZM12 15.5C13.4 15.5 14.5 14.4 14.5 13C14.5 11.6 13.4 10.5 12 10.5C10.6 10.5 9.5 11.6 9.5 13C9.5 14.4 10.6 15.5 12 15.5Z"),
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

// MARK: - Tool metadata

/**
 Which string key labels each tool in a bottom sheet.

 Mirrors `WysiwygEditor::TOOL_LABEL_KEYS` in PHP and the Kotlin table of the
 same name — headings and quote read as text STYLES, so they take the `style*`
 keys and sit in their own section.
 */
let toolLabelKeys: [String: String] = [
    "bold": "toolBold",
    "italic": "toolItalic",
    "underline": "toolUnderline",
    "strikethrough": "toolStrikethrough",
    "h1": "styleH1",
    "h2": "styleH2",
    "h3": "styleH3",
    "bulletList": "toolBulletList",
    "orderedList": "toolOrderedList",
    "blockquote": "styleQuote",
    "link": "toolLink",
    "code": "toolCode",
    "textColor": "toolTextColor",
    "highlight": "toolHighlight",
    "image": "toolImage",
    "camera": "toolCamera",
    "video": "toolVideo",
    "file": "toolFile",
    "poll": "toolPoll",
    "divider": "toolDivider",
    "embed": "toolEmbed",
    "clearFormat": "toolClearFormat",
]

/// Sheet sections, in display order. Normative — Kotlin uses the same lists.
let sheetTextStyleTools = ["h1", "h2", "h3", "blockquote"]
let sheetListTools = ["bulletList", "orderedList"]
let sheetFormatTools = ["bold", "italic", "underline", "strikethrough",
                        "code", "textColor", "highlight", "clearFormat"]
let sheetInsertTools = ["image", "camera", "video", "file", "poll", "embed", "divider", "link"]

/// Which sheet, if any, is open.
enum SheetKind: Identifiable {
    case format, insert
    var id: Int { self == .format ? 0 : 1 }
}

/// Whether `tool` is currently in effect. Shared by the toolbar and the
/// sheets, so a tool cannot look active in one and inactive in the other.
private func isActive(_ tool: String, model: WysiwygEditorModel, palette: PaletteKind?) -> Bool {
    switch tool {
    case "bold": return model.activeMarks.bold
    case "italic": return model.activeMarks.italic
    case "underline": return model.activeMarks.underline
    case "strikethrough": return model.activeMarks.strike
    case "code": return model.activeMarks.code
    case "link": return model.activeMarks.link != nil
    case "textColor": return model.activeMarks.color != nil || palette == .text
    case "highlight": return model.activeMarks.highlight != nil || palette == .highlight
    case "h1", "h2", "h3", "blockquote": return model.activeBlock == tool
    case "bulletList": return model.activeBlock == "ul"
    case "orderedList": return model.activeBlock == "ol"
    case "p": return !["h1", "h2", "h3", "ul", "ol", "blockquote"].contains(model.activeBlock)
    default: return false
    }
}

// MARK: - Formatting toolbar

private struct ToolbarRow: View {
    @ObservedObject var model: WysiwygEditorModel
    @Binding var palette: PaletteKind?
    @Binding var sheet: SheetKind?
    /// Tools that act on the whole document rather than on this segment.
    /// Without this the toolbar silently did nothing for them, because it only
    /// ever had a reference to one text model.
    var onDocumentTool: (String) -> Void = { _ in }
    /// Live count, when it is drawn as a ring. A ring is a compact indicator
    /// meant to sit at the end of a bar — which is where every composer that
    /// has one puts it — so it rides along here rather than taking a row.
    var ringCount: Int?
    var ringLimit: Int = 0

    private var theme: WysiwygTheme { model.config.theme }

    /// Compact bar + sheets, or one scrolling bar with everything on it.
    private var sheetMode: Bool { model.config.menu == "sheet" }

    var body: some View {
        HStack(spacing: 0) {
            tools
            if let ringCount {
                CountRing(count: ringCount, limit: ringLimit, theme: theme)
                    .padding(.trailing, 14)
                    .padding(.leading, 6)
            }
        }
        .background(theme.backgroundColor.overlay(theme.textColor.opacity(0.04)))
        .overlay(Rectangle().fill(theme.textColor.opacity(0.12)).frame(height: 0.5), alignment: .top)
    }

    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                // Undo / redo lead the configured tools, unless turned off.
                if model.config.history {
                    button("undo", active: false, enabled: model.canUndo) { model.undo() }
                    button("redo", active: false, enabled: model.canRedo) { model.redo() }
                    if !model.config.toolbar.isEmpty {
                        Rectangle()
                            .fill(theme.textColor.opacity(0.15))
                            .frame(width: 1, height: 22)
                            .padding(.horizontal, 6)
                    }
                }

                if sheetMode {
                    compactTools
                } else {
                    ForEach(model.config.toolbar, id: \.self) { tool in
                        toolButton(tool)
                    }
                }

                // The host's own buttons, after its tools.
                ForEach(model.config.customTools) { tool in
                    button(tool.icon, active: false) { onDocumentTool("custom:" + tool.id) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    /// Sheet mode: the two or three marks people reach for constantly stay one
    /// tap away; everything else is behind Format / Insert rather than off the
    /// right edge of a scrolling bar.
    @ViewBuilder
    private var compactTools: some View {
        ForEach(model.config.toolbar.filter { ["bold", "italic"].contains($0) }, id: \.self) { tool in
            toolButton(tool)
        }

        if model.config.toolbar.contains(where: { formatSheetTools.contains($0) }) {
            labelledButton("textColor", localized(model.config.strings, "menuFormat", "Format"),
                           active: sheet == .format) {
                sheet = sheet == .format ? nil : .format
            }
        }
        if model.config.toolbar.contains(where: { sheetInsertTools.contains($0) }) {
            labelledButton("image", localized(model.config.strings, "menuInsert", "Insert"),
                           active: sheet == .insert) {
                sheet = sheet == .insert ? nil : .insert
            }
        }
    }

    /// Every tool the Format sheet can offer, in section order.
    private var formatSheetTools: [String] {
        sheetTextStyleTools + sheetListTools + sheetFormatTools
    }

    @ViewBuilder
    private func toolButton(_ tool: String) -> some View {
        button(tool, active: isActive(tool, model: model, palette: palette),
               enabled: true) {
            perform(tool)
        }
    }

    /// Run a tool. Shared by the toolbar and both sheets so a tool cannot
    /// behave differently depending on where it was tapped from.
    private func perform(_ tool: String) {
        switch tool {
        case "bold", "italic", "underline", "strikethrough", "code":
            model.toggleInline(tool)
        case "h1", "h2", "h3", "bulletList", "orderedList", "blockquote":
            model.applyBlock(tool)
        case "p":
            model.applyBlock("p")
        case "link":
            model.linkTapped()
        case "textColor":
            palette = palette == .text ? nil : .text
        case "highlight":
            palette = palette == .highlight ? nil : .highlight
        case "clearFormat":
            model.clearFormat()
        case "image", "camera", "video", "file":
            requestMedia(tool)
        case let tool where tool.hasPrefix("custom:"):
            // Nothing for the editor to do — say who was tapped and stop.
            onDocumentTool(tool)
        case "poll", "divider", "embed":
            // These change the DOCUMENT, not this segment's text, so the
            // screen handles them — the toolbar only knows about one editor.
            onDocumentTool(tool)
        default:
            break
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

    /// A toggle you cannot see the result of (bold with no selection) should
    /// still feel like it happened.
    private func tap(_ action: @escaping () -> Void) -> () -> Void {
        {
            if model.config.haptics {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            action()
        }
    }

    /// A wider button carrying a glyph AND a word — used for Format / Insert,
    /// where an icon alone would not say which sheet opens.
    private func labelledButton(_ icon: String, _ label: String, active: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: tap(action)) {
            HStack(spacing: 6) {
                IconShape(data: toolIcons[icon]?.path ?? "")
                    .stroke(style: StrokeStyle(lineWidth: 2 * 18 / 24, lineCap: .round, lineJoin: .round))
                    .frame(width: 18, height: 18)
                Text(label).font(.system(size: 15, weight: .medium))
            }
            .foregroundColor(active ? theme.highlightColor : theme.textColor.opacity(0.78))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(active ? theme.highlightColor.opacity(0.16) : Color.clear))
        }
    }

    private func button(_ tool: String, active: Bool, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        let icon = toolIcons[tool] ?? ToolIcon(path: "")
        let glyph: CGFloat = 21

        return Button(action: tap(action)) {
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

// MARK: - Bottom sheets

/// The tick drawn beside an active row. Same 24x24 grid as the tool glyphs,
/// and the same path string on Android.
let checkIconPath = "M5 13L9 17L19 7"

/**
 A hand-rolled bottom sheet: scrim plus a panel anchored to the bottom.

 Deliberately not SwiftUI's `.sheet` + `presentationDetents`, which is iOS 16+
 and would put this feature behind a version nothing else here needs. Hand
 rolling also means the panel is directly comparable with Android's, which is
 the whole point.
 */
private struct WysiwygSheet<Content: View>: View {
    let theme: WysiwygTheme
    let title: String
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content

    /// A ScrollView takes every point it is offered, so a four-row Insert
    /// sheet would stand as tall as a sixteen-row Format one. Measure the
    /// content and ask for exactly that, capped. Android's Column already
    /// sizes to content, so this is what keeps the two the same shape.
    @State private var contentHeight: CGFloat = 0

    private var maxSheetHeight: CGFloat { UIScreen.main.bounds.height * 0.6 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                Capsule()
                    .fill(theme.textColor.opacity(0.25))
                    .frame(width: 36, height: 4)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(theme.textColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)

                ScrollView {
                    content()
                        .padding(.bottom, 24)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: SheetContentHeightKey.self,
                                                   value: proxy.size.height)
                        })
                }
                .frame(height: contentHeight == 0 ? maxSheetHeight
                                                  : min(contentHeight, maxSheetHeight))
                .onPreferenceChange(SheetContentHeightKey.self) { contentHeight = $0 }
            }
            .background(theme.backgroundColor)
            .clipShape(TopRoundedCorners(radius: 18))
            .shadow(color: .black.opacity(0.2), radius: 20, y: -4)
        }
    }
}

/// Carries the measured height of a sheet's content up to the panel.
private struct SheetContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Rounding only the TOP corners — `cornerRadius` would round all four.
private struct TopRoundedCorners: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(UIBezierPath(roundedRect: rect,
                          byRoundingCorners: [.topLeft, .topRight],
                          cornerRadii: CGSize(width: radius, height: radius)).cgPath)
    }
}

/// A full-width row: glyph, label, and a tick when the tool is in effect.
private struct SheetRow: View {
    let tool: String
    let label: String
    let active: Bool
    let theme: WysiwygTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconShape(data: toolIcons[tool]?.path ?? "")
                    .stroke(style: StrokeStyle(lineWidth: 2 * 20 / 24, lineCap: .round, lineJoin: .round))
                    .foregroundColor(active ? theme.highlightColor : theme.textColor.opacity(0.75))
                    .frame(width: 20, height: 20)
                Text(label)
                    .font(.system(size: 16))
                    .foregroundColor(theme.textColor)
                Spacer()
                if active {
                    IconShape(data: checkIconPath)
                        .stroke(style: StrokeStyle(lineWidth: 2 * 18 / 24, lineCap: .round, lineJoin: .round))
                        .foregroundColor(theme.highlightColor)
                        .frame(width: 18, height: 18)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 48)
            .contentShape(Rectangle())
            .background(active ? theme.highlightColor.opacity(0.10) : Color.clear)
        }
    }
}

/// Section heading inside a sheet.
private struct SheetSection: View {
    let title: String
    let theme: WysiwygTheme

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(theme.textColor.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 4)
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

// MARK: - Media preview

/**
 Full-screen viewer for one media block.

 Its own window for the same reason the editor has one: presenting on the
 host's root controller loses to whatever that controller is already showing,
 silently. Video goes to AVPlayer, which brings its own chrome and its own
 full-screen behaviour, so only images need a shell built for them.
 */
enum WysiwygMediaPreview {
    private static var window: UIWindow?
    private static weak var previousKeyWindow: UIWindow?

    static func present(kind: String, source: String, caption: String) {
        guard let scene = WysiwygEditorPresenter.activeScene() else { return }

        let url = source.hasPrefix("http") ? URL(string: source)
                                           : URL(fileURLWithPath: source)

        guard let url else { return }

        if kind == "video" {
            let player = AVPlayerViewController()
            player.player = AVPlayer(url: url)
            show(player, in: scene) { player.player?.play() }

            return
        }

        let image = decodeMediaImage(source, maxPixels: 2400)
        show(ImagePreviewController(image: image, caption: caption), in: scene)
    }

    private static func show(_ controller: UIViewController, in scene: UIWindowScene,
                             then: (() -> Void)? = nil) {
        // Only one at a time; a second tap should not stack viewers.
        dismiss()

        previousKeyWindow = scene.windows.first { $0.isKeyWindow }

        let host = UIWindow(windowScene: scene)
        host.rootViewController = controller
        host.windowLevel = .normal + 2
        host.backgroundColor = .black
        host.makeKeyAndVisible()
        window = host

        then?()
    }

    static func dismiss() {
        previousKeyWindow?.makeKey()
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }
}

/// The image shell: black backdrop, pinch to zoom, a close button, and the
/// caption if there is one — what every timeline does when you tap a photo.
private final class ImagePreviewController: UIViewController, UIScrollViewDelegate {
    private let image: UIImage?
    private let caption: String
    private let scrollView = UIScrollView()
    private let imageView = UIImageView()

    init(image: UIImage?, caption: String) {
        self.image = image
        self.caption = caption
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        view.addSubview(scrollView)

        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        // Double tap to zoom, the gesture every photo viewer has.
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        if !caption.isEmpty {
            let label = UILabel()
            label.text = caption
            label.textColor = .white
            label.font = .systemFont(ofSize: 14)
            label.numberOfLines = 3
            label.textAlignment = .center
            label.frame = CGRect(x: 20, y: view.bounds.height - 90,
                                 width: view.bounds.width - 40, height: 54)
            label.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
            view.addSubview(label)
        }

        let close = UIButton(type: .system)
        close.setTitle("✕", for: .normal)
        close.titleLabel?.font = .systemFont(ofSize: 24, weight: .medium)
        close.tintColor = .white
        close.setTitleColor(.white, for: .normal)
        close.frame = CGRect(x: 12, y: 52, width: 44, height: 44)
        close.addTarget(self, action: #selector(close(_:)), for: .touchUpInside)
        view.addSubview(close)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    @objc private func toggleZoom(_ sender: UITapGestureRecognizer) {
        scrollView.setZoomScale(scrollView.zoomScale > 1 ? 1 : 2.5, animated: true)
    }

    @objc private func close(_ sender: UIButton) {
        WysiwygMediaPreview.dismiss()
    }
}

// MARK: - Presenter

/**
 Presents the editor in its OWN key window rather than as a modal on the host
 app's root controller.

 This is not a cosmetic choice. Marketplace plugins — the camera/photo picker
 among them — present their UI on `keyWindow.rootViewController`. If the editor
 were a modal on that controller, that controller is already presenting, iOS
 refuses silently, and picking an image from inside the editor does nothing.

 Giving the editor its own key window makes IT the root controller those
 plugins find, so their existing lookup presents the picker on top of the
 editor with no change needed on their side. It also mirrors Android, where the
 editor is an overlay on the activity's content view rather than a second
 Activity.
 */
final class WysiwygEditorPresenter {
    static let shared = WysiwygEditorPresenter()
    private var hosting: UIHostingController<AnyView>?
    private var window: UIWindow?
    /// Restored as key when the editor closes, so the host app gets input back.
    private weak var previousKeyWindow: UIWindow?
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
        document.onContentChanged = { [weak self] html, text, json in
            self?.send(
                WysiwygEvents.changed,
                ["html": html, "text": text, "json": json, "id": config.id]
            )
        }
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.modalPresentationStyle = .fullScreen
        host.view.backgroundColor = config.theme.backgroundUIColor
        host.rootView = AnyView(EditorScreen(
            document: document,
            onCancel: { [weak self] in
                self?.finish(WysiwygEvents.cancelled, ["id": config.id])
            },
            onSave: { [weak self] html, text, json in
                self?.finish(
                    WysiwygEvents.saved,
                    ["html": html, "text": text, "json": json, "id": config.id]
                )
            }
        ))
        hosting = host

        guard let scene = Self.activeScene() else {
            finish(WysiwygEvents.cancelled, ["id": config.id])
            return
        }

        previousKeyWindow = scene.windows.first { $0.isKeyWindow }

        let editorWindow = UIWindow(windowScene: scene)
        editorWindow.rootViewController = host
        // Above the app, below system UI such as the status bar and alerts.
        editorWindow.windowLevel = .normal + 1
        editorWindow.backgroundColor = config.theme.backgroundUIColor
        editorWindow.makeKeyAndVisible()
        window = editorWindow

        // Match the slide-up a full-screen modal would have given us.
        editorWindow.frame = scene.coordinateSpace.bounds
        host.view.transform = CGAffineTransform(translationX: 0, y: editorWindow.bounds.height)
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseOut) {
            host.view.transform = .identity
        }
    }

    private func dismiss() {
        guard let editorWindow = window else {
            hosting = nil
            return
        }
        hosting = nil
        window = nil

        // Hand input back to the app BEFORE the animation, so the keyboard
        // does not linger over a window that is on its way out.
        previousKeyWindow?.makeKey()

        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn) {
            editorWindow.rootViewController?.view.transform =
                CGAffineTransform(translationX: 0, y: editorWindow.bounds.height)
        } completion: { _ in
            editorWindow.isHidden = true
            editorWindow.rootViewController = nil
        }
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

    static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Topmost controller — used for the link dialog. Walks the presentation
    /// chain so an alert lands above anything already showing.
    static func topController() -> UIViewController? {
        var top = activeScene()?.windows.first { $0.isKeyWindow }?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
