<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * The user backed out of a document with something written, and chose to keep
 * it rather than throw it away.
 *
 * The editor has no database and should not grow one, so it hands the document
 * over exactly as {@see ContentSaved} would and steps back. Where a draft
 * lives — a table, a cache key, a file, your API — is the application's
 * business, and so is whether re-opening it is a different flow from editing
 * a published post.
 *
 * Only fires when the editor was opened with `cancelMode => 'draft'`.
 */
class DraftRequested
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public string $html,
        public string $text,
        /** The canonical form — hand this back to `open()` to resume. */
        public string $json,
        public ?string $id = null,
    ) {}
}
