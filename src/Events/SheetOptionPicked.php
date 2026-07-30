<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;
use Vipertecpro\WysiwygEditor\WysiwygEditor;

/**
 * The user chose something from one of the host's own sheets.
 *
 * The editor presented the sheet because it owns the screen and a sheet the
 * host drew would open behind it — but the options were the host's, and so is
 * what they mean. Change the control that opened it with
 * {@see WysiwygEditor::setAccessory()} so it shows
 * the choice, and do whatever the choice actually implies.
 */
class SheetOptionPicked
{
    use Dispatchable, SerializesModels;

    public function __construct(
        /** The `id` the host gave this sheet. */
        public string $sheet,
        /** The `id` of the option that was picked. */
        public string $option,
        /** Echoed from the `id` the editor was opened with. */
        public ?string $id = null,
    ) {}
}
