# Document model v2 — blocks

**Status: normative.** The Swift and Kotlin implementations are written against
this document, and the parity harnesses assert both produce identical output
for the same input. When this file and an implementation disagree, this file
wins.

v1 modelled a document as one flat rich-text buffer. That cannot represent an
image with an upload state, a poll with options, or a stable identity per node
— so v2 makes a document an **ordered list of blocks**, where the text blocks
are exactly the v1 engine.

## Compatibility rule (non-negotiable)

A document containing **only text blocks** MUST serialize to byte-identical
HTML to what v1 produces. Existing `body_html` columns keep working, and
`WysiwygEditor::open($html)` keeps accepting v1 content unchanged. Every case
in `tests/native/*/HtmlCoderTests` stays green.

## Structure

```
Document := { version: 2, blocks: [Block, ...] }
Block    := { id: string, type: string, ... }
```

`id` is a short opaque string, stable for a block's lifetime. It exists so
hosts can map upload progress, comments or analytics to a specific block. It is
NOT serialized to HTML (HTML has nowhere to put it without polluting the
output) — it survives only in JSON.

### Text blocks

`p` · `h1` · `h2` · `h3` · `ul` · `ol` · `blockquote`

```json
{ "id": "b1", "type": "p", "runs": [ { "text": "Hi ", "marks": {} },
                                     { "text": "there", "marks": { "bold": true } } ] }
```

`runs` and `marks` are the v1 model verbatim: `link`, `color`, `highlight`,
`bold`, `italic`, `underline`, `strike`, `code`. Serialization order and the
merge/grouping rules are unchanged — see the HTML contract in the README.

### Media and interactive blocks

| Type | Fields | HTML |
| --- | --- | --- |
| `image` | `src`, `alt`, `caption?`, `width?`, `height?`, `uploadId?` | `<figure><img src alt><figcaption>…</figcaption></figure>` |
| `video` | `src`, `poster?`, `caption?`, `uploadId?` | `<figure><video src poster controls></video><figcaption>…</figcaption></figure>` |
| `file` | `src`, `name`, `size?`, `mime?`, `uploadId?` | `<p><a href="src" download>name</a></p>` |
| `embed` | `url`, `provider?`, `html?` | `<figure data-embed="url"></figure>` |
| `poll` | `question`, `options: [{id, label}]`, `multiple?`, `closesAt?` | `<figure data-poll="…json…"></figure>` |
| `divider` | — | `<hr>` |

**Lossy by design.** HTML cannot carry `uploadId`, poll option ids, or block
ids. Exporting to HTML drops them; exporting to JSON keeps everything. Hosts
that need full fidelity store JSON and treat HTML as a rendering format. This
is stated loudly rather than hidden, because silently losing a poll's data on
save would be a serious bug.

**Re-importing HTML** produces blocks without ids (fresh ids are minted) and
without upload state — a poll survives via its `data-poll` payload, an embed
via `data-embed`.

## Upload contract

The editor does **not** upload anything. It has no network layer, no queue and
no retry policy — those belong to the host application, which already has
auth, endpoints and error handling.

When the user picks media, the editor:

1. inserts the block immediately with a local `src` and a fresh `uploadId`,
2. emits `MediaAttached { uploadId, localPath, mime, blockId }`,
3. renders that block in a pending state until told otherwise.

The host uploads however it likes, then calls back:

- `WysiwygEditor::uploadProgress($uploadId, $fraction)`
- `WysiwygEditor::uploadCompleted($uploadId, $remoteUrl)`
- `WysiwygEditor::uploadFailed($uploadId, $message)`

This keeps the plugin modular: the editor owns presentation and document
state, the app owns the network. It also means background uploads, retries and
offline queues are the host's existing infrastructure rather than a second
implementation living inside an editor.

## Auto-theming

The editor derives its palette and typography from the host's theme tokens
(`Nativephp\NativeUi\Theme::all()`) and re-derives them on `AppearanceChanged`,
instead of requiring the four explicit hex values v1 asked for.

The v1 `theme` option stays supported and takes precedence, so existing
integrations keep their look. Precedence: explicit `theme` option → host theme
tokens → the plugin's system-adaptive defaults.

## Validation

`validation` accepts declarative rules, checked natively and surfaced inline
without a round-trip to PHP:

```php
'validation' => [
    'minWords' => 50,
    'maxWords' => 2000,
    'requiredBlocks' => ['image'],   // must contain at least one image
    'maxImages' => 10,
]
```

Save is blocked while a rule fails, with the failing rule shown in the editor.

## Counts

`counts` toggles a live readout: `characters`, `words`, `readingTime`. Words
are counted on the plain-text rendition (marks stripped, markers excluded), so
a bulleted list does not inflate the count with bullets.

## Not in this model, deliberately

Drafts, scheduled publishing, auto-save persistence and background upload
queues are **host application concerns**, not editor features. The editor
gives you the seams — an `onChange` event to debounce into auto-save, and the
upload contract above — and stays out of your database and your scheduler.
Owning those would turn a modular editor into a CMS.
