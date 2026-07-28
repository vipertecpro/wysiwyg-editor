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
