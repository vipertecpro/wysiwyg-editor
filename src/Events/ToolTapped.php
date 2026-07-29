<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * The user tapped one of the host's own toolbar buttons.
 *
 * The editor cannot know what a GIF picker, a location tagger or a scheduler
 * should do — those are the application's features, backed by its data and its
 * services. So the editor draws the button and reports the tap; what happens
 * next is entirely yours, and you can put the result back into the document
 * with {@see \Vipertecpro\WysiwygEditor\WysiwygEditor::insertMedia()} or leave
 * the document alone entirely.
 */
class ToolTapped
{
    use Dispatchable, SerializesModels;

    public function __construct(
        /** The `id` the host gave this button. */
        public string $tool,
        /** Echoed from the `id` the editor was opened with. */
        public ?string $id = null,
    ) {}
}
