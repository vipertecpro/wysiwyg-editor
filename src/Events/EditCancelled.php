<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Dispatched when the user leaves the editor without saving — Cancel, the
 * system back gesture, or confirming the discard-changes prompt.
 *
 * @property ?string $id The correlation id passed to WysiwygEditor::open(), if any.
 */
class EditCancelled
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public ?string $id = null,
    ) {}
}
