<?php

namespace Vipertecpro\WysiwygEditor;

use Nativephp\NativeUi\Theme;
use Vipertecpro\WysiwygEditor\Events\ContentSaved;
use Vipertecpro\WysiwygEditor\Events\EditCancelled;
use Vipertecpro\WysiwygEditor\Events\MediaRequested;

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
        'bulletList', 'orderedList', 'checklist', 'blockquote',
        'link', 'code', 'textColor', 'highlight',
        'image', 'camera', 'video', 'file',
        'poll', 'divider', 'embed',
        'clearFormat',
    ];

    /** Toolbar tools that ask the HOST for media rather than formatting text. */
    public const INSERT_TOOLS = ['image', 'camera', 'video', 'file'];

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
        'note' => ['bold', 'italic', 'underline', 'h1', 'h2', 'bulletList', 'orderedList', 'checklist'],
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
        'toolChecklist' => 'Checklist',
        'toolOrderedList' => 'Numbered list',
        'toolLink' => 'Link',
        'toolImage' => 'Photo',
        'toolCamera' => 'Camera',
        'toolVideo' => 'Video',
        'toolFile' => 'File',
        'toolPoll' => 'Poll',
        'toolDivider' => 'Divider',
        'toolEmbed' => 'Embed',
        // Media strip
        'altBadge' => '+ALT',
        'altTitle' => 'Description',
        'altPlaceholder' => 'Describe this for people who cannot see it',
        'altSave' => 'Done',
        'removeMedia' => 'Remove',
        // Backing out with something written
        'draftTitle' => 'Save post?',
        'draftMessage' => 'You can finish it later.',
        'draftSave' => 'Save',
        'draftDelete' => 'Delete',
        // Poll composer, inline
        'pollLength' => 'Poll length',
        'pollDay1' => '1 day',
        'pollDays3' => '3 days',
        'pollDays7' => '7 days',
        'pollRemoveTitle' => 'Are you sure?',
        'pollRemoveMessage' => 'Removing the poll will discard what you have typed.',
        'pollRemove' => 'Remove',
        'embedTitle' => 'Embed a link',
        'embedPlaceholder' => 'https://youtube.com/watch?v=…',
        'embedAdd' => 'Embed',
        // Poll composer
        'pollTitle' => 'New poll',
        'pollEditTitle' => 'Edit poll',
        'pollQuestion' => 'Ask a question',
        'pollOption' => 'Option {n}',
        'pollAddOption' => 'Add option',
        'pollInsert' => 'Insert poll',
        'pollUpdate' => 'Update poll',
    ];

    /**
     * How many pieces of media one document may carry, unless the host says
     * otherwise. `0` means no limit.
     *
     * Four is not arbitrary — it is what every grid below is built to lay out,
     * and what X, Facebook and Instagram all landed on independently.
     */
    public const DEFAULT_MAX_MEDIA = 4;

    /**
     * Characters that start a lookup, and what each one means.
     *
     * Typing one of these begins a query: everything typed after it, up to a
     * space, is sent to the host as {@see Events\SuggestionRequested}. The host
     * searches whatever it likes — its own users, its own tags, an API — and
     * answers with {@see WysiwygEditor::suggestions()}. Picking one inserts a
     * LINKED entity, not just styled text, so the mention survives the round
     * trip and your renderer knows what it points at.
     *
     * The editor deliberately has no directory of people and no tag index. It
     * spots the trigger, collects the query and draws the answers.
     *
     * @var array<string, string> trigger => the `kind` reported with it
     */
    public const DEFAULT_TRIGGERS = ['@' => 'mention', '#' => 'hashtag'];

    /**
     * Extra toolbar buttons the HOST defines.
     *
     * The editor cannot know what a GIF picker, a location tagger or a
     * scheduler should do — those are the app's features. So it draws the
     * button and reports the tap through {@see Events\ToolTapped}, exactly as
     * it does for accessory rows.
     *
     * Each takes an `id` reported back on tap, an `icon` naming one of the
     * editor's glyphs, and an optional `label` for the sheet.
     *
     * @var list<string>
     */
    public const CUSTOM_TOOL_KEYS = ['id', 'icon', 'label', 'sheet'];

    /**
     * What a row offered in answer to a lookup may carry.
     *
     * `id` and `label` are what a MENTION needs — the pick becomes a link
     * carrying the id. `tool` is what a COMMAND needs: `/h1`, `/todo`,
     * `/divider`. A row naming a tool replaces the trigger and what was typed
     * after it, then runs the tool instead of inserting anything.
     *
     * That is the whole difference between the two. One pipeline spots the
     * trigger, asks you what matches and shows the answer; whether the pick
     * writes a name or changes the block is a property of the row.
     *
     * @var list<string>
     */
    public const SUGGESTION_KEYS = ['id', 'label', 'detail', 'avatar', 'icon', 'tool'];

    /**
     * Rows the HOST puts in the composer, under the media.
     *
     * The editor owns the whole screen, which means an app cannot put its own
     * controls beside the text — and every real composer has some. X has
     * "Tag people", "Add location" and a reply-audience row; LinkedIn has an
     * audience picker; Facebook has feeling, tag and location.
     *
     * None of those belong in an editor: they are the app's features, backed
     * by the app's data. So the editor draws the row and gets out of the way —
     * a tap emits {@see Events\AccessoryTapped} with the row's `id` and the
     * host does whatever it likes, including calling back to change the label.
     *
     * @var list<string> the keys each row accepts
     */
    public const ACCESSORY_KEYS = ['id', 'label', 'icon', 'value', 'placement', 'style', 'sheet'];

    /**
     * Where a host control sits.
     *
     * `row` is the strip under the media, which is where X and Facebook put
     * theirs. `header` is the top bar beside Close and Post, which is where
     * LinkedIn puts its audience picker — and a picker that decides who sees
     * the post belongs beside the button that sends it, not below the fold.
     *
     * @var list<string>
     */
    public const ACCESSORY_PLACEMENTS = ['row', 'header'];

    /**
     * How a host control draws.
     *
     * `row` is a full-width strip. `chip` is a label with a disclosure arrow,
     * which is what an audience picker looks like. `icon` is a bare glyph, for
     * something like a schedule button that needs no words.
     *
     * @var list<string>
     */
    public const ACCESSORY_STYLES = ['row', 'chip', 'icon'];

    /**
     * A sheet the HOST defines and the editor presents.
     *
     * The editor owns the screen — on iOS it owns its own window — so a sheet
     * the host draws would open behind it. That is not a detail an app should
     * have to work around, so the host DECLARES its sheet and the editor
     * presents it natively, over everything, and reports the choice through
     * {@see Events\SheetOptionPicked}.
     *
     * What the options mean stays the app's business. The editor draws a list
     * or a grid of them and gets out of the way.
     *
     * @var list<string>
     */
    public const SHEET_KEYS = ['id', 'title', 'style', 'options'];

    /**
     * `list` is rows with a label, an optional detail line and a tick on the
     * chosen one. `grid` is circular icon tiles, which is what a composer's
     * "+" opens onto.
     *
     * @var list<string>
     */
    public const SHEET_STYLES = ['list', 'grid'];

    /** @var list<string> */
    public const SHEET_OPTION_KEYS = ['id', 'label', 'detail', 'icon', 'selected'];

    /**
     * Which end of the bar the tools sit at.
     *
     * @var list<string>
     */
    public const TOOLBAR_ALIGNMENTS = ['leading', 'trailing'];

    /**
     * A colour a short post can be written ON.
     *
     * Facebook's signature composer move: a few words become a card — large,
     * centred, white on a gradient — and stop being a paragraph. That is a
     * property of the DOCUMENT, not of a run inside it, so it round-trips as
     * one and the host gets it back with everything else.
     *
     * `from` alone is a flat colour; adding `to` makes it a gradient.
     *
     * @var list<string>
     */
    public const BACKGROUND_KEYS = ['id', 'from', 'to', 'textColor'];

    /**
     * Past this many characters a background is dropped, the way Facebook
     * drops it: the point is a few words held large, and a paragraph set in
     * 28pt white on orange is unreadable.
     */
    public const BACKGROUND_MAX_LENGTH = 130;

    /**
     * Where the author's picture goes.
     *
     * `text` is beside what they are writing, which is what X and Facebook do.
     * `header` is the top bar, which is what LinkedIn does — it puts the
     * picture next to the audience picker, so the writing runs full width.
     *
     * @var list<string>
     */
    public const AVATAR_PLACEMENTS = ['text', 'header', 'none'];

    /**
     * How long a poll runs, offered in the composer.
     *
     * Labels are localizable like everything else; the VALUE is minutes,
     * because the editor does not own a clock — it records how long the author
     * chose and the host turns that into a closing time when it publishes.
     *
     * @var array<string, int> label key => minutes
     */
    public const POLL_DURATIONS = [
        'pollDay1' => 1440,
        'pollDays3' => 4320,
        'pollDays7' => 10080,
    ];

    /**
     * Longest a single poll option may be.
     *
     * Short by design: an option nobody can read at a glance is not an option,
     * and every platform that runs polls caps them somewhere near here.
     */
    public const DEFAULT_POLL_OPTION_LENGTH = 25;

    /** A poll needs at least two answers, and stops being one past a handful. */
    public const POLL_OPTION_RANGE = ['min' => 2, 'max' => 4];

    /**
     * Where media sits while you are writing.
     *
     *  - blocks: each image, video or poll is a card in the document flow, in
     *            the position it was inserted (the default — right for notes,
     *            articles and anything long-form)
     *  - strip:  media is pulled OUT of the flow into one horizontally
     *            scrolling row of thumbnails under the text, each with its own
     *            remove, alt-text and edit controls
     *
     * Social composers use the strip: attachments there belong to the POST,
     * not to a position in the prose, and a full-width card per photo pushes
     * the writing off the screen.
     *
     * @var list<string>
     */
    public const MEDIA_LAYOUTS = ['blocks', 'strip'];

    /**
     * How the live count is drawn.
     *
     *  - text: "180 chars · 32 words" under the document (the default)
     *  - ring: a filling circle, the way X counts down to its limit. Needs
     *          `maxLength` — a ring with nothing to fill toward is meaningless,
     *          so it falls back to text when none is set.
     *
     * @var list<string>
     */
    public const COUNT_STYLES = ['text', 'ring'];

    /**
     * What `maxLength` does when the user reaches it.
     *
     *  - hard: further typing is rejected (the default)
     *  - soft: typing continues, the overflow is marked, and SAVE is blocked
     *
     * Soft is what social composers do. Refusing the keystroke hides the
     * problem — the writer cannot see how much they have to cut.
     *
     * @var list<string>
     */
    public const MAX_LENGTH_MODES = ['hard', 'soft'];

    /**
     * What backing out of the editor offers.
     *
     *  - discard: "Discard changes?" with Keep Editing / Discard (the default)
     *  - draft:   "Save post?" with Delete / Save — the composer behaviour,
     *             where backing out of something half-written should not throw
     *             it away by default
     *
     * `draft` emits {@see Events\DraftRequested} with the document instead of
     * {@see EditCancelled}, because where a draft is STORED is the
     * host's business — the editor has no database and should not grow one.
     *
     * @var list<string>
     */
    public const CANCEL_MODES = ['discard', 'draft'];

    /**
     * How backing out is drawn.
     *
     *  - text: the word "Cancel" (the default)
     *  - icon: a ✕, which is what full-screen composers use
     *
     * @var list<string>
     */
    public const CANCEL_STYLES = ['text', 'icon'];

    /**
     * How the save action is drawn.
     *
     *  - text: a plain text button (the default)
     *  - filled: a filled pill, dimmed until the document may actually be
     *            saved — the shape every social composer uses for its
     *            primary action
     *
     * @var list<string>
     */
    public const SAVE_STYLES = ['text', 'filled'];

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
        'checklist' => 'toolChecklist',
        'orderedList' => 'toolOrderedList',
        'blockquote' => 'styleQuote',
        'link' => 'toolLink',
        'code' => 'toolCode',
        'textColor' => 'toolTextColor',
        'highlight' => 'toolHighlight',
        'image' => 'toolImage',
        'camera' => 'toolCamera',
        'video' => 'toolVideo',
        'file' => 'toolFile',
        'poll' => 'toolPoll',
        'divider' => 'toolDivider',
        'embed' => 'toolEmbed',
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
     * @var array<string, list<string>> editor key => host tokens, best first
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
     * Update one of your accessory rows while the editor is open.
     *
     * Called after {@see Events\AccessoryTapped} once the app knows what the
     * user chose — so "Add location" can become "San Francisco" without
     * closing the editor.
     */
    public function setAccessory(string $accessory, string $label = '', string $value = ''): void
    {
        if (! function_exists('nativephp_call') || $accessory === '') {
            return;
        }

        nativephp_call('WysiwygEditor.SetAccessory', json_encode([
            'accessory' => $accessory,
            'label' => $label,
            'value' => $value,
        ]));
    }

    /**
     * Show a media block full-screen.
     *
     * The editor already decodes images and plays video for its own cards, so
     * a host rendering SAVED content should not have to build a second viewer
     * to do the same thing — especially as the platform offers no video
     * element to build one out of.
     *
     * `$kind` is `image` or `video`; `$source` is the remote url or the local
     * path, whichever the host has.
     */
    public function preview(string $kind, string $source, string $caption = ''): void
    {
        if (! function_exists('nativephp_call') || $source === '') {
            return;
        }

        nativephp_call('WysiwygEditor.Preview', json_encode([
            'kind' => in_array($kind, ['image', 'video'], true) ? $kind : 'image',
            'source' => $source,
            'caption' => $caption,
        ]));
    }

    /**
     * Convert a saved document to Markdown.
     *
     * Takes the `$json` from {@see ContentSaved}, not the HTML — JSON
     * is the canonical form, so the export does not inherit a loss that
     * already happened. See {@see Markdown} for what Markdown cannot carry.
     */
    /**
     * Every file the document carries, pulled out of the saved JSON.
     *
     * Most servers want the prose in one table and the files in another, and
     * the editor does not upload anything — the endpoint is yours, so the
     * upload is too. This is the split, so an app does not have to learn the
     * document format to do it:
     *
     *     foreach (WysiwygEditor::attachments($json) as $file) {
     *         if ($file['path'] === '') {
     *             continue;   // already on your server; $file['url'] says where
     *         }
     *
     *         Http::attach('file', file_get_contents($file['path']))
     *             ->post('https://api.example.com/media', ['kind' => $file['kind']]);
     *     }
     *
     * `path` is a device path and is set only while a file has NOT been
     * uploaded; `url` is set once it has. Exactly one of them is filled for
     * any given attachment, so which to do next is never ambiguous.
     *
     * Polls, dividers and embeds are not files and are not returned — they
     * travel in the document itself.
     *
     * @return list<array{kind: string, path: string, url: string, alt: string, caption: string, uploadId: string}>
     */
    public function attachments(string $json): array
    {
        $document = json_decode($json, true);

        if (! is_array($document) || ! is_array($document['blocks'] ?? null)) {
            return [];
        }

        $out = [];

        foreach ($document['blocks'] as $block) {
            if (! is_array($block)) {
                continue;
            }

            $kind = (string) ($block['type'] ?? '');

            // `camera` is how a photo is ASKED for, not what it comes back as.
            if (! in_array($kind, ['image', 'video', 'file'], true)) {
                continue;
            }

            $path = $this->attr($block, 'localPath');
            $url = $this->attr($block, 'src');

            // A block carrying neither is a placeholder the user removed the
            // file from; there is nothing to upload and nothing to point at.
            if ($path === '' && $url === '') {
                continue;
            }

            $out[] = [
                'kind' => $kind,
                'path' => $path,
                'url' => $url,
                'alt' => $this->attr($block, 'alt'),
                'caption' => $this->attr($block, 'caption'),
                'uploadId' => $this->attr($block, 'uploadId'),
            ];
        }

        return $out;
    }

    /** @param  array<string, mixed>  $block */
    protected function attr(array $block, string $key): string
    {
        $value = $block[$key] ?? '';

        return is_string($value) ? $value : '';
    }

    public function toMarkdown(string $json): string
    {
        return Markdown::fromJson($json);
    }

    /**
     * Insert a media block at the caret.
     *
     * Call this after your app has picked (and optionally edited) the media —
     * see {@see MediaRequested}. The block
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
        $document = $this->documentJson($html);

        return [
            // Empty when the caller handed us JSON — the native side prefers
            // `contentJson` and only parses HTML when there is none.
            'content' => $document === null ? $html : '',
            'contentJson' => $document ?? '',
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
            'countStyle' => $this->pick($options['countStyle'] ?? null, self::COUNT_STYLES),
            'maxLengthMode' => $this->pick($options['maxLengthMode'] ?? null, self::MAX_LENGTH_MODES),
            'saveStyle' => $this->pick($options['saveStyle'] ?? null, self::SAVE_STYLES),
            'cancelMode' => $this->pick($options['cancelMode'] ?? null, self::CANCEL_MODES),
            'cancelStyle' => $this->pick($options['cancelStyle'] ?? null, self::CANCEL_STYLES),
            'mediaLayout' => $this->pick($options['mediaLayout'] ?? null, self::MEDIA_LAYOUTS),
            // Four is what social composers settle on: enough to tell a story,
            // few enough to lay out in a grid the reader can take in at once.
            'maxMedia' => max(0, (int) ($options['maxMedia'] ?? self::DEFAULT_MAX_MEDIA)),
            'pollOptionMaxLength' => max(
                1,
                (int) ($options['pollOptionMaxLength'] ?? self::DEFAULT_POLL_OPTION_LENGTH)
            ),
            'pollMinOptions' => self::POLL_OPTION_RANGE['min'],
            'pollMaxOptions' => self::POLL_OPTION_RANGE['max'],
            'pollDurations' => self::POLL_DURATIONS,
            'accessories' => $this->resolveAccessories($options['accessories'] ?? []),
            'customTools' => $this->resolveCustomTools($options['customTools'] ?? []),
            'sheets' => $this->resolveSheets($options['sheets'] ?? []),
            'backgrounds' => $this->resolveBackgrounds($options['backgrounds'] ?? []),
            'backgroundMaxLength' => max(
                0,
                (int) ($options['backgroundMaxLength'] ?? self::BACKGROUND_MAX_LENGTH)
            ),
            // Right-aligned when the bar is two buttons rather than a rack of
            // formatting tools — LinkedIn's composer parks its photo and "+"
            // in the corner, and a left-aligned pair reads as an oversight.
            'toolbarAlign' => $this->pick($options['toolbarAlign'] ?? null, self::TOOLBAR_ALIGNMENTS),
            // Beside the text, or up in the header next to the audience
            // picker. `none` leaves the writing the full width.
            'avatarPlacement' => $this->pick($options['avatarPlacement'] ?? null, self::AVATAR_PLACEMENTS),
            'triggers' => $this->resolveTriggers($options['triggers'] ?? null),
            // The author's picture, shown beside what they are writing — what
            // every social composer puts there. A url or a local path.
            'avatar' => (string) ($options['avatar'] ?? ''),
            // Undo/redo lead the toolbar by default. Composers built for short
            // posts do not show them, and with no other tools enabled they
            // would be the only thing left on the bar.
            'history' => (bool) ($options['history'] ?? true),
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
        if (! class_exists(Theme::class)) {
            return '';
        }

        $tokens = Theme::all();

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
     * Choose one of `$allowed`, falling back to the first — which is always
     * the option's documented default.
     *
     * @param  list<string>  $allowed
     */
    protected function pick(mixed $value, array $allowed, ?string $default = null): string
    {
        return in_array($value, $allowed, true) ? $value : ($default ?? $allowed[0]);
    }

    /**
     * Which characters start a lookup.
     *
     * `false` turns the feature off; an array replaces the defaults, so an app
     * that only wants hashtags passes `['#' => 'hashtag']`. A trigger must be
     * a SINGLE character — the editor watches one keystroke, not a prefix.
     *
     * @return array<string, string>
     */
    protected function resolveTriggers(mixed $triggers): array
    {
        if ($triggers === false) {
            return [];
        }

        if (! is_array($triggers)) {
            return self::DEFAULT_TRIGGERS;
        }

        $out = [];

        foreach ($triggers as $character => $kind) {
            $character = (string) $character;
            $kind = trim((string) $kind);

            if (mb_strlen($character) === 1 && $kind !== '') {
                $out[$character] = $kind;
            }
        }

        return $out;
    }

    /**
     * Answer a {@see Events\SuggestionRequested} with what the host found.
     *
     * Each suggestion needs an `id` (yours, echoed back on the resulting
     * mention), a `label` to show and insert, and optionally `detail` — a
     * headline, a handle, a follower count — plus `avatar`.
     *
     * Call with an empty list to say "nothing matched"; the editor closes the
     * list rather than leaving a spinner.
     *
     * @param  array<int, array<string, mixed>>  $suggestions
     */
    /**
     * Ask the open editor to run one of its OWN tools.
     *
     * The seam a host sheet needs. LinkedIn's composer has no formatting bar —
     * everything is behind a "+" the app draws — so when the user picks "Poll"
     * from that sheet, something has to tell the editor to insert one. Without
     * this the host could offer a tool it had no way to trigger.
     *
     * Only tools the editor actually owns; anything else is ignored, because a
     * typo should do nothing rather than something surprising.
     */
    public function insertTool(string $tool): void
    {
        if (! in_array($tool, self::AVAILABLE_TOOLS, true)) {
            return;
        }

        nativephp_call('WysiwygEditor.RunTool', json_encode(['tool' => $tool]));
    }

    /**
     * Write text at the caret, as if the user had typed it.
     *
     * The seam a HOST command needs. A slash command the editor does not own
     * — `/date`, `/signature`, `/ticket` — comes back as
     * {@see Events\ToolTapped} with the trigger already removed, and then the
     * app has to put something there. Without this it could offer the command
     * but never complete it.
     *
     * Inherits the formatting at the caret, because text you insert should
     * look like the text around it.
     */
    public function insertText(string $text): void
    {
        if ($text === '' || ! function_exists('nativephp_call')) {
            return;
        }

        nativephp_call('WysiwygEditor.InsertText', json_encode(['text' => $text]));
    }

    public function suggestions(string $query, array $suggestions): void
    {
        if (! function_exists('nativephp_call')) {
            return;
        }

        $rows = [];

        foreach ($suggestions as $suggestion) {
            if (! is_array($suggestion)) {
                continue;
            }

            $id = trim((string) ($suggestion['id'] ?? ''));
            $label = trim((string) ($suggestion['label'] ?? ''));

            if ($id === '' || $label === '') {
                continue;
            }

            $row = ['id' => $id, 'label' => $label];

            foreach (['detail', 'avatar', 'icon', 'tool'] as $key) {
                $value = trim((string) ($suggestion[$key] ?? ''));

                if ($value !== '') {
                    $row[$key] = $value;
                }
            }

            $rows[] = $row;
        }

        nativephp_call('WysiwygEditor.Suggestions', json_encode([
            'query' => $query,
            'suggestions' => $rows,
        ]));
    }

    /**
     * Extra toolbar buttons for the composer.
     *
     * A button with no `id` could never report a tap and one with no `icon`
     * would draw as a blank gap, so both are required.
     *
     * @param  array<int, array<string, mixed>>  $tools
     * @return list<array<string, string>>
     */
    protected function resolveCustomTools(array $tools): array
    {
        $out = [];

        foreach ($tools as $tool) {
            if (! is_array($tool)) {
                continue;
            }

            $id = trim((string) ($tool['id'] ?? ''));
            $icon = trim((string) ($tool['icon'] ?? ''));

            if ($id === '' || $icon === '') {
                continue;
            }

            $row = ['id' => $id, 'icon' => $icon];

            foreach (['label', 'sheet'] as $key) {
                $value = trim((string) ($tool[$key] ?? ''));

                if ($value !== '') {
                    $row[$key] = $value;
                }
            }

            $out[] = $row;
        }

        return $out;
    }

    /**
     * Host controls for the composer.
     *
     * One needs an `id` to report back with and a `label` to show; anything
     * without both is dropped rather than drawn as a blank tappable strip.
     * `icon` names one of the editor's own glyphs, `value` is the trailing
     * text a row like "Everyone can reply" carries, `placement` and `style`
     * say where and how it draws, and `sheet` names a sheet to present instead
     * of merely reporting the tap.
     *
     * A control in the header defaults to the `chip` style, because that is
     * what fits there — a full-width row in a 52-point bar is not a thing.
     *
     * @param  array<int, array<string, mixed>>  $accessories
     * @return list<array<string, string>>
     */
    protected function resolveAccessories(array $accessories): array
    {
        $rows = [];

        foreach ($accessories as $accessory) {
            if (! is_array($accessory)) {
                continue;
            }

            $id = trim((string) ($accessory['id'] ?? ''));
            $label = trim((string) ($accessory['label'] ?? ''));

            if ($id === '' || $label === '') {
                continue;
            }

            $row = ['id' => $id, 'label' => $label];

            foreach (['icon', 'value', 'sheet'] as $key) {
                $value = trim((string) ($accessory[$key] ?? ''));

                if ($value !== '') {
                    $row[$key] = $value;
                }
            }

            $placement = $this->pick($accessory['placement'] ?? null, self::ACCESSORY_PLACEMENTS);
            $row['placement'] = $placement;
            $row['style'] = $this->pick(
                $accessory['style'] ?? null,
                self::ACCESSORY_STYLES,
                $placement === 'header' ? 'chip' : 'row',
            );

            $rows[] = $row;
        }

        return $rows;
    }

    /**
     * A hex colour, normalised with its leading hash, or null if it is not one.
     *
     * The same rule the theme keys use — #RGB, #RRGGBB or #RRGGBBAA, hash
     * optional going in and always present coming out, so the native side
     * never has to guess.
     */
    protected function color(mixed $value): ?string
    {
        if (! is_string($value)) {
            return null;
        }

        if (! preg_match('/^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/', $value, $match)) {
            return null;
        }

        return '#'.strtoupper($match[1]);
    }

    /**
     * Colours a short post can be written on.
     *
     * A background needs an `id` to round-trip as and a `from` colour to draw;
     * anything without both is dropped rather than offered as a blank swatch.
     *
     * @param  array<int, array<string, mixed>>  $backgrounds
     * @return list<array<string, string>>
     */
    protected function resolveBackgrounds(array $backgrounds): array
    {
        $out = [];

        foreach ($backgrounds as $key => $background) {
            if (! is_array($background)) {
                continue;
            }

            $id = trim((string) ($background['id'] ?? (is_string($key) ? $key : '')));
            $from = $this->color($background['from'] ?? '');

            if ($id === '' || $from === null) {
                continue;
            }

            $row = ['id' => $id, 'from' => $from];

            // A second colour makes it a gradient; without one it is flat.
            $to = $this->color($background['to'] ?? '');

            if ($to !== null) {
                $row['to'] = $to;
            }

            // White on anything dark is the usual answer, so that is the
            // default — but a pale background needs to say otherwise.
            $row['textColor'] = $this->color($background['textColor'] ?? '') ?? '#FFFFFF';

            $out[] = $row;
        }

        return $out;
    }

    /**
     * Sheets the host declares for the editor to present.
     *
     * A sheet with no options would open onto nothing, and one with no id
     * could never be asked for, so both are required. Options follow the same
     * rule as rows: an id to report and a label to show.
     *
     * @param  array<int, array<string, mixed>>  $sheets
     * @return list<array<string, mixed>>
     */
    protected function resolveSheets(array $sheets): array
    {
        $out = [];

        foreach ($sheets as $key => $sheet) {
            if (! is_array($sheet)) {
                continue;
            }

            // Declared either as a list of sheets each carrying an id, or as
            // a map keyed by it — both read naturally, so both are accepted.
            $id = trim((string) ($sheet['id'] ?? (is_string($key) ? $key : '')));
            $options = $this->resolveSheetOptions($sheet['options'] ?? []);

            if ($id === '' || $options === []) {
                continue;
            }

            $out[] = [
                'id' => $id,
                'title' => trim((string) ($sheet['title'] ?? '')),
                'style' => $this->pick($sheet['style'] ?? null, self::SHEET_STYLES),
                'options' => $options,
            ];
        }

        return $out;
    }

    /**
     * @param  array<int, array<string, mixed>>  $options
     * @return list<array<string, mixed>>
     */
    protected function resolveSheetOptions(array $options): array
    {
        $out = [];

        foreach ($options as $option) {
            if (! is_array($option)) {
                continue;
            }

            $id = trim((string) ($option['id'] ?? ''));
            $label = trim((string) ($option['label'] ?? ''));

            if ($id === '' || $label === '') {
                continue;
            }

            $row = ['id' => $id, 'label' => $label];

            foreach (['detail', 'icon'] as $key) {
                $value = trim((string) ($option[$key] ?? ''));

                if ($value !== '') {
                    $row[$key] = $value;
                }
            }

            // The tick, so a sheet can show what is already chosen.
            if (! empty($option['selected'])) {
                $row['selected'] = true;
            }

            $out[] = $row;
        }

        return $out;
    }

    /**
     * Is this content our document JSON rather than HTML?
     *
     * `open()` has always taken HTML, but HTML deliberately cannot carry a
     * local file path — a device path must not leak into published markup —
     * so re-opening a post from its HTML silently loses every image whose
     * upload had not finished. JSON is the canonical form; if you saved it,
     * you can hand it straight back.
     *
     * Returns the JSON when it is one of our documents, or null to treat the
     * input as HTML. Anything ambiguous is HTML, which is the safe default:
     * misreading HTML as JSON would empty the editor.
     */
    protected function documentJson(string $content): ?string
    {
        $trimmed = ltrim($content);

        if ($trimmed === '' || $trimmed[0] !== '{') {
            return null;
        }

        $decoded = json_decode($content, true);

        return is_array($decoded) && is_array($decoded['blocks'] ?? null) ? $content : null;
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
        if (! class_exists(Theme::class)) {
            return [];
        }

        $tokens = Theme::all()[$scheme] ?? [];

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
        // An explicit `toolbar => []` means NO toolbar — a plain-text composer
        // like X's is a real requirement, and it has to be distinguishable
        // from "you asked for tools I do not have", which still falls back.
        if (array_key_exists('toolbar', $options) && $options['toolbar'] === []) {
            return [];
        }

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
