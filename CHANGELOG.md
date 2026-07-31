# Changelog

All notable changes to `vipertecpro/wysiwyg-editor` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.8.0] - 2026-07-31

### Added

- **Tables.** A grid of plain-text cells with an optional header row, inserted
  with the `table` tool and edited where it sits — a row of small fields with
  controls to grow or shrink it. It saves as a real `<table>`, so anything
  rendering your stored markup gets a table rather than an opaque blob, and in
  JSON the cells are a plain 2-D array. Cells hold text and not marks: a cell
  on a phone is a word or two, and carrying bold and links into every one of
  them would multiply the coders for something the layout has no room to show.
  Sized by `tableDefaultRows` / `tableDefaultColumns` and bounded by
  `tableMinRows` / `tableMaxRows` / `tableMinColumns` / `tableMaxColumns`.

### Fixed

- **A document could not be written past its last card.** A table, a picture or
  a divider as the final block left nowhere to put the caret, so anything typed
  after inserting one went nowhere at all. The editor now keeps a paragraph
  below the last card, and drops it again on the way out — along with the blank
  line a card inserted from an empty line leaves above itself. Both are editing
  affordances rather than content, and neither reaches your payload; a blank
  line BETWEEN two paragraphs is content and survives.
- **The editor drew its own colours over an application that had a palette.**
  NativeUI renamed its namespace for NativePHP 4.0, and every lookup of it here
  is guarded by `class_exists` — so the rename read as "no theme installed"
  rather than raising anything, and a blue application opened an orange editor.
  Both names are recognised now.
- **Checklist ticks were lost on save on Android.** The coder was never at
  fault; the reader that turns the live editor buffer back into blocks read the
  block type and never asked about the tick, so every box saved unticked
  however the page looked when you left it.
- **`/table` did nothing.** Slash commands run through a dispatcher of their
  own, and it did not name the tool — so the typed text was consumed and no
  table appeared.

## [0.7.0] - 2026-07-30

### Added

- **`saveStyle => 'none'`** — no Save button at all, for an editor that saves
  as you type. Pair it with `changeDebounce`: with the app already persisting,
  a second button that also saves is a lie about what the first one did. The
  close control commits on the way out so the last keystrokes inside the
  debounce window are not lost, and takes its label from `strings.save`,
  because a button that saves must not say "Cancel".
- **Test assertions for apps using the editor.** NativePHP 4.0 lets a plugin
  teach its own vocabulary to the FakeBridge, so a test of YOUR screen can say
  `assertEditorOpened()` instead of knowing that opening an editor means a
  `WysiwygEditor.Open` call carrying JSON. Eight assertions, registered only
  while an app runs its tests, absent below 4.0.0 at no cost. See
  [Testing your integration](README.md#testing-your-integration).

### Changed

- Verified against **NativePHP 4.0.0** on both platforms, and passes
  `php artisan native:plugin:validate`. Apps on 4.x need one line in
  `config/view.php` before the build will boot — see the note under
  Requirements. It is not this plugin's doing, but it is the first thing you
  will hit.

## [0.6.0] - 2026-07-30

### Added

- **Checklists.** A third list type whose items carry a state: tap the box to
  tick it, and the tick survives the save. The markup is a `<ul data-checklist>`
  with `data-checked` on each item, so anything rendering it without knowing
  about checklists still gets a list rather than nothing — and a plain `<ul>`
  from elsewhere stays bullets. Added to `AVAILABLE_TOOLS` and the `note`
  preset as `checklist`.
- **Slash commands.** A suggestion row may now name a `tool`. Picking it
  deletes the trigger and everything typed after it — `/h1` is an instruction,
  not text you meant to keep — and runs the tool on that line. Mentions are
  unchanged: one pipeline, and whether a pick writes a name or changes the
  block is a property of the row. A tool the editor does not own arrives as
  {@see Events\ToolTapped} rather than being guessed at.
- **`WysiwygEditor::insertText()`** — write at the caret, as if the user had
  typed it. What a host command needs to finish the job: `/date` comes back as
  `ToolTapped` with the trigger already removed, and the app puts something
  there. Inherits the formatting at the caret and lands in the undo stack.
- A suggestion row also takes an `icon`, so a command has a glyph where a
  person has a face.

### Fixed

- A tool named in only ONE of the two iOS dispatchers did nothing when tapped
  while passing every parity check — the toolbar calls one and delegates
  document-wide tools to the other. The guard now demands every tool in every
  dispatcher.
- The iOS list normaliser derived a paragraph's "correct" marker from its block
  type and rewrote anything else, which erased a checklist's box the instant it
  was drawn. A checklist's marker IS its state and cannot be derived from the
  type.

### Internal

- Two tests read both native sources and fail if either never reads a config
  option, top-level or nested — the drift that made `avatarPlacement` draw an
  avatar twice on Android. The nested one demands a bracket READ, because
  several key names double as tool names and mere presence proved nothing.
- The suite now stubs the native bridge and records what the editor SENDS.
  `suggestions()` had no coverage at all before: off-device it returned early.

## [0.5.0] - 2026-07-30

### Added

- **Mentions and hashtags.** The editor watches for a trigger character and
  reports what follows it through `SuggestionRequested`; the host answers with
  `suggestions()`. Picking one writes a **link** carrying the entity id, not
  styled text — so the saved document says which person was named, and survives
  back into an edit. `triggers` is configurable and `false` turns it off.
- **Host sheets.** The editor owns its own window, so a sheet the host drew
  would open behind it. `sheets` declares the options — as a `list` with a tick
  or a `grid` of tiles — the editor presents them, and `SheetOptionPicked`
  reports the choice. An accessory or a custom tool names one with `sheet`.
- **`WysiwygEditor::insertTool()`** — run one of the editor's own tools from
  outside the toolbar, for a composer whose toolbar is a host sheet. Without it
  the host could offer a tool it had no way to trigger.
- **`WysiwygEditor::attachments()`** — the files a document carries, pulled out
  of the saved JSON. Most servers want the prose in one table and the files in
  another; the editor uploads nothing, so this is the split. Exactly one of
  `path` and `url` is filled, so which to do next is unambiguous.
- **Post backgrounds.** A few words held large and centred on a colour, the way
  a social composer does it. `backgrounds` declares them — the editor ships no
  palette, because that is a brand decision — and the choice round-trips in the
  markup and the JSON both. Dropped past `backgroundMaxLength`, and never
  offered alongside media.
- **Accessory `placement` and `style`.** A control can sit in the header beside
  Close and Save rather than in a row under the media, drawn as a `chip` or a
  bare `icon`. An icon control shows its `value` once it has one, so a schedule
  button can say *when*.
- **`toolbarAlign`** — park a short bar in the corner instead of at the leading
  edge. **`avatarPlacement`** — `text`, `header` or `none`.
- Host-facing glyphs for an app's own controls: `clock`, `plus`, `globe`,
  `people`, `calendar`, `briefcase`, `star`, `document`, `chevronDown`.

### Changed

- **A cap no longer conjures a counter.** `counts` decides what the writer is
  told; `maxLength` decides when Save refuses. A composer can have a 3000
  character allowance and show nothing. **If you relied on `maxLength` alone to
  draw an `n/limit` readout, add `'counts' => ['characters']`.**

### Fixed

- Two glyphs were drawn with SVG arcs, which neither path parser implements — a
  clock face rendered as a stray stroke. Rewritten as cubics, with a test that
  refuses anything but `M`, `L`, `C` and `Z`.
- A host sheet opened under the keyboard: Android kept the IME up, and so did
  iOS once the editor had taken focus.
- Android drew the avatar twice when it was placed in the header, and held a
  post written on a colour at the top of the card where iOS centred it.
- The iOS parity harness sliced out a region that no longer compiled, ran
  nothing, and reported success. Both runners now count the checks that
  executed and refuse anything under sixty.

## [0.4.0] - 2026-07-30

### Added

- **`customTools`** — extra toolbar buttons the host defines, emitting
  `ToolTapped`. The editor cannot know what a GIF picker or a scheduler should
  do; it draws the button and reports the tap. Drawn with the editor's own
  glyphs, so they match on both platforms.
- **`camera`** as a first-class insert tool, separate from `image`: a photo you
  TAKE and a photo you PICK are different screens.
- **`avatar`** — the author's picture beside the compose field, decoded the
  same way media is so a local path works as well as a url.

## [0.3.0] - 2026-07-29

### Added

- **`cancelMode => 'draft'`** — backing out of a half-written document offers
  to keep it rather than bin it, emitting `DraftRequested` with the document.
  Where a draft LIVES stays the host's business; the editor has no database.
- **`cancelStyle => 'icon'`** — the close glyph full-screen composers use,
  instead of the word Cancel.
- **Video posters.** A frame is pulled from half a second in — past the black
  or half-exposed opening frame many recordings have — so a video card shows
  what it contains instead of a grey placeholder.

### Fixed

- **A poll's length was never saved.** `durationMinutes` was missing from the
  serialized attributes, so the author's choice was dropped and the host had
  nothing to compute a closing time from.
- **Blank poll answers were saved.** The composer keeps an empty row so you can
  type into it; shipping one means a poll with an answer nobody can choose.

Both are covered by parity harness cases on each platform.

## [0.2.0] - 2026-07-29

### Added

- **Android parity.** Everything that was iOS-only in 0.1.x now works on both,
  device-verified against the iOS screenshots: the media strip with
  per-thumbnail remove / description / edit, the inline poll card with its
  option cap and duration, host accessory rows, the countdown ring, the soft
  length cap with the overrun shaded, the filled save pill, `history => false`,
  `toolbar => []` meaning no toolbar, re-opening from saved JSON, and the
  full-screen media viewer.

### Fixed

- **The Android build was broken outright.** Bridge functions are
  code-generated into each platform's registration file, so declaring
  `Preview` and `SetAccessory` in the manifest without implementing them in
  Kotlin stopped the app compiling — and every Android deploy silently kept the
  previous APK. Compiling the plugin file alone still succeeded, which is what
  hid it. A test now insists every declared bridge function exists in both
  native sources.
- Two events extended a base class that does not exist, so tapping a host
  accessory row did nothing at all: `#[On(Event::class)]` does not autoload, so
  the listener registered and the failure only surfaced, silently, at dispatch.
- Attachments rendered twice in `strip` layout on Android — once as a card in
  the flow and once as a thumbnail.
- The text counter drew beside the ring, saying the same thing twice.

## [0.1.1] - 2026-07-29

### Changed

- **Requires PHP 8.4+.** 0.1.0 published as `^8.2|^8.3|^8.4`, which disagreed
  with the documented requirement and meant supporting three PHP versions.

### Documentation

- The events table listed two of six events; `accessories`, `setAccessory`,
  the media strip and `preview()` were not documented at all.
- NativePHP Mobile v4 is what the plugin is developed and tested against; v3
  is supported by the code but not exercised, and now says so.

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
