<?php

namespace Vipertecpro\WysiwygEditor;

use Vipertecpro\WysiwygEditor\Events\ContentSaved;
use Vipertecpro\WysiwygEditor\Events\EditCancelled;

/**
 * PHP entry point for the native WYSIWYG editor.
 *
 * {@see open()} hands the current HTML to the native side, which presents a
 * full-screen, config-driven rich text editor (SwiftUI-hosted UITextView on
 * iOS, Compose-hosted EditText on Android) with a formatting toolbar pinned
 * above the keyboard. The user writes and formats, and on Save the edited
 * content is reported back **asynchronously via an event** as clean HTML plus
 * a plain-text rendition.
 *
 * The editor is configurable so one plugin covers many use cases — full blog
 * composer, minimal comment box, quick note, etc. — rather than a
 * one-size-fits-all editor.
 *
 *     use Vipertecpro\WysiwygEditor\Facades\WysiwygEditor;
 *
 *     WysiwygEditor::open($note->body, ['title' => 'Edit note']);        // full toolbar
 *     WysiwygEditor::open('', ['preset' => 'comment', 'maxLength' => 500]);
 *     WysiwygEditor::open($html, ['toolbar' => ['bold', 'italic', 'link']]);
 *
 * Handle the result in a NativeComponent with #[On(ContentSaved::class)] /
 * #[On(EditCancelled::class)].
 */
class WysiwygEditor
{
    /**
     * Every formatting tool the native toolbar can offer, in the order the
     * "full" preset shows them. A `toolbar` option (or preset) picks an
     * ordered subset of these; unknown entries are dropped.
     *
     *  - Inline marks: bold, italic, underline, strikethrough, code, link,
     *    textColor, highlight
     *  - Block formats: h1, h2, h3, bulletList, orderedList, blockquote
     *  - Utility: clearFormat (strip all marks from the selection)
     *
     * Undo / Redo are always present in the editor and are not toolbar keys.
     */
    public const AVAILABLE_TOOLS = [
        'bold', 'italic', 'underline', 'strikethrough',
        'h1', 'h2', 'h3',
        'bulletList', 'orderedList', 'blockquote',
        'link', 'code', 'textColor', 'highlight',
        'clearFormat',
    ];

    /**
     * Built-in toolbar presets → ordered tool lists, so common editors are a
     * one-liner. An explicit `toolbar` option always wins over a preset.
     *
     * @var array<string, list<string>>
     */
    public const TOOLBAR_PRESETS = [
        'full' => self::AVAILABLE_TOOLS,
        'basic' => ['bold', 'italic', 'underline', 'strikethrough', 'bulletList', 'orderedList', 'link'],
        'comment' => ['bold', 'italic', 'link'],
        'note' => ['bold', 'italic', 'underline', 'h1', 'h2', 'bulletList', 'orderedList'],
    ];

    /**
     * Theme keys the editor accepts, all optional hex colors (#RGB / #RRGGBB /
     * #RRGGBBAA). Any key omitted falls back to the editor's built-in
     * system-adaptive light/dark default — pass only what you want to override.
     *
     *  - background: editor screen background
     *  - text:       body text, titles and inactive toolbar icons
     *  - accent:     the Save button
     *  - highlight:  active states (toggled toolbar buttons, selection)
     */
    public const THEME_KEYS = ['background', 'text', 'accent', 'highlight'];

    /**
     * Open the full-screen native editor.
     *
     * @param  string  $html  The current content as HTML (may be ''). Only the
     *                        tags in the supported set are rendered; unknown
     *                        tags are ignored but their text is kept. See the
     *                        README's "HTML contract" for the exact tag set.
     * @param  array{
     *     preset?: string,
     *     toolbar?: list<string>,
     *     title?: string,
     *     placeholder?: string,
     *     maxLength?: int,
     *     theme?: array<string, string>,
     *     id?: string|null
     * }  $options  Editor configuration. `preset` picks a built-in toolbar
     *              (full/basic/comment/note); an explicit `toolbar` list
     *              overrides it. `title` is the top-bar heading. `placeholder`
     *              shows while the editor is empty. `maxLength` caps the
     *              PLAIN-TEXT length (0 = unlimited) with a live counter.
     *              `theme` recolours the editor to match YOUR app (see
     *              {@see THEME_KEYS}) — omitted keys keep the system-adaptive
     *              defaults. `id` is echoed back on the result event to
     *              correlate concurrent editors.
     *
     * Fires {@see ContentSaved} on save and {@see EditCancelled} when the user
     * backs out (a discard-changes confirm guards non-empty edits).
     */
    public function open(string $html = '', array $options = []): void
    {
        if (! function_exists('nativephp_call')) {
            return;
        }

        nativephp_call('WysiwygEditor.Open', json_encode($this->resolveConfig($html, $options)));
    }

    /**
     * Merge caller options with the chosen preset and sane defaults into the
     * flat config the native side consumes.
     *
     * @return array{content: string, toolbar: list<string>, title: string, placeholder: string, maxLength: int, theme: array<string, string>, id: string|null}
     */
    protected function resolveConfig(string $html, array $options): array
    {
        return [
            'content' => $html,
            'toolbar' => $this->resolveToolbar($options),
            'title' => (string) ($options['title'] ?? ''),
            'placeholder' => (string) ($options['placeholder'] ?? ''),
            'maxLength' => max(0, (int) ($options['maxLength'] ?? 0)),
            'theme' => $this->resolveTheme($options['theme'] ?? []),
            'id' => $options['id'] ?? null,
        ];
    }

    /**
     * Resolve the ordered tool list: an explicit `toolbar` wins, else the
     * `preset`, else the full set. Unknown tools are dropped; an empty result
     * (all entries unknown) falls back to the full set rather than shipping a
     * toolbar with no buttons.
     *
     * @param  array{preset?: string, toolbar?: list<string>}  $options
     * @return list<string>
     */
    protected function resolveToolbar(array $options): array
    {
        $requested = $options['toolbar']
            ?? self::TOOLBAR_PRESETS[$options['preset'] ?? '']
            ?? self::TOOLBAR_PRESETS['full'];

        $tools = array_values(array_unique(array_intersect(
            $requested,
            self::AVAILABLE_TOOLS,
        )));

        return $tools === [] ? self::TOOLBAR_PRESETS['full'] : $tools;
    }

    /**
     * Keep only known theme keys holding valid hex colors, normalised with a
     * leading '#'. Unknown keys and malformed values are dropped — the native
     * side falls back to its adaptive default for anything missing.
     *
     * @param  array<string, string>  $theme
     * @return array<string, string>
     */
    protected function resolveTheme(array $theme): array
    {
        $clean = [];

        foreach (self::THEME_KEYS as $key) {
            $value = $theme[$key] ?? null;

            if (is_string($value) && preg_match('/^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/', $value, $m)) {
                $clean[$key] = '#'.$m[1];
            }
        }

        return $clean;
    }
}
