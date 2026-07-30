<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Dispatched by the native editor when the user taps Save.
 *
 * A `#[On(ContentSaved::class)]` handler can type-hint any of the properties
 * by name and receive them directly.
 *
 * ─────────────────────────────────────────────────────────────────────────
 *  WHAT YOU ACTUALLY RECEIVE
 * ─────────────────────────────────────────────────────────────────────────
 *
 * The same document arrives three ways. They are not alternatives to pick
 * between — each answers a different question, and a real client usually
 * sends more than one.
 *
 * A post with some words, a photo still uploading, a photo already uploaded
 * and a poll produces exactly this:
 *
 * `$html` — to RENDER. Safe to publish as-is:
 *
 *     <p>Shipping <strong>today</strong>.</p>
 *     <figure data-pending="u-1"><img alt="The harbour"></figure>
 *     <figure><img src="https://cdn.example.com/a.jpg" alt=""></figure>
 *     <figure data-poll="{…}"></figure>
 *
 * Note what is NOT in there: the photo still uploading has no `src` at all.
 * A device path must never leak into published markup, so the editor omits
 * it and marks the figure `data-pending` instead.
 *
 * `$text` — to SEARCH and to excerpt. Marks stripped, one line per block:
 *
 *     Shipping today.
 *     The harbour
 *
 *     Ship it?
 *
 * `$json` — CANONICAL. The only form that carries a device path, a poll's
 * option ids, upload state and the background a post was written on:
 *
 *     {"version":2,"background":"sunset","blocks":[
 *       {"id":"","type":"p","runs":[
 *         {"text":"Shipping ","marks":{}},
 *         {"text":"today","marks":{"bold":true}},
 *         {"text":".","marks":{}}]},
 *       {"id":"","type":"image","localPath":"/var/mobile/…/IMG_0042.HEIC",
 *        "alt":"The harbour","uploadId":"u-1"},
 *       {"id":"","type":"image","src":"https://cdn.example.com/a.jpg"},
 *       {"id":"","type":"poll","question":"Ship it?","durationMinutes":"1440",
 *        "options":[{"id":"o1","label":"Yes"},{"id":"o2","label":"No"}]}]}
 *
 * ─────────────────────────────────────────────────────────────────────────
 *  SAVING TEXT AND ATTACHMENTS SEPARATELY
 * ─────────────────────────────────────────────────────────────────────────
 *
 * Most servers want the prose in one table and the files in another. The
 * media blocks are top-level entries in `blocks`, so splitting them is a
 * filter — see {@see \Vipertecpro\WysiwygEditor\WysiwygEditor::attachments()},
 * which does exactly this:
 *
 *     #[On(ContentSaved::class)]
 *     public function onSaved(string $html, string $text, string $json): void
 *     {
 *         $post = Http::withToken($token)
 *             ->post('https://api.example.com/posts', [
 *                 'html' => $html,   // to render
 *                 'text' => $text,   // to search
 *                 'json' => $json,   // to re-open for editing
 *             ])->json();
 *
 *         foreach (WysiwygEditor::attachments($json) as $file) {
 *             // A file the user picked and the editor has NOT uploaded —
 *             // uploading is yours to do, because the endpoint is yours.
 *             Http::withToken($token)
 *                 ->attach('file', file_get_contents($file['path']), basename($file['path']))
 *                 ->post("https://api.example.com/posts/{$post['id']}/media", [
 *                     'kind' => $file['kind'],   // image | video | file
 *                     'alt' => $file['alt'],
 *                 ]);
 *         }
 *     }
 *
 * Store `$json` if the post should ever be EDITABLE again — re-opening from
 * `$html` alone comes back without any photo whose upload had not finished,
 * and without the colour the post was written on.
 *
 * @property string $html The edited content as clean, normalised HTML. Never
 *                        contains a device path.
 * @property string $text The same content as plain text — marks stripped, one
 *                        line per block.
 * @property string $json The canonical document: block ids, poll options,
 *                        upload state, local file paths and the post
 *                        background, none of which HTML can carry.
 * @property ?string $id The correlation id passed to WysiwygEditor::open(), if any.
 */
class ContentSaved
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public string $html,
        public string $text = '',
        public string $json = '',
        public ?string $id = null,
    ) {}
}
