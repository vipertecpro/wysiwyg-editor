<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Dispatched by the native editor when the user taps Save.
 *
 * The native side serializes the edited document and sends this event; its
 * public properties are populated by name from the native payload, so a
 * `#[On(ContentSaved::class)]` handler can type-hint `string $html` (and
 * optionally `string $text` / `?string $id`) and receive them directly.
 *
 * @property string $html The edited content as clean, normalised HTML.
 * @property string $text The same content as plain text (marks stripped, one line per block).
 * @property string $json The FIDELITY format — the block document including
 *                        block ids, poll options and upload state, none of
 *                        which HTML can carry. Store this when you need
 *                        loss-free round-trips; store `$html` to render.
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
