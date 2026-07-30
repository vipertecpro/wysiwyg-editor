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
- 📑 **Blocks** — H1–H3, bullet / ordered lists, **checklists**, blockquote, dividers
- 🖼️ **Media** — images, video and attachments, with a pending state while your app uploads
- 📊 **Polls** — written inline, with per-answer pictures, an option cap and a length
- 🙋 **Mentions and hashtags** — the editor spots the trigger, YOUR app answers with who matches, and the pick is saved as a link carrying the entity id
- 🎨 **Post backgrounds** — a few words held large on a colour, the way a social composer does it; round-trips in the HTML and the JSON both
- 🗂️ **Your own sheets** — declare a list or a grid of options and the editor presents them over its own window, then tells you what was picked
- 🧰 **Configurable toolbar** — presets (`full`, `basic`, `comment`, `note`) or an explicit ordered tool list
- 📱 **Bottom-sheet menus** — optional Format / Insert sheets instead of a bar that scrolls off screen
- ↩️ **Undo / redo**, placeholder text, live character / word / reading-time readouts
- ✅ **Validation** — `minWords`, `maxWords`, `requiredBlocks`, `maxImages`, checked natively before a save
- 🔁 **Clean HTML in, clean HTML out** — one documented tag set, byte-identical on both platforms
- 📤 **Export** — HTML, plain text, JSON (canonical) and Markdown, and `open()` takes HTML **or** JSON back
- 🌗 **Theme-aware** — light / dark, your app's colours AND its font, adopted automatically
- 🌍 **Localizable** — every user-visible string, with placeholders your translation controls
- 💾 **Auto-save seam** — a debounced `ContentChanged` event; the editor stays out of your database
- 📦 **Zero dependencies** — no third-party native libraries, no permissions, no network
- 🍏 🤖 **iOS + Android** behind one PHP API

## Requirements

- PHP 8.4+
- NativePHP Mobile v3 or v4 (`nativephp/mobile: ^3.0|^4.0`) — **developed and
  tested against v4**; the v3 path is supported by the code but not exercised
  in CI, so treat it as best-effort
- iOS 15+ / Android API 26+

## Platform support

**Both platforms have the same features.** One PHP API, one document model,
one HTML/JSON contract — and a parity harness that asserts the coder produces
byte-identical output on each.

Everything is implemented and device-verified on iOS **and** Android: the text
engine and every mark and block; the toolbar, its presets and bottom-sheet
menus; the media strip with per-thumbnail remove, description and edit; the
inline poll card with its option cap and duration; host accessory rows; the
countdown ring; the soft length cap with the overrun shaded; the filled save
pill; the full-screen media viewer; re-opening from saved JSON; typography and
spacing; theming; localization; validation; counts; haptics; the auto-save
seam; embeds with provider detection; and HTML / plain text / JSON / Markdown
export.

Where the two differ is only where the platforms do: iOS uses UITextView and
NSAttributedString, Android EditText and Spannable; each draws with its own
vector API from one shared set of icon paths. A document written on one opens
identically on the other.

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
| `typography` | array | — | `fontFamily`, `fontSize` (base, 10–32), `lineHeight` (1.0–2.0). Headings scale from the base |
| `spacing` | string | `comfortable` | Editing density: `compact`, `comfortable`, `roomy` |
| `menu` | string | `toolbar` | `toolbar` = one scrolling bar; `sheet` = compact bar + Format/Insert bottom sheets |
| `mediaLayout` | string | `blocks` | `blocks` = media sits in the text flow; `strip` = a thumbnail row under it |
| `maxMedia` | int | `4` | Attachments allowed; `0` = no limit |
| `countStyle` | string | `text` | `text` readout, or a `ring` counting down to `maxLength` |
| `maxLengthMode` | string | `hard` | `hard` refuses the keystroke; `soft` allows the overrun, shades it and blocks save |
| `avatar` | string | `''` | The author's picture — a url or a local path |
| `avatarPlacement` | string | `text` | `text` beside the writing, `header` beside Close and Save, `none` |
| `toolbarAlign` | string | `leading` | `trailing` parks a short bar in the corner instead of the left edge |
| `customTools` | list | `[]` | Extra toolbar buttons: `id`, `icon`, optional `label`, optional `sheet`. Tapping emits `ToolTapped` — unless it names a sheet, which the editor presents instead |
| `accessories` | list | `[]` | Your own controls — see [Your own rows in the composer](#your-own-rows-in-the-composer) |
| `sheets` | array | `[]` | Sheets the editor presents on your behalf — see [Your own sheets](#your-own-sheets) |
| `triggers` | array\|false | `@` → mention, `#` → hashtag | Characters that start a lookup; `false` turns it off entirely |
| `backgrounds` | array | `[]` | Colours a short post can be written ON — see [Post backgrounds](#post-backgrounds) |
| `backgroundMaxLength` | int | `130` | Past this many characters a background is dropped |
| `cancelMode` | string | `discard` | `discard` asks to throw the edits away; `draft` offers to keep them and emits `DraftRequested` |
| `cancelStyle` | string | `text` | `text` shows "Cancel"; `icon` shows a ✕ |
| `saveStyle` | string | `text` | `text` button, or a `filled` pill that dims until there is something to save |
| `history` | bool | `true` | Show undo / redo ahead of the tools |
| `pollOptionMaxLength` | int | `25` | Longest a single poll answer may be |
| `theme` | array | `[]` | Hex colors: `background`, `text`, `accent` (Save button), `highlight` (active states). Omitted keys fall back to the host app's theme, then to system-adaptive defaults |
| `id` | string | `null` | Echoed back on the result event, to correlate concurrent editors |

Available tools for `toolbar` (this order is the `full` preset):
`bold`, `italic`, `underline`, `strikethrough`, `h1`, `h2`, `h3`,
`bulletList`, `orderedList`, `checklist`, `blockquote`, `link`, `code`, `textColor`,
`highlight`, `image`, `camera`, `video`, `file`, `poll`, `divider`, `embed`,
`clearFormat`.
Undo/redo are always present and are not toolbar keys.

**You are meant to take only what you need.** An explicit empty list draws no
bar at all, and everything that costs something is opt-in: name no media tool
and the picker, the uploader and `MediaRequested` never come into play; pass
`triggers => false` and nothing watches your keystrokes. An editor opened with
no options carries no media, no polls, no colours, no host controls and no
lookups — which is what makes it usable as a plain text field.

Toolbar presets:

```php
WysiwygEditor::open($html);                                     // full — everything
WysiwygEditor::open($html, ['preset' => 'basic']);              // bold italic underline strike lists link
WysiwygEditor::open($html, ['preset' => 'comment', 'maxLength' => 500]); // bold italic link
WysiwygEditor::open($html, ['preset' => 'note']);               // bold italic underline h1 h2 lists checklist
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
| `…\Events\ContentSaved` | `string $html`, `string $text`, `string $json`, `?string $id` | User taps **Save** |
| `…\Events\EditCancelled` | `?string $id` | User cancels / backs out (a discard confirm guards unsaved changes) |
| `…\Events\ContentChanged` | `string $html`, `string $text`, `string $json`, `?string $id` | Typing settled, when `changeDebounce` is set — the auto-save seam |
| `…\Events\MediaRequested` | `string $kind`, `?string $id` | User tapped image / video / file. Answer with `insertMedia()` |
| `…\Events\MediaEditRequested` | `string $kind`, `string $uploadId`, `string $source`, `?string $id` | User tapped edit on an attachment. Re-open your own picker |
| `…\Events\DraftRequested` | `string $html`, `string $text`, `string $json`, `?string $id` | User backed out of a half-written document and chose to keep it (`cancelMode => 'draft'`) |
| `…\Events\ToolTapped` | `string $tool`, `?string $id` | User tapped one of your own toolbar buttons |
| `…\Events\AccessoryTapped` | `string $accessory`, `?string $id` | User tapped one of your own controls. Answer with `setAccessory()` |
| `…\Events\SuggestionRequested` | `string $kind`, `string $trigger`, `string $query`, `?string $id` | User typed a trigger character. Answer with `suggestions()` |
| `…\Events\SheetOptionPicked` | `string $sheet`, `string $option`, `?string $id` | User chose something from one of your declared sheets |

All events live under `Vipertecpro\WysiwygEditor\Events\`.

### What you actually receive

The same document arrives three ways. They are not alternatives to pick
between — each answers a different question, and a real client usually sends
more than one. A post with some words, a photo still uploading, a photo
already uploaded and a poll produces exactly this:

**`$html`** — to RENDER. Safe to publish as-is:

```html
<p>Shipping <strong>today</strong>.</p>
<figure data-pending="u-1"><img alt="The harbour"></figure>
<figure><img src="https://cdn.example.com/a.jpg" alt=""></figure>
<figure data-poll="{…}"></figure>
```

Note what is **not** in there: the photo still uploading has no `src` at all. A
device path must never leak into published markup, so the editor omits it and
marks the figure `data-pending` instead.

**`$text`** — to SEARCH and to excerpt. Marks stripped, one line per block.

**`$json`** — CANONICAL. The only form carrying device paths, poll option ids,
upload state and the background a post was written on:

```json
{"version":2,"background":"sunset","blocks":[
  {"id":"","type":"p","runs":[
    {"text":"Shipping ","marks":{}},
    {"text":"today","marks":{"bold":true}},
    {"text":".","marks":{}}]},
  {"id":"","type":"image","localPath":"/var/mobile/…/IMG_0042.HEIC",
   "alt":"The harbour","uploadId":"u-1"},
  {"id":"","type":"image","src":"https://cdn.example.com/a.jpg"},
  {"id":"","type":"poll","question":"Ship it?","durationMinutes":"1440",
   "options":[{"id":"o1","label":"Yes"},{"id":"o2","label":"No"}]}]}
```

Store `$json` if the document should ever be **editable** again — re-opening
from `$html` alone comes back without any photo whose upload had not finished,
and without the colour the post was written on.

### Saving text and attachments separately

Most servers want the prose in one table and the files in another. The editor
uploads nothing — the endpoint is yours, so the upload is too — and you should
not have to learn the document format to find the files:

```php
#[On(ContentSaved::class)]
public function onSaved(string $html, string $text, string $json): void
{
    $post = Http::withToken($token)
        ->post('https://api.example.com/posts', [
            'html' => $html,   // to render
            'text' => $text,   // to search
            'json' => $json,   // to re-open for editing
        ])->json();

    foreach (WysiwygEditor::attachments($json) as $file) {
        if ($file['path'] === '') {
            continue;          // already on your server; $file['url'] says where
        }

        Http::withToken($token)
            ->attach('file', file_get_contents($file['path']), basename($file['path']))
            ->post("https://api.example.com/posts/{$post['id']}/media", [
                'kind' => $file['kind'],       // image | video | file
                'alt' => $file['alt'],
                'caption' => $file['caption'],
                'uploadId' => $file['uploadId'],
            ]);
    }
}
```

**Exactly one of `path` and `url` is ever filled**, so which to do next is
never ambiguous: a device path means it still needs uploading, a url means it
is already yours. Polls, dividers and embeds are not files and are not
returned — they travel in the document itself.

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

### Where attachments sit

`mediaLayout` decides whether media lives in the text or beside it:

- **`blocks`** (default) — each image, video or poll is a card at the point it
  was inserted. Right for notes, articles and documentation, where a picture
  belongs at a particular place in the prose.
- **`strip`** — media is pulled out of the flow into a horizontally scrolling
  row of thumbnails under the text, each with its own remove, description and
  edit controls. Right for social composers, where an attachment belongs to the
  POST rather than to a position in it, and a full-width card each would push
  the writing off the screen.

`maxMedia` caps attachments (default **4** — what the common grids are built to
lay out); `0` means no limit.

Tapping edit on a thumbnail emits `MediaEditRequested` with the block's
`uploadId` and current source. The editor does not crop, rotate or filter —
re-open your own picker and call `insertMedia()` again with the same
`uploadId` to replace it.

### Showing media full-screen

```php
WysiwygEditor::preview('image', $post->photo);   // or 'video'
```

Opens a zoomable image viewer, or a player for video. It lives in the plugin
because the editor already decodes images and plays video for its own cards,
and because NativePHP ships no video element for a host to build a viewer out
of.

## Your own buttons in the toolbar

The same idea as accessory rows, one level up. The editor cannot know what a
GIF picker, a location tagger or a scheduler should do — those are your
features, backed by your services — so it draws the button and reports the tap.

```php
WysiwygEditor::open($html, [
    'toolbar' => ['image', 'camera', 'video', 'poll'],
    'customTools' => [
        ['id' => 'gif', 'icon' => 'embed', 'label' => 'GIF'],
        ['id' => 'schedule', 'icon' => 'orderedList', 'label' => 'Schedule'],
    ],
    'avatar' => $user->avatarUrl,
]);

#[On(ToolTapped::class)]
public function onToolTapped(string $tool): void
{
    // Your picker, your sheet, your data.
}
```

`icon` names one of the editor's own glyphs, so your buttons are drawn by the
same vector code as everything else and match on both platforms. `camera` is a
first-class tool rather than a custom one, because a photo you TAKE and a photo
you PICK are different screens — it emits `MediaRequested` with `kind` of
`camera`.

`avatar` puts the author's picture beside what they are writing, the way social
composers arrange it. A url or a local path; it is decoded the same way media
is, so an app that has not uploaded one yet still shows something.

## Your own rows in the composer

The editor owns the whole screen, so without this an app could not put its own
controls beside the text — and most composers have some: *Tag people*, *Add
location*, an audience picker.

None of that belongs in an editor: they are your features, backed by your data.
So the editor draws the row and gets out of the way.

```php
WysiwygEditor::open($html, [
    'accessories' => [
        ['id' => 'tag',      'label' => 'Tag people',         'icon' => 'image'],
        ['id' => 'audience', 'label' => 'Everyone can reply', 'value' => 'Everyone'],
    ],
]);

#[On(AccessoryTapped::class)]
public function onAccessoryTapped(string $accessory): void
{
    // Your picker, your data. The editor stays open throughout.
    WysiwygEditor::setAccessory('audience', 'Everyone can reply', 'People you follow');
}
```

Each control takes `id` (reported back on tap), `label`, and optionally:

| Key | Meaning |
| --- | --- |
| `icon` | One of the editor's own glyph names |
| `value` | Trailing text — the choice that was made |
| `placement` | `row` under the media (default), or `header` beside Close and Save |
| `style` | `row` full width, `chip` label + disclosure, `icon` a bare glyph. A header control defaults to `chip` |
| `sheet` | Names a declared sheet to present instead of merely reporting the tap |

A control without an `id` could never report a tap and one without a `label`
would draw as a blank tappable strip — both are dropped rather than shown.

**`header` is for the controls that belong beside the button that sends the
post** — an audience picker decides who sees it, so it belongs next to Save,
not below the fold. An `icon` control draws its `value` beside the glyph once
it has one, so a schedule button can say *when* rather than looking identical
before and after you use it.

## Mentions and hashtags

The editor watches for a trigger character and reports what follows it. **It
has no directory of people and should not grow one** — who is mentionable
depends entirely on who is asking, which only your app knows.

```php
use Vipertecpro\WysiwygEditor\Events\SuggestionRequested;

WysiwygEditor::open($html, [
    'triggers' => ['@' => 'mention', '#' => 'hashtag'],   // the default
]);

#[On(SuggestionRequested::class)]
public function onSuggestionRequested(string $kind, string $trigger, string $query = ''): void
{
    // Fires on every keystroke, so debounce or cap it before hitting an API.
    $matches = User::query()
        ->whereLike('name', "%{$query}%")
        ->limit(5)
        ->get()
        ->map(fn (User $u) => [
            'id' => (string) $u->id,      // required — becomes the entity reference
            'label' => $u->name,          // required — what is inserted
            'detail' => $u->headline,     // optional second line
            'avatar' => $u->avatar_url,   // optional picture
        ]);

    WysiwygEditor::suggestions($query, $matches->all());
}
```

Picking one writes a **link**, not styled text, so the saved post says WHICH
person was named rather than merely that some words are blue:

```html
<p>Shipping this with <a href="mention:u2">@Grace Hopper</a> </p>
```

The href is `{kind}:{id}` — the `kind` you declared and the `id` you returned.
Render it however you like; the editor only guarantees it survives the round
trip, including back into an edit.

Turn it off entirely with `'triggers' => false`, and nothing watches
keystrokes at all.

## Post backgrounds

A few words held large and centred on a colour, the way a social composer
does it — the post stops being a paragraph and becomes a card.

```php
WysiwygEditor::open($html, [
    'backgrounds' => [
        'ocean' => ['from' => '#2563EB', 'to' => '#0EA5E9'],
        'sunset' => ['from' => '#F97316', 'to' => '#DB2777'],
        'blush' => ['from' => '#FBCFE8', 'to' => '#FDE68A', 'textColor' => '#1F2937'],
    ],
    'backgroundMaxLength' => 130,
]);
```

`from` alone is a flat colour; adding `to` makes it a gradient. `textColor`
defaults to white. **Which colours exist is your decision** — the editor ships
no palette, because that is a brand decision.

The swatches are offered only while the post is still short and has no media:
a paragraph set in 28pt white on orange is unreadable, and a photo already IS
the card.

A background belongs to the DOCUMENT, not to a run inside it, so it
round-trips in both forms:

```html
<div data-background="sunset"><p>Big news</p></div>
```
```json
{"version":2,"background":"sunset","blocks":[…]}
```

It is in the HTML as well as the JSON on purpose: for a post like this the
background IS the post, and a host rendering saved markup would otherwise show
a few words in plain black on white.

## Your own sheets

The editor owns the screen — on iOS it owns its own window — so **a sheet you
drew would open behind it**. That is not something an app should have to work
around, so you declare the options and the editor presents them, then reports
the pick.

```php
use Vipertecpro\WysiwygEditor\Events\SheetOptionPicked;

WysiwygEditor::open($html, [
    'accessories' => [
        ['id' => 'audience', 'label' => 'Anyone', 'placement' => 'header', 'sheet' => 'audience'],
    ],
    'customTools' => [
        ['id' => 'more', 'icon' => 'plus', 'label' => 'More', 'sheet' => 'compose'],
    ],
    'sheets' => [
        'audience' => [
            'title' => 'Who can see your post?',
            'options' => [
                ['id' => 'public', 'label' => 'Public', 'detail' => 'Anyone', 'icon' => 'globe', 'selected' => true],
                ['id' => 'friends', 'label' => 'Friends', 'icon' => 'people'],
            ],
        ],
        'compose' => [
            'style' => 'grid',    // circular tiles, three across
            'options' => [
                ['id' => 'media', 'label' => 'Media', 'icon' => 'image'],
                ['id' => 'poll', 'label' => 'Poll', 'icon' => 'poll'],
            ],
        ],
    ],
]);

#[On(SheetOptionPicked::class)]
public function onPicked(string $sheet, string $option): void
{
    match ([$sheet, $option]) {
        ['compose', 'media'] => $this->pickAPhoto(),          // your picker
        ['compose', 'poll'] => WysiwygEditor::insertTool('poll'),
        default => $this->remember($sheet, $option),
    };

    // Write the answer back so the control that opened it shows the choice.
    WysiwygEditor::setAccessory('audience', 'Friends', 'Friends');
}
```

`style` is `list` (rows with a tick) or `grid` (circular tiles). What the
options MEAN stays yours; the editor draws them and gets out of the way.

**Offer nothing you cannot honour.** A tile that reports a tap nobody acts on
is a dead control, and it looks exactly like a bug.

### Running one of the editor's own tools

A composer whose toolbar is a sheet of your own still needs to say "insert a
poll":

```php
WysiwygEditor::insertTool('poll');      // or divider, image, camera, video, file
```

Only tools the editor actually owns; anything else is ignored, so a typo does
nothing rather than something surprising. Formatting marks are not available
this way — they apply to a selection, and a sheet has no idea what is selected.

## Polls

`poll` inserts a poll the user writes in the editor — a question and its
options — with no host round-trip, because there is nothing to pick and
nothing to upload. Tapping an existing poll re-opens the composer to edit it.

The editor **authors** polls; it does not run them. Voting belongs to whatever
renders your saved content, which is also where the votes have to be stored.
The block round-trips through HTML as `<figure data-poll="…">` and through
JSON with its option ids intact, so your renderer has everything it needs.

## Exporting

`ContentSaved` hands you the document three ways:

| Format | Payload | Lossless? |
| --- | --- | --- |
| HTML | `$html` | Text is exact. Block ids, upload state and poll options have nowhere to live in HTML |
| Plain text | `$text` | No, by definition — it is the rendition used for counts and previews |
| JSON | `$json` | **Yes** — this is the canonical form |

Markdown is derived from the JSON, not the HTML, so it never inherits a loss
that already happened:

```php
#[On(ContentSaved::class)]
public function onSaved(string $html, string $text, string $json): void
{
    $markdown = WysiwygEditor::toMarkdown($json);
}
```

Markdown is a narrower format than the document model, so some things cannot
survive and are **dropped rather than approximated** — underline, text colour
and highlight have no Markdown spelling, and emitting raw HTML for them would
produce a file that is Markdown in name only. Video and file blocks become
links, an embed becomes its bare URL, and a poll becomes its question plus a
list: the content crosses over, the interactivity does not. Store the JSON if
you need everything back.

## Typography and spacing

The editor takes the host application's **font** the same way it takes its
colours — if the NativeUI theme names one (`fonts.default` or `font-family`),
the editor uses it with no configuration. A font the app never bundled falls
back to the system face rather than rendering nothing.

Size and density are set explicitly:

```php
WysiwygEditor::open($html, [
    'typography' => ['fontSize' => 18, 'lineHeight' => 1.3],
    'spacing' => 'roomy',
]);
```

The **heading ramp is derived** from `fontSize` with fixed multipliers
(1.75 / 1.375 / 1.125), so one number moves the whole scale and the
proportions hold. The default base of 16 gives exactly the 28 / 22 / 18 ramp
the editor has always used, so nothing shifts unless you ask it to.

`spacing` values are points on iOS and **dp** on Android, so both platforms
lay out the same. Unlike colours and the font this is a choice you make rather
than something adopted — NativeUI has no spacing token to read, and guessing
one would be inventing a schema.

| Scale | Horizontal | Vertical | Paragraph |
| --- | --- | --- | --- |
| `compact` | 12 | 8 | 4 |
| `comfortable` | 16 | 12 | 6 |
| `roomy` | 20 | 18 | 10 |

## Toolbar or bottom sheets

`menu` decides how the tools are reached:

```php
WysiwygEditor::open($html, ['menu' => 'sheet']);
```

- **`toolbar`** (default) puts every enabled tool in one horizontally
  scrolling bar. Right for a short toolbar — the `comment` preset has four
  tools and they all fit.
- **`sheet`** keeps undo/redo and bold/italic on the bar and moves the rest
  behind **Format** and **Insert** bottom sheets. Right for the full toolbar,
  where a scrolling bar hides most tools off the right edge and nobody
  scrolls it.

The sheets are built from the SAME `toolbar` list, so they stay modular: a
tool you did not enable does not appear, and a section with nothing in it is
not drawn. Every row is localizable through `strings` like everything else —
see `WysiwygEditor::TOOL_LABEL_KEYS` for which key labels which tool.

`Body` is always offered in the Format sheet even though it is not a tool,
because without it there is no way back to plain text once a heading has been
applied.

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
