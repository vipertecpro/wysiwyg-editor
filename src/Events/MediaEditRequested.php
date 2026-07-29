<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Native\Mobile\Events\NativeEvent;

/**
 * The user tapped edit on a piece of attached media.
 *
 * The editor does not crop, rotate or filter — that is a picker's job, and the
 * host already chose which one it uses. This says WHICH block the user wants
 * to work on; the host re-opens its own editor and calls
 * {@see \Vipertecpro\WysiwygEditor\WysiwygEditor::insertMedia()} again with the
 * same `uploadId` to replace it.
 */
class MediaEditRequested extends NativeEvent
{
    public function __construct(
        /** `image`, `video` or `file`. */
        public string $kind,
        /** The block's upload id, which is how the host identifies it. */
        public string $uploadId,
        /** Where the media currently lives — remote url or local path. */
        public string $source,
        /** Echoed from the `id` the editor was opened with. */
        public ?string $id = null,
    ) {}
}
