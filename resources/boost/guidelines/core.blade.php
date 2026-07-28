## vipertecpro/wysiwyg-editor

A NativePHP Mobile plugin that opens a **fully native** full-screen WYSIWYG
rich text editor (UITextView/NSAttributedString on iOS, EditText/Spannable on
Android — no webview) and returns the edited content to PHP via an event as
**clean HTML** plus a plain-text rendition. Works with NativePHP Mobile v3 and v4.

### What it does / does not do

- It edits rich text — it does NOT render arbitrary HTML. Only the documented
  tag set is supported (see "HTML contract" below); unknown tags are ignored
  but their text content is kept.
- Input: an HTML string (may be empty). Output: normalised HTML + plain text,
  delivered via the `ContentSaved` event. Nothing is written to disk.
- The call is fire-and-forget: `open()` returns `void`; the result arrives
  later as an event. Backing out fires `EditCancelled` instead.

### The one method

`WysiwygEditor::open(string $html = '', array $options = []): void`

`$options` keys (all optional):

- `preset`: `full` (default), `basic`, `comment`, `note` — built-in toolbars.
- `toolbar`: explicit ORDERED tool list, overrides `preset`. Tools: `bold`,
  `italic`, `underline`, `strikethrough`, `h1`, `h2`, `h3`, `bulletList`,
  `orderedList`, `blockquote`, `link`, `code`, `textColor`, `highlight`,
  `clearFormat`. Undo/redo are always present and are not toolbar keys.
- `title`: top-bar heading.
- `placeholder`: shown while the editor is empty.
- `maxLength`: int, max PLAIN-TEXT length with a live counter (`0` = unlimited).
- `theme`: hex colors so the editor matches the HOST APP's look — keys
  `background`, `text`, `accent` (Save button), `highlight` (active toolbar
  states). All optional; omitted keys keep the system-adaptive light/dark
  default. Identical rendering on iOS and Android.
- `id`: string echoed back on the result event, to correlate concurrent editors.

### Events

- `Vipertecpro\WysiwygEditor\Events\ContentSaved` — payload `string $html`,
  `string $text`, `?string $id`. Fired on Save.
- `Vipertecpro\WysiwygEditor\Events\EditCancelled` — payload `?string $id`.
  Fired on Cancel / back (a discard confirm guards unsaved changes).

Handle them in a `NativeComponent` with `#[On(ContentSaved::class)]` (v4) or
`#[OnNative(...)]` (v3). Handlers receive payload properties by name, e.g.
`public function onSaved(string $html, string $text): void`.

### HTML contract (what `$html` contains)

Blocks: `<p>`, `<h1>`–`<h3>`, `<ul><li>`, `<ol><li>`, `<blockquote>`; empty
paragraph = `<p><br></p>`. Inline marks, outermost → innermost: `<a href>`,
`<span style="color:#RRGGBB">`, `<mark style="background-color:#RRGGBB">`,
`<strong>`, `<em>`, `<u>`, `<s>`, `<code>`. Rendering this back in a Blade
view with unescaped output (`@{!! $html !!}`) is safe ONLY because the plugin
never emits scripts or event attributes — still prefer sanitising if the
content crosses users.

### Gotchas

- Requiring with Composer is not enough: run
  `php artisan native:plugin:register vipertecpro/wysiwyg-editor`, verify with
  `native:plugin:list`, then rebuild with `native:run`.
- `maxLength` counts plain text (what the counter shows), not HTML bytes —
  size database columns for HTML overhead on top of it.
- Store `$html`; use `$text` for excerpts / search indexing, not as the
  source of truth.
