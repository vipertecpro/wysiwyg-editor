# Changelog

All notable changes to `vipertecpro/wysiwyg-editor` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-07-29

### Added

- Full-screen native rich text editor opened with
  `WysiwygEditor::open(string $html, array $options)`.
- Inline marks: bold, italic, underline, strikethrough, inline code, links,
  text color and highlight.
- Blocks: paragraph, H1–H3, bullet list, ordered list, blockquote.
- Configurable toolbar via `toolbar` or the `full` / `basic` / `comment` /
  `note` presets, plus `title`, `placeholder`, `maxLength` and `id` options.
- Host-app theming through `theme` (`background`, `text`, `accent`,
  `highlight`); omitted keys keep the system-adaptive light/dark defaults.
- `ContentSaved` (HTML + plain text) and `EditCancelled` result events.
- A normative HTML contract implemented by a hand-written parser/serializer, so
  documents round-trip identically on both platforms.
- iOS implementation (SwiftUI + UITextView) with undo/redo, link and color
  dialogs, live character counter and a discard-changes confirm.
- Android implementation (Compose + EditText/Spannable) mirroring iOS feature
  for feature: the same marks and blocks, list markers with live renumbering,
  Enter continuing or exiting a list, undo/redo, link and color dialogs, live
  character counter and a discard-changes confirm.
- A shared toolbar icon set — hand-drawn 24×24 vector paths defined once and
  drawn with each platform's vector API, so the two toolbars are identical
  rather than "SF Symbols on one side, Material on the other".
- Cross-platform parity harnesses (`tests/native/ios`, `tests/native/android`)
  that run the SAME case list through each platform's real coder and assert
  byte-identical HTML, plain text and idempotence.

- Segment editing shell on BOTH platforms: consecutive text blocks share one
  editor (the v1 engine, unchanged) and media blocks render as cards between
  them, so images, dividers, embeds and polls sit inline with the prose.

- Media insertion: `image` / `video` / `file` toolbar tools, a `MediaRequested`
  event and `insertMedia()` / `uploadProgress()` / `uploadCompleted()` /
  `uploadFailed()`. The editor ships no picker and no uploader — the host
  answers with whatever it already uses.
- Media cards render REAL images, decoded from a local file or an http(s) URL
  and downsampled, on both platforms. No image library — the plugin stays
  dependency-free.

### Added — since the first cut

- **Bottom-sheet menus** (`menu => 'sheet'`): a compact bar with Format and
  Insert sheets instead of one bar that scrolls tools off the screen.
- **Polls**, edited inline: an answer per row with its own picture button, an
  option cap shown as an overrun, Add option, and how long the poll runs.
  Durations are recorded in MINUTES — the editor owns no clock.
- **Embeds** with provider recognised from the URL alone, and dividers.
- **Typography and spacing**: the host application's font is adopted
  automatically; `typography` sets the base size and the heading ramp scales
  from it; `spacing` is stated in points on iOS and dp on Android.
- **Localization** of every user-visible string, with `{n}` / `{max}` / `{type}`
  placeholders substituted natively so the translation controls word order.
- **Validation** (`minWords`, `maxWords`, `requiredBlocks`, `maxImages`),
  checked natively so a failing document never round-trips to PHP.
- **Counts** (`characters`, `words`, `readingTime`) and haptics.
- **Auto-save seam**: a `ContentChanged` event debounced by `changeDebounce`.
- **Markdown export** (`toMarkdown()`), derived from the canonical JSON rather
  than the HTML, so it inherits no loss that already happened.
- **`open()` accepts the document JSON as well as HTML**, so a document
  re-opens with the local file paths that HTML can never carry.
- **Host accessory rows** (`accessories`): the application puts its own
  controls in the composer, gets `AccessoryTapped`, and updates them with
  `setAccessory()` without closing the editor.
- **Media strip** (`mediaLayout => 'strip'`) with per-thumbnail remove,
  description and edit, an attachment cap (`maxMedia`, default 4), and a
  `MediaEditRequested` event handing editing back to the host's own picker.
- **Full-screen media viewer** (`preview()`) — zoomable images and video
  playback, because the platform ships no video element to build one from.
- Composer controls: `countStyle => 'ring'`, `maxLengthMode => 'soft'` with the
  overrun shaded, `saveStyle => 'filled'`, `history => false`, and
  `toolbar => []` meaning no toolbar at all.

### Known limitations

- The list immediately above is **iOS-only** so far. Android accepts the
  options and ignores them. See the platform table in the README; the shared
  document model, HTML/JSON contract and parity harness cover both.
- Inline video autoplay in a host timeline is not possible — NativePHP has no
  video element.
- Markdown drops underline, colour and highlight, which it cannot spell.

### Fixed — since the first cut

- **iOS: long lines never wrapped.** A non-scrolling `UITextView` reports an
  intrinsic width as wide as its longest line, and SwiftUI sized the whole
  editor to it, pushing the top bar and toolbar off screen. Every test string
  until then had happened to fit on one line.
- **`poll`, `divider` and `embed` did nothing from the toolbar** on both
  platforms: the dispatchers had no branch for them, so the buttons were dead
  and silent. A test now insists every offered tool is handled.
- **Two events could never be constructed** — they extended a base class that
  does not exist. `#[On(Event::class)]` does not autoload, so the listener
  registered and the failure only surfaced, silently, at dispatch.
- Backspacing at the start of a text segment now deletes the media card above
  it and merges the runs either side.
- Media cards drew a bullet-list glyph whatever they held; text segments below
  a card repeated the placeholder.

### Fixed

- iOS: the text engine ignored the host theme. Only the SwiftUI chrome adopted
  the app's colours, so the caret, link colour, document text and background
  stayed on the plugin's defaults while the Save button went teal. All four
  UIKit colour accessors now consult the host palette like their SwiftUI
  counterparts.

Found by running the editor on a real simulator and emulator:

- Android: the editor did not take focus when it opened, so the keyboard stayed
  down and the first keystrokes were dropped. It now focuses and raises the IME
  once the overlay is attached, matching iOS.
- Android: a block applied to an EMPTY paragraph left the text you typed
  afterwards rendering at body size while still serializing as a heading. Block
  presentation is now rebuilt after every change, so what you see matches what
  you get.
- Android: every block except the last lost its type on save — a document typed
  as heading + list came back as `<p>` + `<p>` + `<ul>`. Creating a paragraph
  stripped the preceding paragraph's block span, because block spans extend
  over their terminating newline and the strip ran at that exact offset. Span
  ownership is now checked before removal.
- Android: backspacing at the start of a list item nibbled a single character
  out of the marker, leaving a stray "•" on a paragraph that was still a list
  item. The marker is now deleted as one unit and the item demoted to a
  paragraph, intercepting both the DEL key and the soft keyboard's
  `deleteSurroundingText`.
- Android: a mark toggled with no selection applied to a single character
  instead of the word being typed. Armed marks now persist for text typed
  contiguously and are dropped when the caret moves elsewhere.
- Android: the editor did not regain focus after the link dialog or a colour
  swatch, so the armed formatting was lost as soon as the user tapped back in.
- Android: the link tool with no selection ARMED a link, while iOS INSERTED
  the URL as its own linked text — the same action produced different
  documents per platform. Android now matches iOS. The dialog wording was
  aligned too ("Add Link" / Cancel / Save on both).
