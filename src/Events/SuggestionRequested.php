<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;
use Vipertecpro\WysiwygEditor\WysiwygEditor;

/**
 * The user typed a trigger character and is writing a query after it.
 *
 * Fires on every keystroke of the query, so answer it cheaply — debounce, cap
 * the result count, and expect to be asked again a moment later.
 *
 * The editor has no directory of people and no index of tags, and should not
 * grow either: who is mentionable depends on who is signed in, who they are
 * connected to, and what your API will tell them. So the editor spots the
 * trigger, collects the query, and waits for
 * {@see WysiwygEditor::suggestions()}.
 */
class SuggestionRequested
{
    use Dispatchable, SerializesModels;

    public function __construct(
        /** What the trigger means — `mention`, `hashtag`, or your own. */
        public string $kind,
        /** The single character that started it. */
        public string $trigger,
        /** Everything typed after the trigger, which may be empty. */
        public string $query,
        /** Echoed from the `id` the editor was opened with. */
        public ?string $id = null,
    ) {}
}
