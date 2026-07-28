# Changelog

All notable changes to `vipertecpro/wysiwyg-editor` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

### Fixed

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
