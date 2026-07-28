# WysiwygEditor — a native WYSIWYG rich text editor for NativePHP Mobile

[![Packagist Version](https://img.shields.io/packagist/v/vipertecpro/wysiwyg-editor.svg?style=flat-square)](https://packagist.org/packages/vipertecpro/wysiwyg-editor)
[![Total Downloads](https://img.shields.io/packagist/dt/vipertecpro/wysiwyg-editor.svg?style=flat-square)](https://packagist.org/packages/vipertecpro/wysiwyg-editor)
[![PHP Version](https://img.shields.io/packagist/php-v/vipertecpro/wysiwyg-editor.svg?style=flat-square)](https://packagist.org/packages/vipertecpro/wysiwyg-editor)
[![License](https://img.shields.io/packagist/l/vipertecpro/wysiwyg-editor.svg?style=flat-square)](LICENSE)
[![Platforms](https://img.shields.io/badge/platforms-iOS%20%7C%20Android-blue?style=flat-square)](#requirements)

Open a **fully native** rich text editor from PHP — the user writes with a real
native keyboard and a formatting toolbar (bold, italic, headings, lists, links,
colors…), then you get **clean HTML** back. Written against UITextView /
NSAttributedString (iOS) and EditText / Spannable (Android), with one simple
PHP API and **zero third-party native libraries**. No webview.

Think Quill / TipTap / CKEditor — but as a real native mobile screen instead of
a JavaScript editor in a browser.

## Features

- ✍️ **True native editing** — the platform text engine, keyboard, autocorrect and selection, not a webview
- 🅱️ **Inline marks** — bold, italic, underline, strikethrough, inline code, links, text color, highlight
- 📑 **Blocks** — H1–H3, bullet / ordered lists, blockquote
- 🧰 **Configurable toolbar** — presets (`full`, `basic`, `comment`, `note`) or an explicit ordered tool list
- ↩️ **Undo / redo**, placeholder text, live character counter with `maxLength`
- 🔁 **Clean HTML in, clean HTML out** — one documented tag set, identical output on both platforms
- 🌗 **Theme-aware** — follows the system light / dark theme, or recolour it to match your app
- 📦 **Zero dependencies** — no third-party native libraries, no permissions, no network
- 🍏 🤖 **iOS + Android** behind one PHP API

## Requirements

- PHP 8.4+
- NativePHP Mobile v3 or v4 (`nativephp/mobile: ^3.0|^4.0`)
- iOS 15+ / Android API 26+

## Installation

```bash
composer require vipertecpro/wysiwyg-editor
php artisan vendor:publish --tag=nativephp-plugins-provider   # once per app
php artisan native:plugin:register vipertecpro/wysiwyg-editor
php artisan native:plugin:list       # verify "WysiwygEditor" + "WysiwygEditor.Open" appear
php artisan native:run ios           # or: android — rebuild so the native code compiles in
```

> Requiring with Composer is **not** enough — an unregistered plugin does
> nothing. Always run `native:plugin:register` and confirm with
> `native:plugin:list`.

## Usage

Call the facade from a `NativeComponent`, then handle the result event.

```php
use Native\Mobile\Attributes\On;
use Native\Mobile\Edge\NativeComponent;
use Vipertecpro\WysiwygEditor\Events\ContentSaved;
use Vipertecpro\WysiwygEditor\Events\EditCancelled;
use Vipertecpro\WysiwygEditor\Facades\WysiwygEditor;

class EditNote extends NativeComponent
{
    public string $body = '';

    public function edit(): void
    {
        WysiwygEditor::open($this->body, [
            'title' => 'Edit note',
            'placeholder' => 'Write something…',
        ]);
    }

    #[On(ContentSaved::class)]
    public function onSaved(string $html, string $text): void
    {
        $this->body = $html;         // clean, normalised HTML
    }

    #[On(EditCancelled::class)]
    public function onCancelled(): void
    {
        // user backed out — content unchanged
    }
}
```

> **On NativePHP Mobile v3**, the `#[On]` attribute isn't available — listen for
> the events with `#[OnNative(...)]` (from `Native\Mobile\Attributes\OnNative`)
> instead. Everything else is identical; the plugin itself is unchanged across
> v3 and v4.

### Options

`WysiwygEditor::open(string $html = '', array $options = []): void`

All options are optional:

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `preset` | string | `full` | Built-in toolbar: `full`, `basic`, `comment`, `note` |
| `toolbar` | list | — | Explicit **ordered** tool list; overrides `preset` |
| `title` | string | `''` | Heading shown in the editor's top bar |
| `placeholder` | string | `''` | Shown while the editor is empty |
| `maxLength` | int | `0` | Max **plain-text** length; `0` = unlimited. Shows a live counter |
| `counts` | list | `[]` | Live readouts: `characters`, `words`, `readingTime` (200 wpm, min 1) |
| `validation` | array | `[]` | Save-time rules: `minWords`, `maxWords`, `requiredBlocks`, `maxImages` |
| `strings` | array | English | Translations for every user-visible string — see Localization |
| `changeDebounce` | int | `0` | Emit `ContentChanged` this many ms after typing stops; `0` = off |
| `haptics` | bool | `true` | Light haptic tap on toolbar buttons |
| `theme` | array | `[]` | Hex colors: `background`, `text`, `accent` (Save button), `highlight` (active states). Omitted keys fall back to the host app's theme, then to system-adaptive defaults |
| `id` | string | `null` | Echoed back on the result event, to correlate concurrent editors |

Available tools for `toolbar` (this order is the `full` preset):
`bold`, `italic`, `underline`, `strikethrough`, `h1`, `h2`, `h3`,
`bulletList`, `orderedList`, `blockquote`, `link`, `code`, `textColor`,
`highlight`, `clearFormat`. Undo/redo are always present and are not toolbar
keys.

Toolbar presets:

```php
WysiwygEditor::open($html);                                     // full — everything
WysiwygEditor::open($html, ['preset' => 'basic']);              // bold italic underline strike lists link
WysiwygEditor::open($html, ['preset' => 'comment', 'maxLength' => 500]); // bold italic link
WysiwygEditor::open($html, ['preset' => 'note']);               // bold italic underline h1 h2 lists
WysiwygEditor::open($html, ['toolbar' => ['bold', 'link']]);    // exactly these, in this order
```

### Theming

The editor **adopts the host application's theme automatically**. When
`nativephp/native-ui` is present the plugin reads its tokens
(`Theme::all()`) and derives its four surfaces per colour scheme, so the
editor follows your app into dark mode with no configuration:

| Editor surface | Host token (first match wins) |
| --- | --- |
| `background` | `background`, `surface` |
| `text` | `on-background`, `on-surface` |
| `accent` (Save) | `primary`, `accent` |
| `highlight` (active tools) | `primary`, `accent`, `secondary` |

Precedence is **explicit `theme` option → host tokens → the plugin's
system-adaptive defaults**, so passing colours still overrides everything and
an app without NativeUI behaves exactly as before.

Override it explicitly to match a specific look:

```php
WysiwygEditor::open($html, [
    'theme' => [
        'background' => '#121417',
        'text' => '#FFFFFF',
        'accent' => '#F97316',   // Save button
        'highlight' => '#22C55E', // toggled toolbar buttons / active states
    ],
]);
```

## Events

| Event | Payload | When |
| --- | --- | --- |
| `Vipertecpro\WysiwygEditor\Events\ContentSaved` | `string $html`, `string $text`, `string $json`, `?string $id` | User taps **Save** |
| `Vipertecpro\WysiwygEditor\Events\EditCancelled` | `?string $id` | User cancels / backs out (a discard confirm guards unsaved changes) |

`$html` is the document in the normalised form below; `$text` is the same
content as plain text — marks stripped, one line per block — handy for
excerpts, search indexing and length checks.

`$json` is the **fidelity format**: the block document with block ids, poll
options and upload state, none of which HTML can represent. Store `$json` when
you need loss-free round-trips (media, polls, embeds); store `$html` to render.
For a text-only document the two carry the same information.

### Validation

```php
WysiwygEditor::open($html, [
    'validation' => [
        'minWords' => 50,
        'maxWords' => 2000,
        'requiredBlocks' => ['image'],   // must contain at least one image
        'maxImages' => 10,
    ],
]);
```

Checked natively when the user taps Save — a failing document never makes the
round-trip to PHP just to be rejected.

### Localization

The plugin ships **no locale files**, on purpose: your app already knows the
user's language and has its own translation workflow. Pass the strings you want
changed and the rest keep their English defaults.

```php
WysiwygEditor::open($html, [
    'strings' => [
        'save' => __('editor.save'),
        'cancel' => __('editor.cancel'),
        'discardTitle' => __('editor.discard_title'),
        'ruleMinWords' => __('editor.min_words'),   // "Se necesitan {max}…"
    ],
]);
```

`{n}`, `{max}` and `{type}` are substituted natively, so the **translation**
controls word order — important in languages where the number does not come
first. Unknown keys are dropped rather than silently ignored, so a typo shows
up immediately. See `WysiwygEditor::STRINGS` for the full key list.

### Auto-save

The editor does not own drafts or persistence — it tells you the document
changed and settled, and you decide what that means:

```php
WysiwygEditor::open($note->body, ['changeDebounce' => 1500]);

#[On(ContentChanged::class)]
public function onChanged(string $html, string $json): void
{
    $this->note->update(['body_html' => $html, 'body_json' => $json]);
}
```

Off by default, so apps that don't want it pay nothing.

## HTML contract

Both platforms parse and serialize **exactly** this tag set, so a document
round-trips identically on iOS and Android. This section is normative — the
Swift and Kotlin implementations are written against it.

### Blocks (serialized in document order)

| Block | Serialized as |
| --- | --- |
| Paragraph | `<p>…</p>` |
| Empty paragraph (blank line) | `<p><br></p>` |
| Heading 1–3 | `<h1>…</h1>` / `<h2>…</h2>` / `<h3>…</h3>` |
| Bullet list | `<ul><li>…</li><li>…</li></ul>` (consecutive items in ONE `<ul>`) |
| Ordered list | `<ol><li>…</li></ol>` (consecutive items in ONE `<ol>`) |
| Blockquote | `<blockquote>…</blockquote>` (inline content only) |

No attributes on block tags. No nested lists in v1. Blocks are concatenated
with **no whitespace between them**.

### Inline marks (nesting order, outermost → innermost)

`<a href="…">` → `<span style="color:#RRGGBB">` →
`<mark style="background-color:#RRGGBB">` → `<strong>` → `<em>` → `<u>` →
`<s>` → `<code>`

Adjacent runs with identical marks are merged. Text nodes escape `&` `<` `>`
(and `"` inside attribute values). Colors always serialize as 6-digit
uppercase hex.

### Parser tolerance (input only)

Parsing accepts aliases and normalises them: `<b>`→`strong`, `<i>`→`em`,
`<del>`/`<strike>`→`s`, `<div>`→`p`, `<h4>`–`<h6>`→`h3`, `<mark>` without a
style → default highlight. `<br>` inside a block splits it into two blocks.
Unknown tags are ignored but their text content is kept. Unknown attributes
are dropped. `javascript:` and other non-http(s)/mailto/tel link schemes are
dropped (the text is kept, the link removed).

Entities `&amp; &lt; &gt; &quot; &#39; &nbsp;` are decoded. `&nbsp;` becomes a
real non-breaking space (U+00A0) and is emitted **raw** on the way out, not
re-encoded — runs of ordinary whitespace collapse to a single space, U+00A0
does not. Text between blocks that is pure whitespace is dropped; any other
loose text opens an implicit `<p>`.

### Verified examples

These round-trip identically on both platforms (input → `$html`, `$text`), and
are checked by the parity harnesses in [tests/native/ios](tests/native/ios) and
[tests/native/android](tests/native/android):

| Input | `$html` | `$text` |
| --- | --- | --- |
| `<p>Hello <strong>wor</strong>ld</p>` | unchanged | `Hello world` |
| `<div>a<br>b</div>` | `<p>a</p><p>b</p>` | `a\nb` |
| `<b>x</b>` | `<p><strong>x</strong></p>` | `x` |
| `<h4>deep</h4>` | `<h3>deep</h3>` | `deep` |
| `<p><a href="javascript:alert(1)">x</a></p>` | `<p>x</p>` | `x` |
| `<p><span style="color:#f00">r</span></p>` | `<p><span style="color:#FF0000">r</span></p>` | `r` |
| `<p><mark>h</mark></p>` | `<p><mark style="background-color:#FDE68A">h</mark></p>` | `h` |
| `<p><br></p>` | `` (empty) | `` |
| `<ol><li>x</li><li>y</li></ol>` | unchanged | `1. x\n2. y` |

Marks that share a level nest into ONE tag rather than repeating it —
`<strong>a<em>b</em></strong>`, never `<strong>a</strong><strong><em>b</em></strong>`.

### Toolbar icons

The toolbar glyphs are **hand-drawn vector paths defined once** (a 24×24
viewBox, a tiny `M`/`L`/`C`/`Z` subset) and duplicated verbatim in the Swift
and Kotlin files, then stroked with each platform's vector API. SF Symbols and
Material icons share no common subset, so drawing the same vectors is the only
way the two toolbars can genuinely match. Edit both copies together.

### Plain-text rendition (`$text`)

One line per block, `\n`-joined. List items are prefixed `- ` (bullet) or
`1. `, `2. `… (ordered). All marks stripped.

## Editor UI

Top bar: **Cancel** · title · **Save** (accent color). The content area fills
the screen; the formatting toolbar is a horizontally scrollable icon row
pinned above the keyboard, with undo/redo first, then the configured tools.
Active formats show in the highlight color. `link` opens a small URL dialog
(pre-filled when editing an existing link); `textColor` / `highlight` open a
fixed 6-color palette (plus "none"). Cancelling with unsaved changes asks for
confirmation. The editor follows the system light/dark theme unless overridden
by `theme`.

## Inserting media

The editor ships **no picker and no uploader**, on purpose. It asks, and your
app answers with whatever it already uses — so permissions, auth and upload
infrastructure stay in one place instead of being duplicated inside an editor.

```
  toolbar tap                                    insertMedia(localPath)
      │                                                    ▲
      ▼                                                    │
MediaRequested ──▶ nativephp/mobile-camera ──▶ vipertecpro/image-cropper
```

```php
#[On(MediaRequested::class)]
public function onMediaRequested(string $kind): void
{
    Camera::pickImages('images', false);      // or your own picker
}

#[On(MediaSelected::class)]
public function onMediaSelected(bool $success, array $files, int $count): void
{
    ImageCropper::open($files[0]['path'], ['preset' => 'landscape']);
}

#[On(ImageCropped::class)]
public function onImageCropped(string $path): void
{
    WysiwygEditor::insertMedia('image', [
        'localPath' => $path,
        'uploadId' => $id = uniqid('up-'),
    ]);

    // Upload with your own stack (or nativephp/mobile-background-tasks),
    // then tell the editor how it went:
    WysiwygEditor::uploadProgress($id, 0.5);
    WysiwygEditor::uploadCompleted($id, $cdnUrl);
    WysiwygEditor::uploadFailed($id, 'Network unavailable');
}
```

The block appears the moment it is inserted, rendering from `localPath`, so
the user never waits on a network round-trip. Until an upload completes the
block exports as `<figure data-pending="…">` with **no `src`** — the device
path is never written into published HTML.

## Developing on a device

Two caching traps will make you think your changes did nothing. Both bit us:

- **Android caches the PHP bundle** in `app_storage`. Blade/PHP edits can keep
  running the previous version across several rebuilds. Force a fresh extract
  with `adb shell pm clear <applicationId>`.
- **iOS caches the *extracted* bundle** in `Documents/app`. A fresh `app.zip`
  inside the app is not enough — if an extraction already exists it is reused,
  so the app runs the previous PHP. `xcrun simctl uninstall <udid> <applicationId>`
  before re-running forces a clean extract.
- **iOS can also install an older `app.zip`** than the one the build just
  staged, which looks identical from the outside.

Check the **extracted** copy, not the zip — the zip being fresh proves nothing:

```bash
# iOS — is the PHP the app will actually run the code you just wrote?
C=$(xcrun simctl get_app_container <udid> <applicationId> data)
grep -c yourNewOption "$C/Documents/app/app/NativeComponents/YourScreen.php"
```

Native (Swift/Kotlin) code is compiled into the app and does NOT suffer from
this — only the PHP bundle does.

## License

MIT — see [LICENSE](LICENSE).
