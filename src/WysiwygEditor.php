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
        'image', 'video', 'file',
        'clearFormat',
    ];

    /** Toolbar tools that ask the HOST for media rather than formatting text. */
    public const INSERT_TOOLS = ['image', 'video', 'file'];

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
     * Live readouts the editor can show beneath the content.
     *
     *  - characters: plain-text character count
     *  - words:      whitespace-delimited word count
     *  - readingTime: minutes at 200 wpm, rounded up (minimum 1)
     */
    public const AVAILABLE_COUNTS = ['characters', 'words', 'readingTime'];

    /**
     * Declarative rules checked natively before a save is allowed.
     *
     *  - minWords / maxWords: on the plain-text rendition
     *  - requiredBlocks:      block types the document must contain, e.g. ['image']
     *  - maxImages:           cap on image blocks
     */
    public const VALIDATION_RULES = ['minWords', 'maxWords', 'requiredBlocks', 'maxImages'];

    /**
     * Every user-visible string in the editor, with its English default.
     *
     * Pass `strings` to translate the editor into your app's locale — the
     * plugin has no locale files of its own on purpose, because the host
     * already knows the user's language and its own translation workflow.
     *
     * `{n}` / `{max}` / `{type}` placeholders are substituted natively.
     *
     * @var array<string, string>
     */
    public const STRINGS = [
        'cancel' => 'Cancel',
        'save' => 'Save',
        'discardTitle' => 'Discard changes?',
        'discardMessage' => 'Your edits will be lost.',
        'keepEditing' => 'Keep Editing',
        'discard' => 'Discard',
        'linkTitle' => 'Add Link',
        'linkPlaceholder' => 'https://example.com',
        'linkRemove' => 'Remove',
        'ok' => 'OK',
        'uploading' => 'Uploading…',
        'uploadFailed' => 'Upload failed',
        'cannotSaveTitle' => 'Cannot save yet',
        'countCharacters' => '{n} chars',
        'countWords' => '{n} words',
        'countReadingTime' => '{n} min',
        'ruleMinWords' => 'At least {max} words needed — you have {n}.',
        'ruleMaxWords' => 'At most {max} words allowed — you have {n}.',
        'ruleMaxImages' => 'At most {max} image(s) allowed — you have {n}.',
        'ruleRequiredBlock' => 'This needs at least one {type}.',
        // Bottom sheets
        'menuFormat' => 'Format',
        'menuInsert' => 'Insert',
        'sectionTextStyle' => 'Text style',
        'sectionLists' => 'Lists',
        'sectionFormat' => 'Formatting',
        'styleBody' => 'Body',
        'styleH1' => 'Heading 1',
        'styleH2' => 'Heading 2',
        'styleH3' => 'Heading 3',
        'styleQuote' => 'Quote',
        'toolBold' => 'Bold',
        'toolItalic' => 'Italic',
        'toolUnderline' => 'Underline',
        'toolStrikethrough' => 'Strikethrough',
        'toolCode' => 'Code',
        'toolTextColor' => 'Text color',
        'toolHighlight' => 'Highlight',
        'toolClearFormat' => 'Clear formatting',
        'toolBulletList' => 'Bulleted list',
        'toolOrderedList' => 'Numbered list',
        'toolLink' => 'Link',
        'toolImage' => 'Photo',
        'toolVideo' => 'Video',
        'toolFile' => 'File',
    ];

    /**
     * Editing density. Values are points on iOS and dp on Android, so the two
     * platforms lay out the same — until now Android used raw pixels here and
     * was measurably tighter than iOS on the same document.
     *
     * `comfortable` reproduces what the editor looked like before the option
     * existed, so nothing shifts for an app that does not set it.
     *
     * @var array<string, array{horizontal: int, vertical: int, paragraph: int}>
     */
    public const SPACING_SCALES = [
        'compact' => ['horizontal' => 12, 'vertical' => 8, 'paragraph' => 4],
        'comfortable' => ['horizontal' => 16, 'vertical' => 12, 'paragraph' => 6],
        'roomy' => ['horizontal' => 20, 'vertical' => 18, 'paragraph' => 10],
    ];

    /**
     * Typography defaults. The heading ramp is DERIVED from `fontSize` natively
     * using fixed multipliers (1.75 / 1.375 / 1.125), so a host that wants
     * bigger text sets one number instead of four — and the default 16 gives
     * back exactly the 28 / 22 / 18 ramp the editor already used.
     *
     * `fontFamily` is empty by default, meaning the platform's system font. It
     * is filled in from the host application's own theme when that theme names
     * a font, so the editor matches the app without being told to.
     *
     * @var array{fontFamily: string, fontSize: int, lineHeight: float}
     */
    public const TYPOGRAPHY = [
        'fontFamily' => '',
        'fontSize' => 16,
        'lineHeight' => 1.15,
    ];

    /**
     * Which string key labels each tool in a bottom sheet.
     *
     * Headings and quote read as text STYLES rather than as tools, so they use
     * the `style*` keys and sit in their own section. Declared here rather than
     * as a switch inside each native file, so the two platforms cannot drift.
     *
     * @var array<string, string>
     */
    public const TOOL_LABEL_KEYS = [
        'bold' => 'toolBold',
        'italic' => 'toolItalic',
        'underline' => 'toolUnderline',
        'strikethrough' => 'toolStrikethrough',
        'h1' => 'styleH1',
        'h2' => 'styleH2',
        'h3' => 'styleH3',
        'bulletList' => 'toolBulletList',
        'orderedList' => 'toolOrderedList',
        'blockquote' => 'styleQuote',
        'link' => 'toolLink',
        'code' => 'toolCode',
        'textColor' => 'toolTextColor',
        'highlight' => 'toolHighlight',
        'image' => 'toolImage',
        'video' => 'toolVideo',
        'file' => 'toolFile',
        'clearFormat' => 'toolClearFormat',
    ];

    /**
     * How the tools are presented.
     *
     *  - toolbar: every tool in one horizontally scrolling bar (the default,
     *             and the right choice for a small toolbar like `comment`)
     *  - sheet:   a compact bar — undo/redo, bold/italic, then Format and
     *             Insert buttons that open bottom sheets holding the rest.
     *             Fewer taps to reach a tool that is not the first four, and
     *             nothing hides off the edge of the screen.
     *
     * @var list<string>
     */
    public const MENU_MODES = ['toolbar', 'sheet'];

    /**
     * How the host application's NativeUI theme tokens map onto the editor's
     * four surfaces. Consulted per colour scheme so the editor follows the app
     * into dark mode without the developer configuring anything.
     *
     * @var array<string, list<string>>  editor key => host tokens, best first
     */
    protected const HOST_TOKEN_MAP = [
        'background' => ['background', 'surface'],
        'text' => ['on-background', 'on-surface'],
        'accent' => ['primary', 'accent'],
        'highlight' => ['primary', 'accent', 'secondary'],
    ];

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
     *     counts?: list<string>,
     *     validation?: array<string, mixed>,
     *     strings?: array<string, string>,
     *     changeDebounce?: int,
     *     haptics?: bool,
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
     * Convert a saved document to Markdown.
     *
     * Takes the `$json` from {@see Events\ContentSaved}, not the HTML — JSON
     * is the canonical form, so the export does not inherit a loss that
     * already happened. See {@see Markdown} for what Markdown cannot carry.
     */
    public function toMarkdown(string $json): string
    {
        return Markdown::fromJson($json);
    }

    /**
     * Insert a media block at the caret.
     *
     * Call this after your app has picked (and optionally edited) the media —
     * see {@see \Vipertecpro\WysiwygEditor\Events\MediaRequested}. The block
     * appears immediately using `localPath`, so the user sees it before any
     * upload finishes.
     *
     * @param  string  $kind  `image`, `video` or `file`.
     * @param  array{
     *     localPath?: string,
     *     src?: string,
     *     alt?: string,
     *     caption?: string,
     *     name?: string,
     *     mime?: string,
     *     poster?: string,
     *     uploadId?: string
     * }  $attributes  `localPath` shows it now; `src` is the public URL once
     *                 uploaded. Pass an `uploadId` to correlate the upload
     *                 callbacks below — the editor shows a pending state until
     *                 one of them arrives.
     */
    public function insertMedia(string $kind, array $attributes = []): void
    {
        if (! in_array($kind, self::INSERT_TOOLS, true)) {
            throw new \InvalidArgumentException(
                "WysiwygEditor cannot insert \"{$kind}\" — insertable kinds are: "
                .implode(', ', self::INSERT_TOOLS).'.'
            );
        }

        $this->call('WysiwygEditor.InsertMedia', [
            'kind' => $kind,
            'attributes' => array_filter(
                $attributes,
                fn ($value) => is_string($value) && $value !== '',
            ),
        ]);
    }

    /** Report upload progress (0.0–1.0) for a block inserted with an uploadId. */
    public function uploadProgress(string $uploadId, float $fraction): void
    {
        $this->call('WysiwygEditor.UpdateUpload', [
            'uploadId' => $uploadId,
            'state' => 'progress',
            'fraction' => max(0.0, min(1.0, $fraction)),
        ]);
    }

    /** The upload finished: swap the block onto its public URL. */
    public function uploadCompleted(string $uploadId, string $url): void
    {
        $this->call('WysiwygEditor.UpdateUpload', [
            'uploadId' => $uploadId,
            'state' => 'completed',
            'src' => $url,
        ]);
    }

    /** The upload failed: the block stays on its local copy and shows the error. */
    public function uploadFailed(string $uploadId, string $message = ''): void
    {
        $this->call('WysiwygEditor.UpdateUpload', [
            'uploadId' => $uploadId,
            'state' => 'failed',
            'message' => $message,
        ]);
    }

    /** Bridge call, skipped outside a native runtime so tests stay pure. */
    protected function call(string $method, array $payload): void
    {
        if (! function_exists('nativephp_call')) {
            return;
        }

        nativephp_call($method, json_encode($payload));
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
            'counts' => $this->resolveCounts($options['counts'] ?? []),
            'validation' => $this->resolveValidation($options['validation'] ?? []),
            'strings' => $this->resolveStrings($options['strings'] ?? []),
            // 0 = off. When set, the editor emits ContentChanged this many
            // milliseconds after the user stops typing — the auto-save seam.
            'changeDebounce' => max(0, (int) ($options['changeDebounce'] ?? 0)),
            'haptics' => (bool) ($options['haptics'] ?? true),
            'menu' => $this->resolveMenu($options['menu'] ?? null),
            'typography' => $this->resolveTypography($options['typography'] ?? []),
            'spacing' => $this->resolveSpacing($options['spacing'] ?? null),
            // Explicit overrides win; the two scheme maps below are the host
            // app's own theme, so an unconfigured editor still looks native.
            'theme' => $this->resolveTheme($options['theme'] ?? []),
            'themeLight' => $this->hostTheme('light'),
            'themeDark' => $this->hostTheme('dark'),
            'id' => $options['id'] ?? null,
        ];
    }

    /**
     * Type settings, with the host application's font adopted when the caller
     * does not name one.
     *
     * @param  array<string, mixed>  $typography
     * @return array{fontFamily: string, fontSize: int, lineHeight: float}
     */
    protected function resolveTypography(array $typography): array
    {
        $family = (string) ($typography['fontFamily'] ?? '');

        if ($family === '') {
            $family = $this->hostFontFamily();
        }

        $size = (int) ($typography['fontSize'] ?? self::TYPOGRAPHY['fontSize']);
        $lineHeight = (float) ($typography['lineHeight'] ?? self::TYPOGRAPHY['lineHeight']);

        return [
            'fontFamily' => $family,
            // Clamped to a range a text engine can actually lay out. Outside
            // it the heading ramp stops being readable rather than becoming
            // dramatic, so silently accepting 200 would help nobody.
            'fontSize' => max(10, min(32, $size)),
            'lineHeight' => max(1.0, min(2.0, $lineHeight)),
        ];
    }

    /**
     * The host application's font, if its theme names one. NativeUI carries
     * `fonts.default` (preferred) and a literal `font-family` token.
     */
    protected function hostFontFamily(): string
    {
        if (! class_exists(\Nativephp\NativeUi\Theme::class)) {
            return '';
        }

        $tokens = \Nativephp\NativeUi\Theme::all();

        foreach ([$tokens['fonts']['default'] ?? null, $tokens['font-family'] ?? null] as $candidate) {
            if (is_string($candidate) && trim($candidate) !== '') {
                return trim($candidate);
            }
        }

        return '';
    }

    /**
     * Editing density. NativeUI has no spacing token to read, so unlike
     * colours and the font this is a choice the host makes rather than
     * something adopted — stated plainly rather than guessed at.
     */
    protected function resolveSpacing(mixed $spacing): string
    {
        return isset(self::SPACING_SCALES[$spacing]) ? $spacing : 'comfortable';
    }

    /**
     * Presentation mode for the tools. Anything unrecognised falls back to the
     * scrolling toolbar, which can show every tool whatever the config says.
     */
    protected function resolveMenu(mixed $menu): string
    {
        return in_array($menu, self::MENU_MODES, true) ? $menu : 'toolbar';
    }

    /**
     * Keep only known count readouts, in the documented order.
     *
     * @param  list<string>  $counts
     * @return list<string>
     */
    protected function resolveCounts(array $counts): array
    {
        return array_values(array_intersect(self::AVAILABLE_COUNTS, $counts));
    }

    /**
     * Merge caller translations over the English defaults, dropping unknown
     * keys so a typo fails visibly rather than silently doing nothing.
     *
     * @param  array<string, string>  $strings
     * @return array<string, string>
     */
    protected function resolveStrings(array $strings): array
    {
        $clean = self::STRINGS;

        foreach ($strings as $key => $value) {
            if (isset($clean[$key]) && is_string($value) && $value !== '') {
                $clean[$key] = $value;
            }
        }

        return $clean;
    }

    /**
     * Keep only known validation rules, coerced to the shapes the native side
     * expects. Unknown rules are dropped rather than silently ignored later.
     *
     * @param  array<string, mixed>  $rules
     * @return array<string, mixed>
     */
    protected function resolveValidation(array $rules): array
    {
        $clean = [];

        foreach (self::VALIDATION_RULES as $rule) {
            if (! array_key_exists($rule, $rules)) {
                continue;
            }

            if ($rule === 'requiredBlocks') {
                $types = array_values(array_filter((array) $rules[$rule], 'is_string'));

                if ($types !== []) {
                    $clean[$rule] = $types;
                }

                continue;
            }

            $clean[$rule] = max(0, (int) $rules[$rule]);
        }

        return $clean;
    }

    /**
     * Derive the editor's palette from the HOST application's NativeUI theme
     * tokens, so it adopts the app's colours without the developer restating
     * them. Returns an empty array when NativeUI isn't installed or has no
     * tokens for the scheme — the native side then falls back to its own
     * system-adaptive defaults, exactly as before.
     *
     * @return array<string, string>
     */
    protected function hostTheme(string $scheme): array
    {
        if (! class_exists(\Nativephp\NativeUi\Theme::class)) {
            return [];
        }

        $tokens = \Nativephp\NativeUi\Theme::all()[$scheme] ?? [];

        if (! is_array($tokens) || $tokens === []) {
            return [];
        }

        $resolved = [];

        foreach (self::HOST_TOKEN_MAP as $key => $candidates) {
            foreach ($candidates as $token) {
                $value = $tokens[$token] ?? null;

                if (is_string($value) && preg_match('/^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/', $value, $m)) {
                    $resolved[$key] = '#'.$m[1];

                    break;
                }
            }
        }

        return $resolved;
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
