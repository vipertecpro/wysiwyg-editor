<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Native\Mobile\Events\NativeEvent;

/**
 * The user tapped one of the host's own rows in the composer.
 *
 * The editor draws the row and reports the tap; what happens next is entirely
 * the application's business — open a people picker, ask for a location,
 * change who may reply. Update the row afterwards with
 * {@see \Vipertecpro\WysiwygEditor\WysiwygEditor::setAccessory()} so it shows
 * the choice that was made.
 */
class AccessoryTapped extends NativeEvent
{
    public function __construct(
        /** The `id` the host gave this row. */
        public string $accessory,
        /** Echoed from the `id` the editor was opened with. */
        public ?string $id = null,
    ) {}
}
