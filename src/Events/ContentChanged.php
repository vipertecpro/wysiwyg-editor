<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Dispatched while the user is editing, debounced by `changeDebounce` ms.
 *
 * This is the **auto-save seam**. The editor deliberately does not own drafts,
 * scheduling or persistence — it tells you the document changed and settled,
 * and your app decides what that means:
 *
 *     WysiwygEditor::open($note->body, ['changeDebounce' => 1500]);
 *
 *     #[On(ContentChanged::class)]
 *     public function onChanged(string $html, string $json): void
 *     {
 *         $this->note->update(['body_html' => $html, 'body_json' => $json]);
 *     }
 *
 * Off by default: `changeDebounce` of 0 means the event never fires, so apps
 * that don't want it pay nothing.
 *
 * @property string $html The document so far, as normalised HTML.
 * @property string $text The plain-text rendition.
 * @property string $json The fidelity format (block ids, poll options, upload state).
 * @property ?string $id The correlation id passed to WysiwygEditor::open(), if any.
 */
class ContentChanged
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public string $html,
        public string $text = '',
        public string $json = '',
        public ?string $id = null,
    ) {}
}
