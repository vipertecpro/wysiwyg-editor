<?php

namespace Vipertecpro\WysiwygEditor\Events;

use Illuminate\Foundation\Events\Dispatchable;
use Illuminate\Queue\SerializesModels;

/**
 * Dispatched when the user taps an insert tool (image / video / file) in the
 * editor toolbar.
 *
 * The editor deliberately ships NO picker. It tells you what the user asked
 * for and waits; your app picks the media with whatever it already uses —
 * `nativephp/mobile-camera`, a file picker, your own screen — optionally edits
 * it (e.g. `vipertecpro/image-cropper`), then calls
 * {@see \Vipertecpro\WysiwygEditor\WysiwygEditor::insertMedia()}.
 *
 * That keeps the plugin dependency-free and lets each app reuse the
 * permissions, auth and upload infrastructure it already has.
 *
 * @property string $kind One of `image`, `video`, `file`.
 * @property ?string $id The correlation id passed to WysiwygEditor::open(), if any.
 */
class MediaRequested
{
    use Dispatchable, SerializesModels;

    public function __construct(
        public string $kind,
        public ?string $id = null,
    ) {}
}
