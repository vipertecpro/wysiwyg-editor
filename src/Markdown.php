<?php

namespace Vipertecpro\WysiwygEditor;

/**
 * Converts a saved document to Markdown.
 *
 * Reads the **JSON** the editor returns, not the HTML. JSON is the canonical
 * form — it carries block ids, upload state and poll options that HTML has
 * nowhere to put — so converting from it means Markdown never inherits a loss
 * that already happened. See docs/DOCUMENT-MODEL.md.
 *
 * Markdown is a narrower format than the document model, so some things cannot
 * survive. That is stated rather than hidden — see {@see self::DROPPED}.
 */
class Markdown
{
    /**
     * Marks with no Markdown spelling. They are dropped, not approximated:
     * emitting raw HTML for them would produce a file that is Markdown in name
     * only, and every renderer would treat it differently.
     *
     * @var list<string>
     */
    public const DROPPED = ['underline', 'color', 'highlight'];

    /** Characters that would otherwise be read as Markdown syntax. */
    private const ESCAPE = ['\\', '`', '*', '_', '[', ']'];

    /**
     * Convert the `$json` payload from {@see Events\ContentSaved} to Markdown.
     *
     * Unparseable or foreign JSON yields an empty string rather than an
     * exception — an export helper should not be able to take down a save.
     */
    public static function fromJson(string $json): string
    {
        $document = json_decode($json, true);

        if (! is_array($document) || ! is_array($document['blocks'] ?? null)) {
            return '';
        }

        $chunks = [];
        $ordinal = 1;

        foreach ($document['blocks'] as $block) {
            if (! is_array($block)) {
                continue;
            }

            $type = (string) ($block['type'] ?? 'p');

            // Ordered lists number within a RUN — a paragraph between two
            // lists starts the second one at 1 again, as the editor shows it.
            if ($type === 'ol') {
                $chunks[] = $ordinal.'. '.self::runs($block);
                $ordinal++;

                continue;
            }

            $ordinal = 1;

            $chunk = self::block($type, $block);

            if ($chunk !== null) {
                $chunks[] = $chunk;
            }
        }

        return implode("\n\n", $chunks);
    }

    /**
     * One block. Returns null for a block with nothing to say in Markdown.
     *
     * @param  array<string, mixed>  $block
     */
    private static function block(string $type, array $block): ?string
    {
        return match ($type) {
            'h1' => '# '.self::runs($block),
            'h2' => '## '.self::runs($block),
            'h3' => '### '.self::runs($block),
            'ul' => '- '.self::runs($block),
            'blockquote' => '> '.self::runs($block),
            'divider' => '---',
            'image' => self::image($block),
            // Markdown has no video element, so it becomes a link — the reader
            // can still get to it, which is the most the format allows.
            'video' => self::link(self::attr($block, 'caption') ?: 'Video', self::src($block)),
            'file' => self::link(self::attr($block, 'name') ?: 'File', self::src($block)),
            // Bare URLs are what most renderers turn back into an embed.
            'embed' => self::attr($block, 'url'),
            'poll' => self::poll($block),
            default => self::runs($block),
        };
    }

    /** @param  array<string, mixed>  $block */
    private static function image(array $block): string
    {
        $out = '!'.self::link(self::attr($block, 'alt'), self::src($block));
        $caption = self::attr($block, 'caption');

        return $caption === '' ? $out : $out."\n\n*".self::escape($caption).'*';
    }

    /**
     * Polls have no Markdown form at all. Rendering the question and its
     * options as a list at least carries the CONTENT across; the fact that it
     * was votable does not survive, which is why JSON is the lossless format.
     *
     * @param  array<string, mixed>  $block
     */
    private static function poll(array $block): string
    {
        $lines = ['**'.self::escape(self::attr($block, 'question')).'**'];

        foreach ($block['options'] ?? [] as $option) {
            if (is_array($option) && isset($option['label'])) {
                $lines[] = '- '.self::escape((string) $option['label']);
            }
        }

        return implode("\n", $lines);
    }

    /**
     * A block's inline runs, with marks applied.
     *
     * @param  array<string, mixed>  $block
     */
    private static function runs(array $block): string
    {
        $out = '';

        foreach ($block['runs'] ?? [] as $run) {
            if (! is_array($run)) {
                continue;
            }

            $text = (string) ($run['text'] ?? '');

            if ($text === '') {
                continue;
            }

            $marks = is_array($run['marks'] ?? null) ? $run['marks'] : [];
            $out .= self::marked($text, $marks);
        }

        return $out;
    }

    /**
     * Wrap `$text` in its marks.
     *
     * Code is applied FIRST and stops there: nothing inside a code span is
     * formatting, so wrapping it in asterisks would put literal asterisks in
     * the reader's code. A link always wraps outermost so its label carries
     * whatever emphasis it had.
     *
     * @param  array<string, mixed>  $marks
     */
    private static function marked(string $text, array $marks): string
    {
        if (($marks['code'] ?? false) === true) {
            // A span containing a backtick needs a longer fence than any run
            // of backticks inside it, per CommonMark.
            preg_match_all('/`+/', $text, $found);
            $fence = str_repeat('`', max(array_map('strlen', $found[0] ?: [''])) + 1);
            $body = $fence.$text.$fence;
        } else {
            $body = self::escape($text);

            if (($marks['bold'] ?? false) === true) {
                $body = '**'.$body.'**';
            }
            if (($marks['italic'] ?? false) === true) {
                $body = '*'.$body.'*';
            }
            if (($marks['strike'] ?? false) === true) {
                $body = '~~'.$body.'~~';
            }
        }

        $link = $marks['link'] ?? null;

        return is_string($link) && $link !== '' ? '['.$body.']('.$link.')' : $body;
    }

    /** Prefer the uploaded url, fall back to the local file. */
    private static function src(array $block): string
    {
        $src = self::attr($block, 'src');

        return $src !== '' ? $src : self::attr($block, 'localPath');
    }

    /** @param  array<string, mixed>  $block */
    private static function attr(array $block, string $key): string
    {
        $value = $block[$key] ?? '';

        return is_string($value) ? $value : '';
    }

    private static function link(string $label, string $url): string
    {
        return '['.self::escape($label).']('.$url.')';
    }

    private static function escape(string $text): string
    {
        return str_replace(self::ESCAPE, array_map(fn ($c) => '\\'.$c, self::ESCAPE), $text);
    }
}
