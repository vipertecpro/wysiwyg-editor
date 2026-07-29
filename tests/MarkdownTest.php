<?php

use Vipertecpro\WysiwygEditor\Markdown;

/**
 * Markdown export.
 *
 * Fixtures are the JSON the editor actually returns — same shape, same key
 * order — so these tests fail if the document model changes underneath them.
 */
function doc(array ...$blocks): string
{
    return json_encode(['version' => 2, 'blocks' => $blocks]);
}

function text(string $type, array ...$runs): array
{
    return ['id' => 'b1', 'type' => $type, 'runs' => $runs];
}

function run(string $text, array $marks = []): array
{
    return ['text' => $text, 'marks' => (object) $marks];
}

describe('Blocks', function () {
    it('converts headings, paragraphs and quotes', function () {
        $md = Markdown::fromJson(doc(
            text('h1', run('Title')),
            text('p', run('Body')),
            text('h2', run('Sub')),
            text('h3', run('Smaller')),
            text('blockquote', run('Quoted')),
        ));

        expect($md)->toBe("# Title\n\nBody\n\n## Sub\n\n### Smaller\n\n> Quoted");
    });

    it('numbers ordered lists within a run, restarting after other content', function () {
        $md = Markdown::fromJson(doc(
            text('ol', run('one')),
            text('ol', run('two')),
            text('p', run('break')),
            text('ol', run('one again')),
        ));

        expect($md)->toBe("1. one\n\n2. two\n\nbreak\n\n1. one again");
    });

    it('converts bullets and dividers', function () {
        expect(Markdown::fromJson(doc(text('ul', run('a')), ['type' => 'divider'])))
            ->toBe("- a\n\n---");
    });
});

describe('Marks', function () {
    it('applies bold, italic and strike', function () {
        $md = Markdown::fromJson(doc(text('p',
            run('b', ['bold' => true]),
            run('i', ['italic' => true]),
            run('s', ['strike' => true]),
        )));

        expect($md)->toBe('**b***i*~~s~~');
    });

    it('nests marks on one run', function () {
        expect(Markdown::fromJson(doc(text('p', run('x', ['bold' => true, 'italic' => true])))))
            ->toBe('***x***');
    });

    it('wraps a link outermost so its label keeps its emphasis', function () {
        $md = Markdown::fromJson(doc(text('p',
            run('site', ['bold' => true, 'link' => 'https://example.com']),
        )));

        expect($md)->toBe('[**site**](https://example.com)');
    });

    it('does not format inside code, which would put literal asterisks in it', function () {
        expect(Markdown::fromJson(doc(text('p', run('a*b', ['code' => true, 'bold' => true])))))
            ->toBe('`a*b`');
    });

    it('lengthens the fence when the code itself contains backticks', function () {
        expect(Markdown::fromJson(doc(text('p', run('use `x`', ['code' => true])))))
            ->toBe('``use `x```');
    });

    it('escapes characters that would otherwise be syntax', function () {
        expect(Markdown::fromJson(doc(text('p', run('a *star* and _under_')))))
            ->toBe('a \*star\* and \_under\_');
    });

    it('drops marks Markdown cannot spell rather than faking them', function () {
        $md = Markdown::fromJson(doc(text('p',
            run('plain', ['underline' => true, 'color' => '#FF0000', 'highlight' => '#FDE68A']),
        )));

        expect($md)->toBe('plain')
            ->and(Markdown::DROPPED)->toBe(['underline', 'color', 'highlight']);
    });
});

describe('Media', function () {
    it('converts an image, with its caption below', function () {
        $md = Markdown::fromJson(doc([
            'type' => 'image', 'src' => 'https://cdn/x.jpg', 'alt' => 'A cat', 'caption' => 'Asleep',
        ]));

        expect($md)->toBe("![A cat](https://cdn/x.jpg)\n\n*Asleep*");
    });

    it('falls back to the local file before an upload finishes', function () {
        expect(Markdown::fromJson(doc(['type' => 'image', 'localPath' => '/tmp/a.jpg', 'alt' => 'x'])))
            ->toBe('![x](/tmp/a.jpg)');
    });

    it('links video and files, since Markdown has no element for them', function () {
        $md = Markdown::fromJson(doc(
            ['type' => 'video', 'src' => 'https://cdn/v.mp4'],
            ['type' => 'file', 'src' => 'https://cdn/r.pdf', 'name' => 'Report.pdf'],
        ));

        expect($md)->toBe("[Video](https://cdn/v.mp4)\n\n[Report.pdf](https://cdn/r.pdf)");
    });

    it('emits an embed as a bare url', function () {
        expect(Markdown::fromJson(doc(['type' => 'embed', 'url' => 'https://youtu.be/x'])))
            ->toBe('https://youtu.be/x');
    });

    it('carries a poll across as a question and a list, losing only the voting', function () {
        $md = Markdown::fromJson(doc([
            'type' => 'poll',
            'question' => 'Best editor?',
            'options' => [['id' => 'o1', 'label' => 'This one'], ['id' => 'o2', 'label' => 'The other']],
        ]));

        expect($md)->toBe("**Best editor?**\n- This one\n- The other");
    });
});

describe('Robustness', function () {
    it('returns nothing for input that is not a document', function (string $input) {
        expect(Markdown::fromJson($input))->toBe('');
    })->with(['', 'not json', '{}', '[]', '{"blocks":"nope"}']);

    it('skips empty runs rather than emitting stray markers', function () {
        expect(Markdown::fromJson(doc(text('p', run(''), run('kept')))))->toBe('kept');
    });
});
